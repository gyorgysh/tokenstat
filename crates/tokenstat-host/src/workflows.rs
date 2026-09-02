// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Host-owned workflow graphs: persist, validate, and run a DAG of steps.
//!
//! A workflow is not an automation. An automation is one scheduled job. A
//! workflow is a graph that may *include* one as a node. The Mac canvas is a
//! view of this IR. MCP and the runner see the same JSON.
//!
//! A timer still must not call `gitwrite`. Commit, push and tag are an agent
//! prompt, an existing automation, or a Command the person pressed Run on.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::automations::{self, DEFAULT_BUDGET_SECONDS, ScheduleSpec};

/// How many completed runs to remember.
const RUNS_KEPT: usize = 100;
/// Prompt and HTTP body expansion cap, same order as automation transcripts.
const OUTPUT_CAP: usize = 64 * 1024;
const MAX_NODES: usize = 64;
const MAX_EDGES: usize = 128;
const MAX_LOOP_TIMES: u32 = 20;
const TICK: Duration = Duration::from_secs(5);
const DRAIN_POLL: Duration = Duration::from_millis(40);
const EXIT_SETTLE: Duration = Duration::from_secs(2);

// MARK: - IR

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum WorkflowScope {
    #[default]
    Global,
    Workspace,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum NodeKind {
    Input,
    Agent,
    Automation,
    Http,
    Command,
    Gate,
    /// Then / Else on the joined output of finished predecessors.
    Condition,
    /// Bounded repeat. Cycles may pass through this node only.
    Loop,
    /// Reserved. Saving a graph that uses it is refused until the host is
    /// an MCP client.
    Mcp,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum EdgeWhen {
    #[default]
    Ok,
    Error,
    Always,
}

/// One node on the graph. Positions are view metadata. The runner ignores them.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    pub x: f64,
    pub y: f64,
    pub title: String,
    pub backend: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub prompt: Option<String>,
    /// `exit` (default) or `output`.
    pub wait: Option<String>,
    pub wait_pattern: Option<String>,
    pub automation_id: Option<String>,
    pub prompt_override: Option<String>,
    pub method: Option<String>,
    pub url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub body: Option<String>,
    pub command: Option<String>,
    /// `contains` (default), `equals`, or `matches`. Condition nodes.
    pub test: Option<String>,
    pub pattern: Option<String>,
    /// Loop body passes. 1..=20, default 3.
    pub times: Option<u32>,
    /// Optional template. After a body pass, stop when the expanded text
    /// is found in the body output.
    pub until: Option<String>,
}

impl Default for Node {
    fn default() -> Self {
        Self {
            id: String::new(),
            kind: NodeKind::Input,
            x: 0.0,
            y: 0.0,
            title: String::new(),
            backend: None,
            model: None,
            effort: None,
            prompt: None,
            wait: None,
            wait_pattern: None,
            automation_id: None,
            prompt_override: None,
            method: None,
            url: None,
            headers: None,
            body: None,
            command: None,
            test: None,
            pattern: None,
            times: None,
            until: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Edge {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub when: EdgeWhen,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Workflow {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub scope: WorkflowScope,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default = "default_budget")]
    pub budget_seconds: u64,
    #[serde(default)]
    pub schedule: ScheduleSpec,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub nodes: Vec<Node>,
    #[serde(default)]
    pub edges: Vec<Edge>,
    #[serde(default)]
    pub last_run_at_ms: Option<i64>,
    #[serde(default)]
    pub next_run_at_ms: Option<i64>,
    #[serde(default)]
    pub last_run_id: Option<String>,
}

fn default_budget() -> u64 {
    DEFAULT_BUDGET_SECONDS
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StepRecord {
    pub node_id: String,
    pub kind: String,
    pub title: String,
    pub status: String,
    #[serde(default)]
    pub output: String,
    pub started_at_ms: i64,
    #[serde(default)]
    pub ended_at_ms: Option<i64>,
    #[serde(default)]
    pub exit_code: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRun {
    pub id: String,
    pub workflow_id: String,
    pub name: String,
    pub workspace_id: String,
    #[serde(default)]
    pub input: String,
    pub status: String,
    pub started_at_ms: i64,
    #[serde(default)]
    pub ended_at_ms: Option<i64>,
    #[serde(default)]
    pub current_node_id: Option<String>,
    #[serde(default)]
    pub steps: Vec<StepRecord>,
    #[serde(default)]
    pub live_pty_ids: Vec<String>,
    /// Whole-run budget, copied from the graph at start so continue after a
    /// gate still stops at the original limit.
    #[serde(default = "default_budget")]
    pub budget_seconds: u64,
    /// How many body passes each loop has started. Runner-only.
    #[serde(default)]
    pub loop_counts: HashMap<String, u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct WorkflowsFile {
    #[serde(default)]
    workflows: Vec<Workflow>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct RunsFile {
    #[serde(default)]
    runs: Vec<WorkflowRun>,
}

// MARK: - Store

pub struct Store {
    path: PathBuf,
    runs_path: PathBuf,
    runs_dir: PathBuf,
    workflows: Mutex<Vec<Workflow>>,
    runs: Mutex<Vec<WorkflowRun>>,
    killed: Mutex<HashSet<String>>,
}

pub fn shared() -> Arc<Store> {
    static STORE: std::sync::OnceLock<Arc<Store>> = std::sync::OnceLock::new();
    Arc::clone(STORE.get_or_init(|| Arc::new(Store::load())))
}

impl Store {
    #[cfg(test)]
    fn at(path: PathBuf) -> Store {
        let runs_dir = path.parent().unwrap_or(&path).join("workflow-runs");
        let file = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<WorkflowsFile>(&text).ok())
            .unwrap_or_default();
        let runs_path = runs_dir.join("runs.json");
        let runs = std::fs::read_to_string(&runs_path)
            .ok()
            .and_then(|text| serde_json::from_str::<RunsFile>(&text).ok())
            .map(|file| file.runs)
            .unwrap_or_default();
        Store {
            path,
            runs_path,
            runs_dir,
            workflows: Mutex::new(file.workflows),
            runs: Mutex::new(runs),
            killed: Mutex::new(HashSet::new()),
        }
    }

    pub fn load() -> Store {
        let dir = tokenstat_paths::data_dir().unwrap_or_else(|| PathBuf::from("."));
        let path = dir.join("workflows.json");
        let file = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<WorkflowsFile>(&text).ok())
            .unwrap_or_default();
        let runs_dir = dir.join("workflow-runs");
        let runs_path = runs_dir.join("runs.json");
        let mut runs = std::fs::read_to_string(&runs_path)
            .ok()
            .and_then(|text| serde_json::from_str::<RunsFile>(&text).ok())
            .map(|file| file.runs)
            .unwrap_or_default();
        let mut recovered = false;
        for run in &mut runs {
            if matches!(run.status.as_str(), "running" | "waiting") {
                run.status = "interrupted".into();
                run.ended_at_ms = Some(now_ms());
                run.live_pty_ids.clear();
                recovered = true;
            }
        }
        let store = Store {
            path,
            runs_path,
            runs_dir,
            workflows: Mutex::new(file.workflows),
            runs: Mutex::new(runs),
            killed: Mutex::new(HashSet::new()),
        };
        if recovered {
            let _ = store.save_runs();
        }
        store
    }

    fn save(&self) -> Result<(), String> {
        let workflows = self
            .workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let body = serde_json::to_string_pretty(&WorkflowsFile { workflows })
            .map_err(|e| e.to_string())?;
        write_atomic(&self.path, &body)
    }

    fn save_runs(&self) -> Result<(), String> {
        let runs = self
            .runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        std::fs::create_dir_all(&self.runs_dir).map_err(|e| e.to_string())?;
        let body = serde_json::to_string_pretty(&RunsFile { runs }).map_err(|e| e.to_string())?;
        write_atomic(&self.runs_path, &body)
    }

    pub fn list(&self) -> Vec<Workflow> {
        self.workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn get(&self, id: &str) -> Result<Workflow, String> {
        self.workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|wf| wf.id == id)
            .cloned()
            .ok_or_else(|| format!("no workflow with id {id}"))
    }

    pub fn create(&self, mut workflow: Workflow) -> Result<Workflow, String> {
        if workflow.id.is_empty() {
            workflow.id = format!("wf-{}", now_ms());
        }
        validate(&workflow)?;
        let mut all = self
            .workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if all.iter().any(|existing| existing.id == workflow.id) {
            return Err(format!("a workflow with id {} already exists", workflow.id));
        }
        if workflow.enabled {
            workflow.next_run_at_ms = workflow.schedule.next_run_ms(now_ms());
        }
        all.push(workflow.clone());
        drop(all);
        self.save()?;
        Ok(workflow)
    }

    pub fn update(&self, mut workflow: Workflow) -> Result<Workflow, String> {
        validate(&workflow)?;
        let mut all = self
            .workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let Some(idx) = all.iter().position(|existing| existing.id == workflow.id) else {
            return Err(format!("no workflow with id {}", workflow.id));
        };
        workflow.last_run_at_ms = all[idx].last_run_at_ms;
        workflow.last_run_id = all[idx].last_run_id.clone();
        if workflow.enabled {
            workflow.next_run_at_ms = workflow.schedule.next_run_ms(now_ms());
        } else {
            workflow.next_run_at_ms = None;
        }
        all[idx] = workflow.clone();
        drop(all);
        self.save()?;
        Ok(workflow)
    }

    pub fn remove(&self, id: &str) -> Result<bool, String> {
        let mut all = self
            .workflows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let before = all.len();
        all.retain(|wf| wf.id != id);
        let removed = all.len() != before;
        drop(all);
        if removed {
            self.save()?;
        }
        Ok(removed)
    }

    pub fn runs(&self) -> Vec<WorkflowRun> {
        self.runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    pub fn get_run(&self, id: &str) -> Result<WorkflowRun, String> {
        self.runs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|run| run.id == id)
            .cloned()
            .ok_or_else(|| format!("no workflow run with id {id}"))
    }

    pub fn transcript(
        &self,
        run_id: &str,
        node_id: &str,
        offset: u64,
    ) -> Result<(String, u64), String> {
        let path = self.step_path(run_id, node_id);
        let bytes = std::fs::read(&path).unwrap_or_default();
        let text = if bytes.is_empty() {
            self.get_run(run_id)
                .ok()
                .and_then(|run| {
                    run.steps
                        .into_iter()
                        .find(|s| s.node_id == node_id)
                        .map(|s| s.output)
                })
                .unwrap_or_default()
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        };
        let start = align_char_boundary(&text, offset as usize);
        let slice = &text[start..];
        Ok((slice.to_string(), start as u64 + slice.len() as u64))
    }

    fn step_path(&self, run_id: &str, node_id: &str) -> PathBuf {
        self.runs_dir.join(run_id).join(format!("{node_id}.txt"))
    }

    fn write_step_file(&self, run_id: &str, node_id: &str, text: &str) {
        let path = self.step_path(run_id, node_id);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, text.as_bytes());
    }

    fn is_killed(&self, run_id: &str) -> bool {
        self.killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(run_id)
    }

    fn mark_killed(&self, run_id: &str) {
        self.killed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(run_id.to_string());
    }

    fn upsert_run(&self, run: WorkflowRun) -> Result<(), String> {
        let mut runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = runs.iter_mut().find(|r| r.id == run.id) {
            *existing = run;
        } else {
            runs.insert(0, run);
            if runs.len() > RUNS_KEPT {
                runs.truncate(RUNS_KEPT);
            }
        }
        drop(runs);
        self.save_runs()
    }

    pub fn run(
        self: &Arc<Self>,
        id: &str,
        input: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<WorkflowRun, String> {
        let workflow = self.get(id)?;
        let bound = bind_workspace(&workflow, workspace_id.as_deref())?;
        crate::workspaces::folder(&bound)?;
        if !automations::shared().try_take_slot() {
            return Err("the run queue is full".into());
        }
        let run = WorkflowRun {
            id: format!("wfr-{}", now_ms()),
            workflow_id: workflow.id.clone(),
            name: workflow.name.clone(),
            workspace_id: bound,
            input: input.unwrap_or_default(),
            status: "running".into(),
            started_at_ms: now_ms(),
            ended_at_ms: None,
            current_node_id: None,
            steps: Vec::new(),
            live_pty_ids: Vec::new(),
            budget_seconds: workflow.budget_seconds,
            loop_counts: HashMap::new(),
        };
        if let Err(e) = self.upsert_run(run.clone()) {
            automations::shared().release_slot();
            return Err(e);
        }
        {
            let mut all = self
                .workflows
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if let Some(wf) = all.iter_mut().find(|wf| wf.id == workflow.id) {
                wf.last_run_at_ms = Some(run.started_at_ms);
                wf.last_run_id = Some(run.id.clone());
                if wf.enabled {
                    wf.next_run_at_ms = wf.schedule.next_run_ms(now_ms());
                }
            }
        }
        let _ = self.save();
        let me = Arc::clone(self);
        let graph = workflow;
        let run_id = run.id.clone();
        if let Err(e) = std::thread::Builder::new()
            .name(format!("workflow-{run_id}"))
            .spawn(move || {
                me.execute(&graph, &run_id);
                automations::shared().release_slot();
            })
        {
            automations::shared().release_slot();
            let mut failed = run;
            self.kill_live(&mut failed);
            fail_run(&mut failed, &format!("could not start the run: {e}"));
            let _ = self.upsert_run(failed);
            return Err(e.to_string());
        }
        Ok(run)
    }

    pub fn kill(&self, run_id: &str) -> Result<(), String> {
        self.mark_killed(run_id);
        let mut run = self.get_run(run_id)?;
        for pty in run.live_pty_ids.drain(..) {
            let _ = tokenstat_pty::manager().kill(&pty);
            let _ = tokenstat_pty::manager().close(&pty);
        }
        if matches!(run.status.as_str(), "running" | "waiting") {
            run.status = "stopped".into();
            run.ended_at_ms = Some(now_ms());
            self.upsert_run(run)?;
        }
        Ok(())
    }

    pub fn continue_run(self: &Arc<Self>, run_id: &str) -> Result<WorkflowRun, String> {
        let (workflow, run, gate_id) = {
            let mut runs = self.runs.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(existing) = runs.iter_mut().find(|run| run.id == run_id) else {
                return Err(format!("no workflow run with id {run_id}"));
            };
            if existing.status != "waiting" {
                return Err("that run is not waiting on a gate".into());
            }
            let Some(node_id) = existing.current_node_id.clone() else {
                return Err("that run has no gate to continue".into());
            };
            let workflow = self.get(&existing.workflow_id)?;
            if !automations::shared().try_take_slot() {
                return Err("the run queue is full".into());
            }
            if let Some(step) = existing.steps.iter_mut().find(|s| s.node_id == node_id) {
                step.status = "ok".into();
                step.ended_at_ms = Some(now_ms());
                step.output = "continued".into();
            }
            existing.status = "running".into();
            existing.current_node_id = None;
            (workflow, existing.clone(), node_id)
        };
        if let Err(e) = self.save_runs() {
            if let Ok(mut waiting) = self.get_run(run_id) {
                restore_waiting_gate(&mut waiting, &gate_id);
                let _ = self.upsert_run(waiting);
            }
            automations::shared().release_slot();
            return Err(e);
        }
        let me = Arc::clone(self);
        let id = run.id.clone();
        let spawn_id = id.clone();
        if let Err(e) = std::thread::Builder::new()
            .name(format!("workflow-{id}"))
            .spawn(move || {
                me.execute(&workflow, &spawn_id);
                automations::shared().release_slot();
            })
        {
            automations::shared().release_slot();
            if let Ok(mut waiting) = self.get_run(&id) {
                restore_waiting_gate(&mut waiting, &gate_id);
                let _ = self.upsert_run(waiting);
            }
            return Err(e.to_string());
        }
        Ok(run)
    }

    fn execute(&self, workflow: &Workflow, run_id: &str) {
        let Ok(mut run) = self.get_run(run_id) else {
            return;
        };
        let workspace = match crate::workspaces::folder(&run.workspace_id) {
            Ok(ws) => ws,
            Err(e) => {
                self.kill_live(&mut run);
                fail_run(&mut run, &e);
                let _ = self.upsert_run(run);
                return;
            }
        };
        let workspace_path = workspace.path.to_string_lossy().into_owned();
        let deadline = run_deadline(&run);

        for node in &workflow.nodes {
            if node.kind != NodeKind::Input {
                continue;
            }
            if run.steps.iter().any(|s| s.node_id == node.id) {
                continue;
            }
            run.steps.push(StepRecord {
                node_id: node.id.clone(),
                kind: "input".into(),
                title: display_title(node),
                status: "ok".into(),
                output: run.input.clone(),
                started_at_ms: now_ms(),
                ended_at_ms: Some(now_ms()),
                exit_code: None,
            });
        }

        loop {
            if self.is_killed(run_id) {
                self.finish_run(&mut run, "stopped");
                return;
            }
            if deadline.is_some_and(|d| Instant::now() >= d) || budget_spent(&run) {
                self.finish_run(&mut run, "stopped");
                return;
            }

            let mut ready = ready_nodes(workflow, &run);
            if ready.is_empty() {
                settle_stuck_loops(workflow, &mut run);
                skip_unreachable(workflow, &mut run);
                ready = ready_nodes(workflow, &run);
            }
            if ready.is_empty() {
                if unfinished(workflow, &run).is_empty() {
                    let status = if run.steps.iter().any(|s| s.status == "error") {
                        "error"
                    } else {
                        "ok"
                    };
                    self.finish_run(&mut run, status);
                    return;
                }
                std::thread::sleep(DRAIN_POLL);
                continue;
            }

            for node_id in ready {
                if self.is_killed(run_id) {
                    break;
                }
                let Some(node) = workflow.nodes.iter().find(|n| n.id == node_id) else {
                    continue;
                };
                run.current_node_id = Some(node.id.clone());
                let _ = self.upsert_run(run.clone());
                match self.run_node(&mut run, node, &workspace_path) {
                    NodeOutcome::Gate => {
                        run.status = "waiting".into();
                        let _ = self.upsert_run(run);
                        // A gate is the one state that cannot resolve itself.
                        // Worth waking a phone for, where a finished run is
                        // only worth telling.
                        tokenstat_sync::push::notify_in_background(
                            tokenstat_sync::push::Reason::RunNeedsInput,
                        );
                        return;
                    }
                    NodeOutcome::Done => {}
                }
            }
        }
    }

    fn finish_run(&self, run: &mut WorkflowRun, status: &str) {
        run.status = status.into();
        run.ended_at_ms = Some(now_ms());
        run.current_node_id = None;
        self.kill_live(run);
        let _ = self.upsert_run(run.clone());
        // A phone with the app closed has no other way to learn this. The Mac
        // sees it for itself and notifies locally. "stopped" is somebody at
        // the keyboard, so it stays quiet.
        if status != "stopped" {
            tokenstat_sync::push::notify_in_background(tokenstat_sync::push::Reason::for_exit(
                status, None,
            ));
        }
    }

    fn run_node(&self, run: &mut WorkflowRun, node: &Node, workspace_path: &str) -> NodeOutcome {
        let started = now_ms();
        let mut step = StepRecord {
            node_id: node.id.clone(),
            kind: kind_name(node.kind).into(),
            title: display_title(node),
            status: "running".into(),
            output: String::new(),
            started_at_ms: started,
            ended_at_ms: None,
            exit_code: None,
        };
        if !matches!(node.kind, NodeKind::Gate | NodeKind::Input | NodeKind::Loop) {
            if let Some(existing) = run.steps.iter_mut().find(|s| s.node_id == node.id) {
                *existing = step.clone();
            } else {
                run.steps.push(step.clone());
            }
            self.write_step_file(&run.id, &node.id, "");
            let _ = self.upsert_run(run.clone());
        }
        let outputs = outputs_so_far(run);
        let result = match node.kind {
            NodeKind::Input => Ok(("ok".into(), run.input.clone(), None)),
            NodeKind::Gate => {
                step.status = "waiting".into();
                run.steps.push(step);
                return NodeOutcome::Gate;
            }
            NodeKind::Mcp => Err("MCP steps are not available yet".into()),
            NodeKind::Condition => self.run_condition(run, node, workspace_path, &outputs),
            NodeKind::Loop => self.run_loop(run, node, workspace_path, &outputs),
            NodeKind::Agent => self.run_agent(run, node, workspace_path, &outputs),
            NodeKind::Command => self.run_command(run, node, workspace_path, &outputs),
            NodeKind::Http => run_http(node, &outputs, workspace_path, &run.input),
            NodeKind::Automation => self.run_automation(run, node, &outputs, workspace_path),
        };
        match result {
            Ok((status, output, code)) => {
                step.status = status;
                step.output = cap_output(&output);
                step.exit_code = code;
            }
            Err(e) => {
                step.status = "error".into();
                step.output = e;
            }
        }
        step.ended_at_ms = Some(now_ms());
        self.write_step_file(&run.id, &node.id, &step.output);
        if let Some(existing) = run.steps.iter_mut().find(|s| s.node_id == node.id) {
            *existing = step;
        } else {
            run.steps.push(step);
        }
        let _ = self.upsert_run(run.clone());
        NodeOutcome::Done
    }

    fn run_condition(
        &self,
        run: &mut WorkflowRun,
        node: &Node,
        workspace_path: &str,
        outputs: &HashMap<String, StepRecord>,
    ) -> Result<(String, String, Option<i32>), String> {
        let workflow = self.get(&run.workflow_id).ok();
        eval_condition(workflow.as_ref(), run, node, workspace_path, outputs)
    }

    fn run_loop(
        &self,
        run: &mut WorkflowRun,
        node: &Node,
        workspace_path: &str,
        outputs: &HashMap<String, StepRecord>,
    ) -> Result<(String, String, Option<i32>), String> {
        let workflow = self.get(&run.workflow_id)?;
        advance_loop(&workflow, run, node, workspace_path, outputs)
    }

    fn run_agent(
        &self,
        run: &mut WorkflowRun,
        node: &Node,
        workspace_path: &str,
        outputs: &HashMap<String, StepRecord>,
    ) -> Result<(String, String, Option<i32>), String> {
        let backend = node
            .backend
            .as_deref()
            .ok_or("an agent node needs a backend")?;
        let prompt = expand(
            node.prompt.as_deref().unwrap_or(""),
            &run.input,
            workspace_path,
            outputs,
        );
        if prompt.trim().is_empty() {
            return Err("an agent node needs a prompt".into());
        }
        if budget_spent(run) {
            return Err("the run budget is spent".into());
        }
        let remaining = remaining_budget(run);
        let argv = automations::agent_command(
            backend,
            &prompt,
            node.model.as_deref(),
            node.effort.as_deref(),
            remaining,
        )?;
        let run_id = run.id.clone();
        let node_id = node.id.clone();
        drain_pty(
            DrainPty {
                run,
                argv: &argv,
                cwd: workspace_path,
                budget_seconds: remaining,
                node,
                reader: &format!("workflow:{run_id}:{node_id}"),
            },
            |current| {
                let _ = self.upsert_run(current.clone());
            },
            || self.is_killed(&run_id),
            |text| self.write_step_file(&run_id, &node_id, text),
        )
    }

    fn run_command(
        &self,
        run: &mut WorkflowRun,
        node: &Node,
        workspace_path: &str,
        outputs: &HashMap<String, StepRecord>,
    ) -> Result<(String, String, Option<i32>), String> {
        let raw = node
            .command
            .as_deref()
            .or(node.prompt.as_deref())
            .unwrap_or("");
        let command = expand(raw, &run.input, workspace_path, outputs);
        if command.trim().is_empty() {
            return Err("a command node needs a command".into());
        }
        if budget_spent(run) {
            return Err("the run budget is spent".into());
        }
        let remaining = remaining_budget(run);
        let argv = automations::agent_command("sh", &command, None, None, remaining)?;
        let run_id = run.id.clone();
        let node_id = node.id.clone();
        drain_pty(
            DrainPty {
                run,
                argv: &argv,
                cwd: workspace_path,
                budget_seconds: remaining,
                node,
                reader: &format!("workflow:{run_id}:{node_id}"),
            },
            |current| {
                let _ = self.upsert_run(current.clone());
            },
            || self.is_killed(&run_id),
            |text| self.write_step_file(&run_id, &node_id, text),
        )
    }

    fn run_automation(
        &self,
        run: &WorkflowRun,
        node: &Node,
        outputs: &HashMap<String, StepRecord>,
        workspace_path: &str,
    ) -> Result<(String, String, Option<i32>), String> {
        let id = node
            .automation_id
            .as_deref()
            .ok_or("an automation node needs automationId")?;
        let override_prompt = node
            .prompt_override
            .as_deref()
            .map(|over| expand(over, &run.input, workspace_path, outputs));
        // Stamped with the workflow run, so the step does not announce itself
        // as a job somebody scheduled. See `RunRecord::parent_run_id`.
        let started =
            automations::shared().start_now(id, override_prompt.as_deref(), Some(&run.id))?;
        loop {
            if self.is_killed(&run.id) {
                let _ = automations::shared().kill_run(&started.id);
                return Err("stopped".into());
            }
            std::thread::sleep(DRAIN_POLL);
            let Some(current) = automations::shared().get_run(&started.id) else {
                return Err("the automation run disappeared".into());
            };
            if matches!(current.status.as_str(), "running" | "queued") {
                continue;
            }
            let (text, _) = automations::shared()
                .transcript(&current.id, 0)
                .unwrap_or_else(|_| (String::new(), 0));
            let status = match current.status.as_str() {
                "ok" => "ok",
                "stopped" => "stopped",
                _ => "error",
            };
            return Ok((status.into(), text, current.exit_code));
        }
    }

    fn kill_live(&self, run: &mut WorkflowRun) {
        for pty in run.live_pty_ids.drain(..) {
            let _ = tokenstat_pty::manager().kill(&pty);
            let _ = tokenstat_pty::manager().close(&pty);
        }
    }

    pub fn run_due(self: &Arc<Self>) {
        let now = now_ms();
        let due: Vec<String> = {
            let all = self
                .workflows
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            all.iter()
                .filter(|wf| wf.enabled && wf.next_run_at_ms.is_some_and(|at| at <= now))
                .map(|wf| wf.id.clone())
                .collect()
        };
        for id in due {
            let _ = self.run(&id, None, None);
        }
    }
}

enum NodeOutcome {
    Done,
    Gate,
}

/// Start the due-job loop. Same reason as automations: no session lock.
pub fn start_scheduler() {
    let store = shared();
    std::thread::spawn(move || {
        loop {
            store.run_due();
            std::thread::sleep(TICK);
        }
    });
}

// MARK: - Design

/// Ask a cheap installed backend for a workflow JSON draft. Never persists
/// and never runs what comes back.
pub fn design(
    prompt: &str,
    workspace_id: Option<&str>,
    backend: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
) -> Result<Value, String> {
    let intent = prompt.trim();
    if intent.is_empty() {
        return Err("describe the run first".into());
    }
    let backend = pick_design_backend(backend);
    let (model, effort) = design_model_effort(&backend, model, effort);
    let workspace = match workspace_id {
        Some(id) => Some(crate::workspaces::folder(id)?),
        None => None,
    };
    let automations = automations::shared()
        .list()
        .into_iter()
        .map(|job| format!("{} ({})", job.id, job.name))
        .collect::<Vec<_>>()
        .join(", ");
    let backends = automations::backends()
        .into_iter()
        .filter_map(|b| b.get("id").and_then(Value::as_str).map(str::to_string))
        .collect::<Vec<_>>()
        .join(", ");
    let folder = workspace
        .as_ref()
        .map(|w| w.path.to_string_lossy().into_owned())
        .unwrap_or_default();
    let brief = format!(
        "{DESIGN_PROMPT}\n\nAvailable backends: {backends}\nExisting automations: {automations}\nWorkspace path: {folder}\n\nIntent:\n{intent}\n"
    );
    let argv =
        automations::agent_command(&backend, &brief, model.as_deref(), effort.as_deref(), 180)?;
    let cwd = if folder.is_empty() {
        std::env::temp_dir().display().to_string()
    } else {
        folder
    };
    let mut scratch = WorkflowRun {
        id: format!("design-{}", now_ms()),
        workflow_id: String::new(),
        name: "Design".into(),
        workspace_id: workspace_id.unwrap_or("").into(),
        input: intent.into(),
        status: "running".into(),
        started_at_ms: now_ms(),
        ended_at_ms: None,
        current_node_id: None,
        steps: Vec::new(),
        live_pty_ids: Vec::new(),
        budget_seconds: 180,
        loop_counts: HashMap::new(),
    };
    let node = Node {
        id: "design".into(),
        kind: NodeKind::Agent,
        title: "Design".into(),
        backend: Some(backend),
        wait: Some("exit".into()),
        ..Node::default()
    };
    let design_reader = format!("workflow-design:{}", scratch.id);
    let (status, transcript, _) = drain_pty(
        DrainPty {
            run: &mut scratch,
            argv: &argv,
            cwd: &cwd,
            budget_seconds: 180,
            node: &node,
            reader: &design_reader,
        },
        |_| {},
        || false,
        |_| {},
    )?;
    if status != "ok" {
        return Err(format!(
            "the design backend did not finish cleanly:\n{transcript}"
        ));
    }
    match parse_workflow_json(&transcript) {
        Ok(mut draft) => {
            draft.id.clear();
            if let Some(id) = workspace_id {
                draft.scope = WorkflowScope::Workspace;
                draft.workspace_id = Some(id.to_string());
            } else {
                draft.scope = WorkflowScope::Global;
                draft.workspace_id = None;
            }
            if let Err(e) = validate(&draft) {
                return Err(format!(
                    "the draft was not a valid workflow ({e}). Transcript:\n{transcript}"
                ));
            }
            Ok(json!({ "workflow": draft, "transcript": transcript }))
        }
        Err(e) => Err(format!("{e}\n\nTranscript:\n{transcript}")),
    }
}

const DESIGN_PROMPT: &str = "You design a tokenstat workflow. Reply with a single JSON object and nothing else. No markdown. The object must match this shape: {\"name\": string, \"scope\": \"global\" or \"workspace\", \"budgetSeconds\": number, \"nodes\": [{\"id\": string, \"kind\": \"input\"|\"agent\"|\"automation\"|\"http\"|\"command\"|\"gate\"|\"condition\"|\"loop\", \"x\": number, \"y\": number, \"title\": string, \"backend\": string?, \"model\": string?, \"effort\": string?, \"prompt\": string?, \"wait\": \"exit\"|\"output\", \"automationId\": string?, \"method\": string?, \"url\": string?, \"body\": string?, \"command\": string?, \"test\": \"contains\"|\"equals\"|\"matches\", \"pattern\": string?, \"times\": number?, \"until\": string?}], \"edges\": [{\"from\": string, \"to\": string, \"when\": \"ok\"|\"error\"|\"always\"}]}. Place nodes top to bottom: x = 80 + sibling * 252, y = 80 + step * 160. A condition reads the previous output: ok is Then, error is Else. A loop's ok edge is the body, always is after the last pass. Cycles may only go through a loop. Use {{input}} and {{nodeId.output}} in prompts. Do not execute anything. Do not invent MCP nodes.";

pub fn parse_workflow_json(text: &str) -> Result<Workflow, String> {
    let start = text
        .find('{')
        .ok_or("the design backend did not return JSON")?;
    let end = text
        .rfind('}')
        .ok_or("the design backend did not return JSON")?;
    if end < start {
        return Err("the design backend did not return JSON".into());
    }
    serde_json::from_str::<Workflow>(&text[start..=end]).map_err(|e| e.to_string())
}

// MARK: - Validate and walk

pub fn validate(workflow: &Workflow) -> Result<(), String> {
    if workflow.name.trim().is_empty() {
        return Err("a workflow needs a name".into());
    }
    match workflow.scope {
        WorkflowScope::Workspace => {
            if workflow.workspace_id.as_deref().unwrap_or("").is_empty() {
                return Err("a workspace workflow needs a workspace".into());
            }
        }
        WorkflowScope::Global => {}
    }
    workflow.schedule.validate()?;
    if workflow.nodes.len() > MAX_NODES {
        return Err(format!("a workflow may have at most {MAX_NODES} nodes"));
    }
    if workflow.edges.len() > MAX_EDGES {
        return Err(format!("a workflow may have at most {MAX_EDGES} edges"));
    }
    let mut ids = HashSet::new();
    for node in &workflow.nodes {
        if node.id.trim().is_empty() {
            return Err("every node needs an id".into());
        }
        if !ids.insert(node.id.clone()) {
            return Err(format!("duplicate node id {}", node.id));
        }
        validate_node(node)?;
    }
    for edge in &workflow.edges {
        if !ids.contains(&edge.from) {
            return Err(format!("edge from unknown node {}", edge.from));
        }
        if !ids.contains(&edge.to) {
            return Err(format!("edge to unknown node {}", edge.to));
        }
        if edge.from == edge.to {
            return Err("a node cannot connect to itself".into());
        }
    }
    if has_illegal_cycle(workflow) {
        return Err("a workflow cannot contain a cycle".into());
    }
    for node in &workflow.nodes {
        if node.kind == NodeKind::Loop {
            let times = node.times.unwrap_or(3);
            if !(1..=MAX_LOOP_TIMES).contains(&times) {
                return Err(format!("a loop may repeat at most {MAX_LOOP_TIMES} times"));
            }
            if !workflow
                .edges
                .iter()
                .any(|e| e.from == node.id && e.when == EdgeWhen::Ok)
            {
                return Err(format!("loop {} needs a body", node.id));
            }
        }
    }
    Ok(())
}

fn validate_node(node: &Node) -> Result<(), String> {
    match node.kind {
        NodeKind::Input | NodeKind::Gate | NodeKind::Loop => Ok(()),
        NodeKind::Condition => match node.test.as_deref().unwrap_or("contains") {
            "contains" | "equals" | "matches" => Ok(()),
            other => Err(format!("unknown condition test {other}")),
        },
        NodeKind::Mcp => Err("MCP steps are not available yet".into()),
        NodeKind::Agent => {
            if node.backend.as_deref().unwrap_or("").is_empty() {
                Err("an agent node needs a backend".into())
            } else {
                Ok(())
            }
        }
        NodeKind::Automation => {
            if node.automation_id.as_deref().unwrap_or("").is_empty() {
                Err("an automation node needs automationId".into())
            } else {
                Ok(())
            }
        }
        NodeKind::Http => {
            let url = node.url.as_deref().unwrap_or("");
            if url.is_empty() {
                return Err("an HTTP node needs a URL".into());
            }
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return Err("an HTTP node URL must start with http:// or https://".into());
            }
            Ok(())
        }
        NodeKind::Command => {
            if node
                .command
                .as_deref()
                .or(node.prompt.as_deref())
                .unwrap_or("")
                .is_empty()
            {
                Err("a command node needs a command".into())
            } else {
                Ok(())
            }
        }
    }
}

/// Cycles are allowed only when every cycle passes through a loop node.
fn has_illegal_cycle(workflow: &Workflow) -> bool {
    let loops: HashSet<&str> = workflow
        .nodes
        .iter()
        .filter(|n| n.kind == NodeKind::Loop)
        .map(|n| n.id.as_str())
        .collect();
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    for edge in &workflow.edges {
        if loops.contains(edge.from.as_str()) || loops.contains(edge.to.as_str()) {
            continue;
        }
        adj.entry(edge.from.as_str())
            .or_default()
            .push(edge.to.as_str());
    }
    fn visit(
        id: &str,
        adj: &HashMap<&str, Vec<&str>>,
        stack: &mut HashSet<String>,
        seen: &mut HashSet<String>,
    ) -> bool {
        if !stack.insert(id.to_string()) {
            return true;
        }
        if seen.insert(id.to_string()) {
            if let Some(next) = adj.get(id) {
                for child in next {
                    if visit(child, adj, stack, seen) {
                        return true;
                    }
                }
            }
        }
        stack.remove(id);
        false
    }
    let mut stack = HashSet::new();
    let mut seen = HashSet::new();
    workflow
        .nodes
        .iter()
        .any(|n| visit(&n.id, &adj, &mut stack, &mut seen))
}

fn ready_nodes(workflow: &Workflow, run: &WorkflowRun) -> Vec<String> {
    let by_id: HashMap<&str, &StepRecord> =
        run.steps.iter().map(|s| (s.node_id.as_str(), s)).collect();
    let mut incoming: HashMap<&str, Vec<&Edge>> = HashMap::new();
    for edge in &workflow.edges {
        incoming.entry(edge.to.as_str()).or_default().push(edge);
    }
    let mut ready = Vec::new();
    for node in &workflow.nodes {
        if let Some(step) = by_id.get(node.id.as_str()) {
            let reenter = node.kind == NodeKind::Loop && step.status == "running";
            if !reenter {
                continue;
            }
        }
        let body = if node.kind == NodeKind::Loop {
            body_ids(workflow, &node.id)
        } else {
            HashSet::new()
        };
        let started = by_id.contains_key(node.id.as_str());
        let edges: Vec<&Edge> = incoming
            .get(node.id.as_str())
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|edge| {
                if node.kind != NodeKind::Loop {
                    return true;
                }
                let from_body = body.contains(&edge.from);
                if started { from_body } else { !from_body }
            })
            .collect();
        if edges.is_empty() {
            if node.kind == NodeKind::Loop && started {
                continue;
            }
            ready.push(node.id.clone());
            continue;
        }
        if incoming_ready(workflow, run, &edges) {
            ready.push(node.id.clone());
        }
    }
    ready
}

fn unfinished(workflow: &Workflow, run: &WorkflowRun) -> Vec<String> {
    let started: HashSet<&str> = run.steps.iter().map(|s| s.node_id.as_str()).collect();
    workflow
        .nodes
        .iter()
        .filter(|n| !started.contains(n.id.as_str()))
        .map(|n| n.id.clone())
        .collect()
}

/// Put a gate back to waiting after continue failed to persist or spawn.
fn restore_waiting_gate(run: &mut WorkflowRun, gate_id: &str) {
    run.status = "waiting".into();
    run.current_node_id = Some(gate_id.to_string());
    if let Some(step) = run.steps.iter_mut().find(|s| s.node_id == gate_id) {
        step.status = "waiting".into();
        step.ended_at_ms = None;
        step.output.clear();
    }
}

/// Edges from a skipped predecessor do not count. Edges from the same
/// predecessor are OR'd so Then and Else can share a join. Distinct
/// predecessors stay AND-joined.
fn incoming_ready(workflow: &Workflow, run: &WorkflowRun, edges: &[&Edge]) -> bool {
    match classify_incoming(workflow, run, edges) {
        Incoming::Ready => true,
        Incoming::Pending | Incoming::Dead => false,
    }
}

enum Incoming {
    Ready,
    Pending,
    Dead,
}

fn classify_incoming(workflow: &Workflow, run: &WorkflowRun, edges: &[&Edge]) -> Incoming {
    let mut by_from: HashMap<&str, Vec<&Edge>> = HashMap::new();
    for edge in edges {
        by_from.entry(edge.from.as_str()).or_default().push(*edge);
    }
    let mut pending = false;
    let mut remaining = 0;
    let mut matching = 0;
    for (from, group) in by_from {
        match run.steps.iter().find(|s| s.node_id == from) {
            Some(step) if step.status == "skipped" => {}
            Some(_) if group.iter().any(|edge| edge_allows(workflow, run, edge)) => {
                remaining += 1;
                matching += 1;
            }
            Some(step) if matches!(step.status.as_str(), "ok" | "error" | "stopped") => {
                remaining += 1;
            }
            Some(_) | None => {
                remaining += 1;
                pending = true;
            }
        }
    }
    if remaining == 0 {
        return Incoming::Dead;
    }
    if pending {
        return Incoming::Pending;
    }
    if matching == remaining {
        Incoming::Ready
    } else {
        Incoming::Dead
    }
}

fn skip_unreachable(workflow: &Workflow, run: &mut WorkflowRun) {
    loop {
        let leftover = unfinished(workflow, run);
        let mut skipped = false;
        for id in leftover {
            if !node_can_never_run(workflow, run, &id) {
                continue;
            }
            let node = workflow.nodes.iter().find(|n| n.id == id);
            run.steps.push(StepRecord {
                node_id: id,
                kind: node
                    .map(|n| kind_name(n.kind).to_string())
                    .unwrap_or_else(|| "node".into()),
                title: node.map(display_title).unwrap_or_default(),
                status: "skipped".into(),
                output: String::new(),
                started_at_ms: now_ms(),
                ended_at_ms: Some(now_ms()),
                exit_code: None,
            });
            skipped = true;
        }
        if !skipped {
            break;
        }
    }
}

fn node_can_never_run(workflow: &Workflow, run: &WorkflowRun, id: &str) -> bool {
    let incoming: Vec<&Edge> = workflow.edges.iter().filter(|e| e.to == id).collect();
    if incoming.is_empty() {
        return false;
    }
    matches!(classify_incoming(workflow, run, &incoming), Incoming::Dead)
}

/// A Loop left `running` with no body to re-enter is stuck. Settle it so
/// Always/Error ports can follow `edge_allows`.
fn settle_stuck_loops(workflow: &Workflow, run: &mut WorkflowRun) {
    let loop_ids: Vec<String> = workflow
        .nodes
        .iter()
        .filter(|n| n.kind == NodeKind::Loop)
        .map(|n| n.id.clone())
        .collect();
    for id in loop_ids {
        let Some(step) = run.steps.iter().find(|s| s.node_id == id) else {
            continue;
        };
        if step.status != "running" {
            continue;
        }
        let body = body_ids(workflow, &id);
        if run.steps.iter().any(|s| {
            body.contains(&s.node_id) && matches!(s.status.as_str(), "running" | "waiting")
        }) {
            continue;
        }
        let returns: Vec<&Edge> = workflow
            .edges
            .iter()
            .filter(|e| e.to == id && body.contains(&e.from))
            .collect();
        if !returns.is_empty() {
            let all_settled = returns.iter().all(|edge| {
                run.steps.iter().any(|s| {
                    s.node_id == edge.from
                        && matches!(s.status.as_str(), "ok" | "error" | "stopped" | "skipped")
                })
            });
            if !all_settled {
                continue;
            }
            if returns.iter().any(|edge| edge_allows(workflow, run, edge)) {
                continue;
            }
        }
        if let Some(step) = run.steps.iter_mut().find(|s| s.node_id == id) {
            step.status = "error".into();
            step.output = "loop body did not return".into();
            step.ended_at_ms = Some(now_ms());
        }
    }
}

fn edge_matches(when: EdgeWhen, status: &str) -> bool {
    match when {
        EdgeWhen::Always => matches!(status, "ok" | "error" | "stopped"),
        EdgeWhen::Ok => status == "ok",
        EdgeWhen::Error => status == "error",
    }
}

fn edge_allows(workflow: &Workflow, run: &WorkflowRun, edge: &Edge) -> bool {
    let Some(pred) = run.steps.iter().find(|s| s.node_id == edge.from) else {
        return false;
    };
    let from_loop = workflow
        .nodes
        .iter()
        .any(|n| n.id == edge.from && n.kind == NodeKind::Loop);
    if from_loop {
        return match edge.when {
            EdgeWhen::Ok => pred.status == "running",
            EdgeWhen::Always => pred.status == "ok",
            EdgeWhen::Error => pred.status == "error",
        };
    }
    edge_matches(edge.when, pred.status.as_str())
}

fn body_ids(workflow: &Workflow, loop_id: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let mut stack: Vec<String> = workflow
        .edges
        .iter()
        .filter(|e| e.from == loop_id && e.when == EdgeWhen::Ok)
        .map(|e| e.to.clone())
        .collect();
    while let Some(id) = stack.pop() {
        if id == loop_id || !out.insert(id.clone()) {
            continue;
        }
        for edge in workflow.edges.iter().filter(|e| e.from == id) {
            if edge.to != loop_id {
                stack.push(edge.to.clone());
            }
        }
    }
    out
}

fn predecessor_output(workflow: &Workflow, run: &WorkflowRun, node_id: &str) -> String {
    workflow
        .edges
        .iter()
        .filter(|e| e.to == node_id)
        .filter_map(|e| {
            run.steps
                .iter()
                .find(|s| s.node_id == e.from)
                .map(|s| s.output.as_str())
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn test_text(test: &str, source: &str, pattern: &str) -> bool {
    match test {
        "equals" => source.trim() == pattern.trim(),
        "matches" => wildcard_match(pattern, source),
        _ => source.contains(pattern),
    }
}

fn wildcard_match(pattern: &str, text: &str) -> bool {
    if pattern.is_empty() {
        return true;
    }
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return text.contains(pattern);
    }
    let mut rest = text;
    if let Some(first) = parts.first() {
        if !first.is_empty() {
            if let Some(idx) = rest.find(first) {
                rest = &rest[idx + first.len()..];
            } else {
                return false;
            }
        }
    }
    for (i, part) in parts.iter().enumerate().skip(1) {
        if part.is_empty() {
            continue;
        }
        if i == parts.len() - 1 && !pattern.ends_with('*') {
            return rest.ends_with(part);
        }
        if let Some(idx) = rest.find(part) {
            rest = &rest[idx + part.len()..];
        } else {
            return false;
        }
    }
    true
}

fn eval_condition(
    workflow: Option<&Workflow>,
    run: &WorkflowRun,
    node: &Node,
    workspace_path: &str,
    outputs: &HashMap<String, StepRecord>,
) -> Result<(String, String, Option<i32>), String> {
    let source = match workflow {
        Some(wf) => predecessor_output(wf, run, &node.id),
        None => run
            .steps
            .iter()
            .map(|s| s.output.as_str())
            .collect::<Vec<_>>()
            .join("\n"),
    };
    let pattern = expand(
        node.pattern.as_deref().unwrap_or(""),
        &run.input,
        workspace_path,
        outputs,
    );
    let matched = test_text(
        node.test.as_deref().unwrap_or("contains"),
        &source,
        &pattern,
    );
    Ok((
        if matched { "ok".into() } else { "error".into() },
        if matched {
            "matched".into()
        } else {
            "not matched".into()
        },
        None,
    ))
}

fn advance_loop(
    workflow: &Workflow,
    run: &mut WorkflowRun,
    node: &Node,
    workspace_path: &str,
    outputs: &HashMap<String, StepRecord>,
) -> Result<(String, String, Option<i32>), String> {
    let times = node.times.unwrap_or(3).clamp(1, MAX_LOOP_TIMES);
    let count = run.loop_counts.get(&node.id).copied().unwrap_or(0);
    if count > 0 && until_matched(node, run, workflow, workspace_path, outputs) {
        return Ok(("ok".into(), format!("done after {count}"), None));
    }
    if count >= times {
        return Ok(("ok".into(), format!("done after {count}"), None));
    }
    let next = count + 1;
    run.loop_counts.insert(node.id.clone(), next);
    let body = body_ids(workflow, &node.id);
    run.steps.retain(|s| !body.contains(&s.node_id));
    Ok((
        "running".into(),
        format!("iteration {next} of {times}"),
        None,
    ))
}

fn until_matched(
    node: &Node,
    run: &WorkflowRun,
    workflow: &Workflow,
    workspace_path: &str,
    outputs: &HashMap<String, StepRecord>,
) -> bool {
    let Some(until) = node.until.as_deref().filter(|s| !s.trim().is_empty()) else {
        return false;
    };
    let needle = expand(until, &run.input, workspace_path, outputs);
    if needle.is_empty() {
        return false;
    }
    let body = body_ids(workflow, &node.id);
    let hay = run
        .steps
        .iter()
        .filter(|s| body.contains(&s.node_id))
        .map(|s| s.output.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    hay.contains(&needle)
}

fn outputs_so_far(run: &WorkflowRun) -> HashMap<String, StepRecord> {
    run.steps
        .iter()
        .map(|s| (s.node_id.clone(), s.clone()))
        .collect()
}

pub fn expand(
    template: &str,
    input: &str,
    workspace_path: &str,
    outputs: &HashMap<String, StepRecord>,
) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        if let Some(end) = after.find("}}") {
            let key = after[..end].trim();
            out.push_str(&lookup(key, input, workspace_path, outputs));
            rest = &after[end + 2..];
        } else {
            out.push_str(&rest[start..]);
            return out;
        }
    }
    out.push_str(rest);
    out
}

fn lookup(
    key: &str,
    input: &str,
    workspace_path: &str,
    outputs: &HashMap<String, StepRecord>,
) -> String {
    if key == "input" {
        return input.to_string();
    }
    if key == "workspace.path" {
        return workspace_path.to_string();
    }
    if let Some((id, field)) = key.split_once('.') {
        if let Some(step) = outputs.get(id) {
            return match field {
                "output" => step.output.clone(),
                "status" => step.status.clone(),
                _ => String::new(),
            };
        }
    }
    String::new()
}

fn bind_workspace(workflow: &Workflow, requested: Option<&str>) -> Result<String, String> {
    let picked = requested.map(str::to_string).filter(|id| !id.is_empty());
    match workflow.scope {
        WorkflowScope::Workspace => picked
            .or_else(|| workflow.workspace_id.clone().filter(|id| !id.is_empty()))
            .ok_or_else(|| "a workspace workflow needs a workspace".into()),
        WorkflowScope::Global => picked
            .or_else(|| workflow.workspace_id.clone())
            .ok_or_else(|| "choose a workspace to run this workflow".into()),
    }
}

fn display_title(node: &Node) -> String {
    if !node.title.trim().is_empty() {
        return node.title.clone();
    }
    match node.kind {
        NodeKind::Input => "Input".into(),
        NodeKind::Agent => node.backend.clone().unwrap_or_else(|| "Agent".into()),
        NodeKind::Automation => "Automation".into(),
        NodeKind::Http => {
            node.method.clone().unwrap_or_else(|| "GET".into())
                + " "
                + node.url.as_deref().unwrap_or("")
        }
        NodeKind::Command => "Command".into(),
        NodeKind::Gate => "Gate".into(),
        NodeKind::Condition => "If".into(),
        NodeKind::Loop => "Loop".into(),
        NodeKind::Mcp => "MCP".into(),
    }
}

fn kind_name(kind: NodeKind) -> &'static str {
    match kind {
        NodeKind::Input => "input",
        NodeKind::Agent => "agent",
        NodeKind::Automation => "automation",
        NodeKind::Http => "http",
        NodeKind::Command => "command",
        NodeKind::Gate => "gate",
        NodeKind::Condition => "condition",
        NodeKind::Loop => "loop",
        NodeKind::Mcp => "mcp",
    }
}

fn align_char_boundary(text: &str, index: usize) -> usize {
    let mut index = index.min(text.len());
    while index > 0 && !text.is_char_boundary(index) {
        index -= 1;
    }
    index
}

fn cap_output(text: &str) -> String {
    if text.len() <= OUTPUT_CAP {
        text.to_string()
    } else {
        text[align_char_boundary(text, text.len() - OUTPUT_CAP)..].to_string()
    }
}

/// Seconds left on the run budget. `0` means no limit when `budget_seconds`
/// is 0, and "already spent" otherwise.
fn remaining_budget(run: &WorkflowRun) -> u64 {
    if run.budget_seconds == 0 {
        return 0;
    }
    let elapsed = ((now_ms() - run.started_at_ms).max(0) as u64) / 1000;
    run.budget_seconds.saturating_sub(elapsed)
}

fn budget_spent(run: &WorkflowRun) -> bool {
    run.budget_seconds != 0 && remaining_budget(run) == 0
}

fn run_deadline(run: &WorkflowRun) -> Option<Instant> {
    if run.budget_seconds == 0 {
        return None;
    }
    let elapsed_ms = (now_ms() - run.started_at_ms).max(0) as u64;
    let budget_ms = run.budget_seconds.saturating_mul(1000);
    if elapsed_ms >= budget_ms {
        Some(Instant::now())
    } else {
        Some(Instant::now() + Duration::from_millis(budget_ms - elapsed_ms))
    }
}

fn pick_design_backend(requested: Option<&str>) -> String {
    if let Some(id) = requested.filter(|id| !id.is_empty()) {
        return id.to_string();
    }
    let listed: Vec<(String, Vec<String>, Vec<String>)> = automations::backends()
        .into_iter()
        .filter_map(|b| {
            let id = b.get("id")?.as_str()?.to_string();
            if id == "sh" {
                return None;
            }
            let models = b
                .get("models")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            let efforts = b
                .get("efforts")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
            Some((id, models, efforts))
        })
        .collect();
    if let Some((id, _, _)) = listed.iter().find(|(id, models, efforts)| {
        crate::agent_models::cheapest_model(id, models).is_some()
            || crate::agent_models::lowest_effort(efforts).is_some()
    }) {
        return id.clone();
    }
    listed
        .into_iter()
        .next()
        .map(|(id, _, _)| id)
        .unwrap_or_else(|| "grok".into())
}

fn design_model_effort(
    backend: &str,
    model: Option<&str>,
    effort: Option<&str>,
) -> (Option<String>, Option<String>) {
    let listed = automations::backends()
        .into_iter()
        .find(|b| b.get("id").and_then(Value::as_str) == Some(backend));
    let models: Vec<String> = listed
        .as_ref()
        .and_then(|b| b.get("models"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let efforts: Vec<String> = listed
        .as_ref()
        .and_then(|b| b.get("efforts"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    resolve_design_model_effort(backend, model, effort, &models, &efforts)
}

fn resolve_design_model_effort(
    backend: &str,
    model: Option<&str>,
    effort: Option<&str>,
    models: &[String],
    efforts: &[String],
) -> (Option<String>, Option<String>) {
    let model = model
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| crate::agent_models::cheapest_model(backend, models));
    let effort = effort
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| crate::agent_models::lowest_effort(efforts));
    (model, effort)
}

fn fail_run(run: &mut WorkflowRun, message: &str) {
    run.status = "error".into();
    run.ended_at_ms = Some(now_ms());
    run.steps.push(StepRecord {
        node_id: "run".into(),
        kind: "run".into(),
        title: "Run".into(),
        status: "error".into(),
        output: message.into(),
        started_at_ms: run.started_at_ms,
        ended_at_ms: run.ended_at_ms,
        exit_code: None,
    });
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn write_atomic(path: &Path, body: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
}

// MARK: - Process and HTTP

struct DrainPty<'a> {
    run: &'a mut WorkflowRun,
    argv: &'a [String],
    cwd: &'a str,
    budget_seconds: u64,
    node: &'a Node,
    reader: &'a str,
}

fn drain_pty(
    ctx: DrainPty<'_>,
    mut persist: impl FnMut(&WorkflowRun),
    is_killed: impl Fn() -> bool,
    mut on_output: impl FnMut(&str),
) -> Result<(String, String, Option<i32>), String> {
    let DrainPty {
        run,
        argv,
        cwd,
        budget_seconds,
        node,
        reader,
    } = ctx;
    let info = tokenstat_pty::manager()
        .spawn(&tokenstat_pty::Spawn {
            command: crate::launcher::spawn_command(&argv[0]),
            args: argv[1..].to_vec(),
            cwd: PathBuf::from(cwd),
            workspace_id: Some(run.workspace_id.clone()),
            hidden: true,
            rows: 24,
            cols: 120,
            no_color: false,
            dark: None,
            environment: Vec::new(),
        })
        .map_err(|e| e.to_string())?;
    let pty_id = info.id.clone();
    run.live_pty_ids.push(pty_id.clone());
    persist(run);
    let wait_output = node.wait.as_deref() == Some("output");
    let pattern = node.wait_pattern.clone();
    let deadline = if budget_seconds == 0 {
        None
    } else {
        Some(Instant::now() + Duration::from_secs(budget_seconds))
    };
    let mut offset = 0u64;
    let mut raw = Vec::new();
    let mut readable = String::new();
    let backend = node.backend.as_deref().unwrap_or("sh");
    let mut parser = crate::transcript::Parser::new(backend);
    let manager = tokenstat_pty::manager();
    let mut stopped = false;
    let matched = loop {
        if is_killed() || deadline.is_some_and(|d| Instant::now() >= d) {
            let _ = manager.kill(&pty_id);
            stopped = is_killed();
        }
        match manager.read_for_viewer(&pty_id, reader, offset) {
            Ok(chunk) => {
                if !chunk.bytes.is_empty() {
                    raw.extend_from_slice(&chunk.bytes);
                    let piece = parser.push(&chunk.bytes);
                    if !piece.is_empty() {
                        readable.push_str(&piece);
                        if readable.len() > OUTPUT_CAP {
                            readable = cap_output(&readable);
                        }
                        on_output(&readable);
                    }
                    offset = chunk.next_offset;
                    if wait_output && !stopped {
                        if let Some(pat) = &pattern {
                            if readable.contains(pat.as_str()) {
                                break true;
                            }
                        } else if !readable.trim().is_empty() {
                            break true;
                        }
                    }
                }
            }
            Err(_) => break false,
        }
        let alive = manager.info(&pty_id).map(|i| i.alive).unwrap_or(false);
        if !alive || stopped {
            let settle = Instant::now() + EXIT_SETTLE;
            while Instant::now() < settle {
                if let Ok(chunk) = manager.read_for_viewer(&pty_id, reader, offset)
                    && !chunk.bytes.is_empty()
                {
                    raw.extend_from_slice(&chunk.bytes);
                    readable.push_str(&parser.push(&chunk.bytes));
                    offset = chunk.next_offset;
                }
                std::thread::sleep(DRAIN_POLL);
            }
            if !readable.is_empty() {
                on_output(&readable);
            }
            break false;
        }
        std::thread::sleep(DRAIN_POLL);
    };
    if readable.trim().is_empty() && !raw.is_empty() {
        readable = String::from_utf8_lossy(&raw).into_owned();
        on_output(&readable);
    }
    let info = manager.info(&pty_id).ok();
    let exit = info.as_ref().and_then(|i| i.exit_code);
    let alive = info.as_ref().map(|i| i.alive).unwrap_or(false);
    if !matched {
        run.live_pty_ids.retain(|id| id != &pty_id);
        persist(run);
        let _ = manager.close(&pty_id);
    }
    let status = if stopped {
        "stopped"
    } else if matched {
        "ok"
    } else if exit == Some(0) || (exit.is_none() && !alive) {
        if exit.unwrap_or(0) == 0 {
            "ok"
        } else {
            "error"
        }
    } else if !alive && exit.unwrap_or(1) != 0 {
        "error"
    } else if alive {
        "ok"
    } else {
        "error"
    };
    let _ = raw;
    Ok((status.into(), cap_output(&readable), exit))
}

fn run_http(
    node: &Node,
    outputs: &HashMap<String, StepRecord>,
    workspace_path: &str,
    input: &str,
) -> Result<(String, String, Option<i32>), String> {
    let url = expand(
        node.url.as_deref().unwrap_or(""),
        input,
        workspace_path,
        outputs,
    );
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("an HTTP node URL must start with http:// or https://".into());
    }
    let method = node.method.as_deref().unwrap_or("GET").to_uppercase();
    let body = expand(
        node.body.as_deref().unwrap_or(""),
        input,
        workspace_path,
        outputs,
    );
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|e| e.to_string())?;
    let parsed: reqwest::Method = method
        .parse()
        .map_err(|_| format!("unknown HTTP method {method}"))?;
    let mut req = client.request(parsed, &url);
    if let Some(headers) = &node.headers {
        for (key, value) in headers {
            let value = expand(value, input, workspace_path, outputs);
            req = req.header(key, value);
        }
    }
    if !body.is_empty() && method != "GET" && method != "HEAD" {
        req = req.body(body);
    }
    let resp = req.send().map_err(|e| e.to_string())?;
    let status = resp.status();
    let code = status.as_u16();
    let text = resp.text().unwrap_or_default();
    let out = format!("HTTP {code}\n{}", cap_output(&text));
    if status.is_success() {
        Ok(("ok".into(), out, Some(i32::from(code))))
    } else {
        Ok(("error".into(), out, Some(i32::from(code))))
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: &str, kind: NodeKind) -> Node {
        Node {
            id: id.into(),
            kind,
            title: id.into(),
            backend: (kind == NodeKind::Agent).then(|| "grok".into()),
            prompt: (kind == NodeKind::Agent).then(|| "{{input}}".into()),
            command: (kind == NodeKind::Command).then(|| "echo hi".into()),
            url: (kind == NodeKind::Http).then(|| "https://example.com".into()),
            automation_id: (kind == NodeKind::Automation).then(|| "job_1".into()),
            ..Node::default()
        }
    }

    fn edge(from: &str, to: &str, when: EdgeWhen) -> Edge {
        Edge {
            from: from.into(),
            to: to.into(),
            when,
        }
    }

    fn test_run(steps: Vec<StepRecord>) -> WorkflowRun {
        WorkflowRun {
            id: "r".into(),
            workflow_id: "wf-test".into(),
            name: "Test".into(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "running".into(),
            started_at_ms: 0,
            ended_at_ms: None,
            current_node_id: None,
            steps,
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        }
    }

    fn rec(id: &str, status: &str, output: &str) -> StepRecord {
        StepRecord {
            node_id: id.into(),
            kind: "command".into(),
            title: id.into(),
            status: status.into(),
            output: output.into(),
            started_at_ms: 0,
            ended_at_ms: Some(0),
            exit_code: None,
        }
    }

    fn graph(nodes: Vec<Node>, edges: Vec<Edge>) -> Workflow {
        Workflow {
            id: "wf-test".into(),
            name: "Test".into(),
            scope: WorkflowScope::Global,
            workspace_id: None,
            budget_seconds: 60,
            schedule: ScheduleSpec::default(),
            enabled: false,
            nodes,
            edges,
            last_run_at_ms: None,
            next_run_at_ms: None,
            last_run_id: None,
        }
    }

    #[test]
    fn rejects_a_cycle() {
        let wf = graph(
            vec![node("a", NodeKind::Input), node("b", NodeKind::Command)],
            vec![edge("a", "b", EdgeWhen::Ok), edge("b", "a", EdgeWhen::Ok)],
        );
        let err = validate(&wf).unwrap_err();
        assert!(err.contains("cycle"), "{err}");
    }

    #[test]
    fn rejects_mcp_until_the_client_exists() {
        let wf = graph(vec![node("m", NodeKind::Mcp)], vec![]);
        let err = validate(&wf).unwrap_err();
        assert!(err.contains("MCP"), "{err}");
    }

    #[test]
    fn rejects_http_without_a_real_url() {
        let mut n = node("h", NodeKind::Http);
        n.url = Some("ftp://x".into());
        let err = validate(&graph(vec![n], vec![])).unwrap_err();
        assert!(err.contains("http"), "{err}");
    }

    #[test]
    fn join_waits_for_every_incoming_edge() {
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                node("a", NodeKind::Command),
                node("b", NodeKind::Command),
                node("join", NodeKind::Command),
            ],
            vec![
                edge("in", "a", EdgeWhen::Ok),
                edge("in", "b", EdgeWhen::Ok),
                edge("a", "join", EdgeWhen::Ok),
                edge("b", "join", EdgeWhen::Ok),
            ],
        );
        let mut run = WorkflowRun {
            id: "r".into(),
            workflow_id: wf.id.clone(),
            name: wf.name.clone(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "running".into(),
            started_at_ms: 0,
            ended_at_ms: None,
            current_node_id: None,
            steps: vec![StepRecord {
                node_id: "in".into(),
                kind: "input".into(),
                title: "in".into(),
                status: "ok".into(),
                output: String::new(),
                started_at_ms: 0,
                ended_at_ms: Some(0),
                exit_code: None,
            }],
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        };
        let first = ready_nodes(&wf, &run);
        assert_eq!(first.len(), 2, "{first:?}");
        assert!(first.contains(&"a".into()));
        assert!(first.contains(&"b".into()));
        run.steps.push(StepRecord {
            node_id: "a".into(),
            kind: "command".into(),
            title: "a".into(),
            status: "ok".into(),
            output: String::new(),
            started_at_ms: 0,
            ended_at_ms: Some(0),
            exit_code: Some(0),
        });
        let mid = ready_nodes(&wf, &run);
        assert_eq!(mid, vec!["b".to_string()]);
        run.steps.push(StepRecord {
            node_id: "b".into(),
            kind: "command".into(),
            title: "b".into(),
            status: "ok".into(),
            output: String::new(),
            started_at_ms: 0,
            ended_at_ms: Some(0),
            exit_code: Some(0),
        });
        assert_eq!(ready_nodes(&wf, &run), vec!["join".to_string()]);
    }

    #[test]
    fn error_edge_fires_only_on_error() {
        let wf = graph(
            vec![
                node("a", NodeKind::Command),
                node("ok", NodeKind::Command),
                node("err", NodeKind::Command),
            ],
            vec![
                edge("a", "ok", EdgeWhen::Ok),
                edge("a", "err", EdgeWhen::Error),
            ],
        );
        let run = WorkflowRun {
            id: "r".into(),
            workflow_id: wf.id.clone(),
            name: wf.name.clone(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "running".into(),
            started_at_ms: 0,
            ended_at_ms: None,
            current_node_id: None,
            steps: vec![StepRecord {
                node_id: "a".into(),
                kind: "command".into(),
                title: "a".into(),
                status: "error".into(),
                output: "no".into(),
                started_at_ms: 0,
                ended_at_ms: Some(0),
                exit_code: Some(1),
            }],
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        };
        assert_eq!(ready_nodes(&wf, &run), vec!["err".to_string()]);
    }

    #[test]
    fn templates_expand_input_and_node_output() {
        let mut outputs = HashMap::new();
        outputs.insert(
            "n1".into(),
            StepRecord {
                node_id: "n1".into(),
                kind: "agent".into(),
                title: "Plan".into(),
                status: "ok".into(),
                output: "build it".into(),
                started_at_ms: 0,
                ended_at_ms: Some(0),
                exit_code: None,
            },
        );
        let got = expand(
            "do {{input}} then {{n1.output}} ({{n1.status}}) in {{workspace.path}}",
            "review",
            "/tmp/proj",
            &outputs,
        );
        assert_eq!(got, "do review then build it (ok) in /tmp/proj");
    }

    #[test]
    fn persist_round_trip() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-wf-{}-{}", std::process::id(), now_ms()));
        let _ = std::fs::create_dir_all(&dir);
        let store = Store::at(dir.join("workflows.json"));
        let created = store
            .create(graph(
                vec![node("in", NodeKind::Input), node("sh", NodeKind::Command)],
                vec![edge("in", "sh", EdgeWhen::Ok)],
            ))
            .unwrap();
        let loaded = Store::at(dir.join("workflows.json"));
        let got = loaded.get(&created.id).unwrap();
        assert_eq!(got.name, "Test");
        assert_eq!(got.nodes.len(), 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn design_json_is_accepted_when_valid() {
        let text = r#"here you go
{"name":"Plan then build","scope":"global","budgetSeconds":3600,"nodes":[{"id":"in","kind":"input","x":0,"y":0,"title":"Start"},{"id":"a","kind":"agent","x":40,"y":0,"title":"Plan","backend":"grok","prompt":"{{input}}"}],"edges":[{"from":"in","to":"a","when":"ok"}]}
thanks"#;
        let wf = parse_workflow_json(text).unwrap();
        validate(&wf).unwrap();
        assert_eq!(wf.name, "Plan then build");
    }

    #[test]
    fn workspace_scope_requires_a_folder() {
        let mut wf = graph(vec![node("in", NodeKind::Input)], vec![]);
        wf.scope = WorkflowScope::Workspace;
        assert!(validate(&wf).unwrap_err().contains("workspace"));
        wf.workspace_id = Some("ws-1".into());
        validate(&wf).unwrap();
    }

    #[test]
    fn leftover_error_branch_is_skipped_on_success() {
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                node("a", NodeKind::Command),
                node("http", NodeKind::Http),
                node("notify", NodeKind::Command),
            ],
            vec![
                edge("in", "a", EdgeWhen::Ok),
                edge("a", "http", EdgeWhen::Ok),
                edge("a", "notify", EdgeWhen::Error),
            ],
        );
        let mut run = WorkflowRun {
            id: "r".into(),
            workflow_id: wf.id.clone(),
            name: wf.name.clone(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "running".into(),
            started_at_ms: 0,
            ended_at_ms: None,
            current_node_id: None,
            steps: vec![
                StepRecord {
                    node_id: "in".into(),
                    kind: "input".into(),
                    title: "in".into(),
                    status: "ok".into(),
                    output: String::new(),
                    started_at_ms: 0,
                    ended_at_ms: Some(0),
                    exit_code: None,
                },
                StepRecord {
                    node_id: "a".into(),
                    kind: "command".into(),
                    title: "a".into(),
                    status: "ok".into(),
                    output: String::new(),
                    started_at_ms: 0,
                    ended_at_ms: Some(0),
                    exit_code: Some(0),
                },
                StepRecord {
                    node_id: "http".into(),
                    kind: "http".into(),
                    title: "http".into(),
                    status: "ok".into(),
                    output: String::new(),
                    started_at_ms: 0,
                    ended_at_ms: Some(0),
                    exit_code: Some(200),
                },
            ],
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        };
        skip_unreachable(&wf, &mut run);
        assert!(
            run.steps
                .iter()
                .any(|s| s.node_id == "notify" && s.status == "skipped"),
            "{:?}",
            run.steps
        );
        assert!(unfinished(&wf, &run).is_empty());
        assert!(!run.steps.iter().any(|s| s.status == "error"));
    }

    #[test]
    fn remaining_budget_is_zero_once_spent() {
        let run = WorkflowRun {
            id: "r".into(),
            workflow_id: "wf".into(),
            name: "t".into(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "running".into(),
            started_at_ms: now_ms() - 120_000,
            ended_at_ms: None,
            current_node_id: None,
            steps: Vec::new(),
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        };
        assert_eq!(remaining_budget(&run), 0);
        assert!(budget_spent(&run));
        let unlimited = WorkflowRun {
            budget_seconds: 0,
            started_at_ms: now_ms() - 120_000,
            ..run
        };
        assert_eq!(remaining_budget(&unlimited), 0);
        assert!(!budget_spent(&unlimited));
    }

    #[test]
    fn cap_output_does_not_panic_on_multibyte() {
        let text = "é".repeat(OUTPUT_CAP);
        let capped = cap_output(&text);
        assert!(capped.len() <= OUTPUT_CAP);
        assert!(!capped.is_empty());
    }

    #[test]
    fn transcript_offset_clamps_to_a_char_boundary() {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-wf-tx-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let store = Store::at(dir.join("workflows.json"));
        let run = WorkflowRun {
            id: "wfr-tx".into(),
            workflow_id: "wf".into(),
            name: "t".into(),
            workspace_id: "ws".into(),
            input: String::new(),
            status: "ok".into(),
            started_at_ms: 0,
            ended_at_ms: Some(0),
            current_node_id: None,
            steps: vec![StepRecord {
                node_id: "n".into(),
                kind: "command".into(),
                title: "n".into(),
                status: "ok".into(),
                output: "éé".into(),
                started_at_ms: 0,
                ended_at_ms: Some(0),
                exit_code: Some(0),
            }],
            live_pty_ids: Vec::new(),
            budget_seconds: 60,
            loop_counts: HashMap::new(),
        };
        store.write_step_file(&run.id, "n", "éé");
        let _ = store.upsert_run(run);
        let (text, next) = store.transcript("wfr-tx", "n", 1).unwrap();
        assert!(text.starts_with('é'), "{text:?}");
        assert_eq!(next, 4);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn loop_cycle_is_allowed() {
        let mut done = node("done", NodeKind::Command);
        done.command = Some("echo done".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                {
                    let mut lp = node("lp", NodeKind::Loop);
                    lp.times = Some(3);
                    lp
                },
                node("body", NodeKind::Command),
                done,
            ],
            vec![
                edge("in", "lp", EdgeWhen::Ok),
                edge("lp", "body", EdgeWhen::Ok),
                edge("body", "lp", EdgeWhen::Ok),
                edge("lp", "done", EdgeWhen::Always),
            ],
        );
        validate(&wf).unwrap();
    }

    #[test]
    fn cycle_without_a_loop_is_still_rejected() {
        let wf = graph(
            vec![node("a", NodeKind::Input), node("b", NodeKind::Command)],
            vec![edge("a", "b", EdgeWhen::Ok), edge("b", "a", EdgeWhen::Ok)],
        );
        let err = validate(&wf).unwrap_err();
        assert!(err.contains("cycle"), "{err}");
    }

    #[test]
    fn loop_times_above_the_cap_is_rejected() {
        let mut lp = node("lp", NodeKind::Loop);
        lp.times = Some(21);
        let wf = graph(
            vec![lp, node("body", NodeKind::Command)],
            vec![edge("lp", "body", EdgeWhen::Ok)],
        );
        let err = validate(&wf).unwrap_err();
        assert!(err.contains("20"), "{err}");
    }

    #[test]
    fn condition_then_and_else_follow_the_test() {
        let mut cond = node("if1", NodeKind::Condition);
        cond.test = Some("contains".into());
        cond.pattern = Some("FAIL".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                node("cmd", NodeKind::Command),
                cond,
                node("then", NodeKind::Command),
                node("els", NodeKind::Command),
            ],
            vec![
                edge("in", "cmd", EdgeWhen::Ok),
                edge("cmd", "if1", EdgeWhen::Ok),
                edge("if1", "then", EdgeWhen::Ok),
                edge("if1", "els", EdgeWhen::Error),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "go"),
            rec("cmd", "ok", "tests FAIL here"),
        ]);
        let outs = outputs_so_far(&run);
        let (status, _, _) = eval_condition(Some(&wf), &run, &wf.nodes[2], "", &outs).unwrap();
        assert_eq!(status, "ok");
        run.steps.push(rec("if1", "ok", "matched"));
        assert_eq!(ready_nodes(&wf, &run), vec!["then".to_string()]);

        let mut miss = test_run(vec![rec("in", "ok", "go"), rec("cmd", "ok", "all green")]);
        let outs = outputs_so_far(&miss);
        let (status, _, _) = eval_condition(Some(&wf), &miss, &wf.nodes[2], "", &outs).unwrap();
        assert_eq!(status, "error");
        miss.steps.push(rec("if1", "error", "not matched"));
        assert_eq!(ready_nodes(&wf, &miss), vec!["els".to_string()]);
    }

    #[test]
    fn leftover_else_branch_is_skipped_after_then() {
        let mut cond = node("if1", NodeKind::Condition);
        cond.pattern = Some("yes".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                cond,
                node("then", NodeKind::Command),
                node("els", NodeKind::Command),
            ],
            vec![
                edge("in", "if1", EdgeWhen::Ok),
                edge("if1", "then", EdgeWhen::Ok),
                edge("if1", "els", EdgeWhen::Error),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "yes"),
            rec("if1", "ok", "matched"),
            rec("then", "ok", "ok"),
        ]);
        skip_unreachable(&wf, &mut run);
        assert!(
            run.steps
                .iter()
                .any(|s| s.node_id == "els" && s.status == "skipped"),
            "{:?}",
            run.steps
        );
    }

    #[test]
    fn loop_runs_the_body_then_takes_always() {
        let mut lp = node("lp", NodeKind::Loop);
        lp.times = Some(2);
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                lp,
                node("body", NodeKind::Command),
                node("done", NodeKind::Command),
            ],
            vec![
                edge("in", "lp", EdgeWhen::Ok),
                edge("lp", "body", EdgeWhen::Ok),
                edge("body", "lp", EdgeWhen::Ok),
                edge("lp", "done", EdgeWhen::Always),
            ],
        );
        validate(&wf).unwrap();
        let mut run = test_run(vec![rec("in", "ok", "start")]);
        assert_eq!(ready_nodes(&wf, &run), vec!["lp".to_string()]);
        let outs = outputs_so_far(&run);
        let (status, _, _) = advance_loop(&wf, &mut run, &wf.nodes[1], "", &outs).unwrap();
        assert_eq!(status, "running");
        assert_eq!(run.loop_counts.get("lp").copied(), Some(1));
        run.steps.push(rec("lp", "running", "iteration 1 of 2"));
        assert_eq!(ready_nodes(&wf, &run), vec!["body".to_string()]);
        run.steps.push(rec("body", "ok", "pass 1"));
        assert_eq!(ready_nodes(&wf, &run), vec!["lp".to_string()]);
        let outs = outputs_so_far(&run);
        let (status, _, _) = advance_loop(&wf, &mut run, &wf.nodes[1], "", &outs).unwrap();
        assert_eq!(status, "running");
        assert_eq!(run.loop_counts.get("lp").copied(), Some(2));
        assert!(!run.steps.iter().any(|s| s.node_id == "body"));
        run.steps.retain(|s| s.node_id != "lp");
        run.steps.push(rec("lp", "running", "iteration 2 of 2"));
        run.steps.push(rec("body", "ok", "pass 2"));
        let outs = outputs_so_far(&run);
        let (status, out, _) = advance_loop(&wf, &mut run, &wf.nodes[1], "", &outs).unwrap();
        assert_eq!(status, "ok", "{out}");
        run.steps.retain(|s| s.node_id != "lp");
        run.steps.push(rec("lp", "ok", "done after 2"));
        assert_eq!(ready_nodes(&wf, &run), vec!["done".to_string()]);
    }

    #[test]
    fn loop_stops_early_when_until_matches() {
        let mut lp = node("lp", NodeKind::Loop);
        lp.times = Some(5);
        lp.until = Some("green".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                lp,
                node("body", NodeKind::Command),
            ],
            vec![
                edge("in", "lp", EdgeWhen::Ok),
                edge("lp", "body", EdgeWhen::Ok),
                edge("body", "lp", EdgeWhen::Ok),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "start"),
            rec("lp", "running", "iteration 1 of 5"),
            rec("body", "ok", "now green"),
        ]);
        run.loop_counts.insert("lp".into(), 1);
        let outs = outputs_so_far(&run);
        let (status, out, _) = advance_loop(&wf, &mut run, &wf.nodes[1], "", &outs).unwrap();
        assert_eq!(status, "ok", "{out}");
        assert!(out.contains("done after 1"), "{out}");
    }

    #[test]
    fn omitted_model_effort_on_claude_is_haiku_and_low() {
        let models = ["fable", "opus", "sonnet", "haiku"].map(String::from);
        let efforts = ["high", "medium", "low"].map(String::from);
        let (model, effort) = resolve_design_model_effort("claude", None, None, &models, &efforts);
        assert_eq!(model.as_deref(), Some("haiku"));
        assert_eq!(effort.as_deref(), Some("low"));
    }

    #[test]
    fn explicit_model_effort_are_honoured() {
        let models = ["fable", "opus", "sonnet", "haiku"].map(String::from);
        let efforts = ["high", "medium", "low"].map(String::from);
        let (model, effort) =
            resolve_design_model_effort("claude", Some("opus"), Some("high"), &models, &efforts);
        assert_eq!(model.as_deref(), Some("opus"));
        assert_eq!(effort.as_deref(), Some("high"));
    }

    #[test]
    fn empty_model_effort_are_treated_as_omitted() {
        let models = ["fable", "opus", "sonnet", "haiku"].map(String::from);
        let efforts = ["high", "medium", "low"].map(String::from);
        let (model, effort) =
            resolve_design_model_effort("claude", Some(""), Some(""), &models, &efforts);
        assert_eq!(model.as_deref(), Some("haiku"));
        assert_eq!(effort.as_deref(), Some("low"));
    }

    #[test]
    fn continue_restores_the_gate_when_spawn_fails() {
        let mut run = test_run(vec![rec("in", "ok", "go"), rec("gate", "ok", "continued")]);
        run.status = "running".into();
        run.current_node_id = None;
        restore_waiting_gate(&mut run, "gate");
        assert_eq!(run.status, "waiting");
        assert_eq!(run.current_node_id.as_deref(), Some("gate"));
        let gate = run.steps.iter().find(|s| s.node_id == "gate").unwrap();
        assert_eq!(gate.status, "waiting");
        assert!(gate.ended_at_ms.is_none());
        assert!(gate.output.is_empty());
    }

    #[test]
    fn bind_workspace_honours_the_requested_folder() {
        let mut wf = graph(vec![node("in", NodeKind::Input)], vec![]);
        wf.scope = WorkflowScope::Workspace;
        wf.workspace_id = Some("ws-a".into());
        assert_eq!(bind_workspace(&wf, Some("ws-b")).unwrap(), "ws-b");
        assert_eq!(bind_workspace(&wf, None).unwrap(), "ws-a");
        wf.scope = WorkflowScope::Global;
        assert_eq!(bind_workspace(&wf, Some("ws-c")).unwrap(), "ws-c");
    }

    #[test]
    fn diamond_join_runs_after_then() {
        let mut cond = node("if1", NodeKind::Condition);
        cond.pattern = Some("yes".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                cond,
                node("then", NodeKind::Command),
                node("els", NodeKind::Command),
                node("join", NodeKind::Command),
            ],
            vec![
                edge("in", "if1", EdgeWhen::Ok),
                edge("if1", "then", EdgeWhen::Ok),
                edge("if1", "els", EdgeWhen::Error),
                edge("then", "join", EdgeWhen::Ok),
                edge("els", "join", EdgeWhen::Ok),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "yes"),
            rec("if1", "ok", "matched"),
            rec("then", "ok", "ok"),
        ]);
        skip_unreachable(&wf, &mut run);
        assert!(
            run.steps
                .iter()
                .any(|s| s.node_id == "els" && s.status == "skipped"),
            "{:?}",
            run.steps
        );
        assert_eq!(ready_nodes(&wf, &run), vec!["join".to_string()]);
        assert!(!run.steps.iter().any(|s| s.status == "error"));
    }

    #[test]
    fn condition_then_and_else_into_the_same_join() {
        let mut cond = node("if1", NodeKind::Condition);
        cond.pattern = Some("yes".into());
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                cond,
                node("join", NodeKind::Command),
            ],
            vec![
                edge("in", "if1", EdgeWhen::Ok),
                edge("if1", "join", EdgeWhen::Ok),
                edge("if1", "join", EdgeWhen::Error),
            ],
        );
        let run = test_run(vec![rec("in", "ok", "yes"), rec("if1", "ok", "matched")]);
        assert_eq!(ready_nodes(&wf, &run), vec!["join".to_string()]);
    }

    #[test]
    fn loop_body_error_settles_and_takes_the_error_port() {
        let mut lp = node("lp", NodeKind::Loop);
        lp.times = Some(3);
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                lp,
                node("body", NodeKind::Command),
                node("fail", NodeKind::Command),
                node("done", NodeKind::Command),
            ],
            vec![
                edge("in", "lp", EdgeWhen::Ok),
                edge("lp", "body", EdgeWhen::Ok),
                edge("body", "lp", EdgeWhen::Ok),
                edge("lp", "fail", EdgeWhen::Error),
                edge("lp", "done", EdgeWhen::Always),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "start"),
            rec("lp", "running", "iteration 1 of 3"),
            rec("body", "error", "boom"),
        ]);
        run.loop_counts.insert("lp".into(), 1);
        settle_stuck_loops(&wf, &mut run);
        let loop_step = run.steps.iter().find(|s| s.node_id == "lp").unwrap();
        assert_eq!(loop_step.status, "error", "{:?}", run.steps);
        skip_unreachable(&wf, &mut run);
        assert_eq!(ready_nodes(&wf, &run), vec!["fail".to_string()]);
        assert!(
            run.steps
                .iter()
                .any(|s| s.node_id == "done" && s.status == "skipped"),
            "{:?}",
            run.steps
        );
    }

    #[test]
    fn loop_missing_return_settles_error_not_always() {
        let mut lp = node("lp", NodeKind::Loop);
        lp.times = Some(2);
        let wf = graph(
            vec![
                node("in", NodeKind::Input),
                lp,
                node("body", NodeKind::Command),
                node("done", NodeKind::Command),
            ],
            vec![
                edge("in", "lp", EdgeWhen::Ok),
                edge("lp", "body", EdgeWhen::Ok),
                edge("lp", "done", EdgeWhen::Always),
            ],
        );
        let mut run = test_run(vec![
            rec("in", "ok", "start"),
            rec("lp", "running", "iteration 1 of 2"),
            rec("body", "ok", "pass"),
        ]);
        run.loop_counts.insert("lp".into(), 1);
        settle_stuck_loops(&wf, &mut run);
        let loop_step = run.steps.iter().find(|s| s.node_id == "lp").unwrap();
        assert_eq!(loop_step.status, "error");
        skip_unreachable(&wf, &mut run);
        assert!(
            run.steps
                .iter()
                .any(|s| s.node_id == "done" && s.status == "skipped"),
            "{:?}",
            run.steps
        );
    }
}
