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
        let dir = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .map(|d| d.data_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."));
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
        let text = String::from_utf8_lossy(&bytes);
        let start = (offset as usize).min(text.len());
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
        };
        self.upsert_run(run.clone())?;
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
        std::thread::spawn(move || {
            me.execute(&graph, &run_id);
            automations::shared().release_slot();
        });
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
        let run = self.get_run(run_id)?;
        if run.status != "waiting" {
            return Err("that run is not waiting on a gate".into());
        }
        let Some(node_id) = run.current_node_id.clone() else {
            return Err("that run has no gate to continue".into());
        };
        let workflow = self.get(&run.workflow_id)?;
        if !automations::shared().try_take_slot() {
            return Err("the run queue is full".into());
        }
        let mut run = run;
        if let Some(step) = run.steps.iter_mut().find(|s| s.node_id == node_id) {
            step.status = "ok".into();
            step.ended_at_ms = Some(now_ms());
            step.output = "continued".into();
        }
        run.status = "running".into();
        run.current_node_id = None;
        if let Err(e) = self.upsert_run(run.clone()) {
            automations::shared().release_slot();
            return Err(e);
        }
        let me = Arc::clone(self);
        let id = run.id.clone();
        std::thread::spawn(move || {
            me.execute(&workflow, &id);
            automations::shared().release_slot();
        });
        Ok(run)
    }

    fn execute(&self, workflow: &Workflow, run_id: &str) {
        let Ok(mut run) = self.get_run(run_id) else {
            return;
        };
        let workspace = match crate::workspaces::folder(&run.workspace_id) {
            Ok(ws) => ws,
            Err(e) => {
                fail_run(&mut run, &e);
                let _ = self.upsert_run(run);
                return;
            }
        };
        let workspace_path = workspace.path.to_string_lossy().into_owned();
        let deadline = if workflow.budget_seconds == 0 {
            None
        } else {
            Some(Instant::now() + Duration::from_secs(workflow.budget_seconds))
        };

        // Seed implicit or explicit input nodes.
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
                run.status = "stopped".into();
                run.ended_at_ms = Some(now_ms());
                self.kill_live(&mut run);
                let _ = self.upsert_run(run);
                return;
            }
            if deadline.is_some_and(|d| Instant::now() >= d) {
                run.status = "stopped".into();
                run.ended_at_ms = Some(now_ms());
                self.kill_live(&mut run);
                let _ = self.upsert_run(run);
                return;
            }

            let ready = ready_nodes(workflow, &run);
            if ready.is_empty() {
                if unfinished(workflow, &run).is_empty() {
                    run.status = "ok".into();
                    run.ended_at_ms = Some(now_ms());
                    run.current_node_id = None;
                    let _ = self.upsert_run(run);
                    return;
                }
                // A predecessor failed and no error/always edge remains.
                if remaining_can_never_run(workflow, &run) {
                    run.status = "error".into();
                    run.ended_at_ms = Some(now_ms());
                    let _ = self.upsert_run(run);
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
                        return;
                    }
                    NodeOutcome::Done => {}
                }
            }
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
        let outputs = outputs_so_far(run);
        let result = match node.kind {
            NodeKind::Input => Ok(("ok".into(), run.input.clone(), None)),
            NodeKind::Gate => {
                step.status = "waiting".into();
                run.steps.push(step);
                return NodeOutcome::Gate;
            }
            NodeKind::Mcp => Err("MCP steps are not available yet".into()),
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
        let remaining = remaining_budget(run);
        let argv = automations::agent_command(
            backend,
            &prompt,
            node.model.as_deref(),
            node.effort.as_deref(),
            remaining,
        )?;
        drain_pty(
            run,
            &argv,
            workspace_path,
            remaining,
            node,
            &format!("workflow:{}:{}", run.id, node.id),
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
        let remaining = remaining_budget(run);
        let argv = automations::agent_command("sh", &command, None, None, remaining)?;
        drain_pty(
            run,
            &argv,
            workspace_path,
            remaining,
            node,
            &format!("workflow:{}:{}", run.id, node.id),
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
        if let Some(over) = node.prompt_override.as_deref() {
            let _ = expand(over, &run.input, workspace_path, outputs);
        }
        let started = automations::shared().start_now(id)?;
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
) -> Result<Value, String> {
    let intent = prompt.trim();
    if intent.is_empty() {
        return Err("describe the run first".into());
    }
    let backend = pick_design_backend(backend);
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
    let argv = automations::agent_command(&backend, &brief, None, None, 180)?;
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
    let (status, transcript, _) = drain_pty(&mut scratch, &argv, &cwd, 180, &node, &design_reader)?;
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

const DESIGN_PROMPT: &str = "You design a tokenstat workflow. Reply with a single JSON object and nothing else. No markdown. The object must match this shape: {\"name\": string, \"scope\": \"global\" or \"workspace\", \"budgetSeconds\": number, \"nodes\": [{\"id\": string, \"kind\": \"input\"|\"agent\"|\"automation\"|\"http\"|\"command\"|\"gate\", \"x\": number, \"y\": number, \"title\": string, \"backend\": string?, \"model\": string?, \"effort\": string?, \"prompt\": string?, \"wait\": \"exit\"|\"output\", \"automationId\": string?, \"method\": string?, \"url\": string?, \"body\": string?, \"command\": string?}], \"edges\": [{\"from\": string, \"to\": string, \"when\": \"ok\"|\"error\"|\"always\"}]}. Use {{input}} and {{nodeId.output}} in prompts. Do not execute anything. Do not invent MCP nodes.";

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
    if has_cycle(workflow) {
        return Err("a workflow cannot contain a cycle".into());
    }
    Ok(())
}

fn validate_node(node: &Node) -> Result<(), String> {
    match node.kind {
        NodeKind::Input | NodeKind::Gate => Ok(()),
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

fn has_cycle(workflow: &Workflow) -> bool {
    let mut adj: HashMap<&str, Vec<&str>> = HashMap::new();
    for edge in &workflow.edges {
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
    let done: HashMap<&str, &StepRecord> = run
        .steps
        .iter()
        .filter(|s| matches!(s.status.as_str(), "ok" | "error" | "stopped"))
        .map(|s| (s.node_id.as_str(), s))
        .collect();
    let started: HashSet<&str> = run.steps.iter().map(|s| s.node_id.as_str()).collect();
    let mut incoming: HashMap<&str, Vec<&Edge>> = HashMap::new();
    for edge in &workflow.edges {
        incoming.entry(edge.to.as_str()).or_default().push(edge);
    }
    let mut ready = Vec::new();
    for node in &workflow.nodes {
        if started.contains(node.id.as_str()) {
            continue;
        }
        let Some(edges) = incoming.get(node.id.as_str()) else {
            ready.push(node.id.clone());
            continue;
        };
        if edges.is_empty() {
            ready.push(node.id.clone());
            continue;
        }
        let all_ready = edges.iter().all(|edge| {
            let Some(pred) = done.get(edge.from.as_str()) else {
                return false;
            };
            edge_matches(edge.when, pred.status.as_str())
        });
        if all_ready {
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

fn remaining_can_never_run(workflow: &Workflow, run: &WorkflowRun) -> bool {
    let ready = ready_nodes(workflow, run);
    if !ready.is_empty() {
        return false;
    }
    let started: HashSet<&str> = run.steps.iter().map(|s| s.node_id.as_str()).collect();
    workflow
        .nodes
        .iter()
        .any(|n| !started.contains(n.id.as_str()))
}

fn edge_matches(when: EdgeWhen, status: &str) -> bool {
    match when {
        EdgeWhen::Always => matches!(status, "ok" | "error" | "stopped"),
        EdgeWhen::Ok => status == "ok",
        EdgeWhen::Error => status == "error",
    }
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
    match workflow.scope {
        WorkflowScope::Workspace => workflow
            .workspace_id
            .clone()
            .filter(|id| !id.is_empty())
            .ok_or_else(|| "a workspace workflow needs a workspace".into()),
        WorkflowScope::Global => requested
            .map(str::to_string)
            .filter(|id| !id.is_empty())
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
        NodeKind::Mcp => "mcp",
    }
}

fn cap_output(text: &str) -> String {
    if text.len() <= OUTPUT_CAP {
        text.to_string()
    } else {
        text[text.len() - OUTPUT_CAP..].to_string()
    }
}

fn remaining_budget(run: &WorkflowRun) -> u64 {
    // The whole run shares one budget. Per-step drain uses what is left.
    if run.budget_seconds == 0 {
        return 0;
    }
    let elapsed = ((now_ms() - run.started_at_ms).max(0) as u64) / 1000;
    run.budget_seconds.saturating_sub(elapsed).max(30)
}

fn pick_design_backend(requested: Option<&str>) -> String {
    if let Some(id) = requested.filter(|id| !id.is_empty()) {
        return id.to_string();
    }
    let ids: Vec<String> = automations::backends()
        .into_iter()
        .filter_map(|b| b.get("id").and_then(Value::as_str).map(str::to_string))
        .collect();
    for preferred in ["grok", "opencode", "claude"] {
        if ids.iter().any(|id| id == preferred) {
            return preferred.to_string();
        }
    }
    ids.into_iter().next().unwrap_or_else(|| "grok".into())
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

fn drain_pty(
    run: &mut WorkflowRun,
    argv: &[String],
    cwd: &str,
    budget_seconds: u64,
    node: &Node,
    reader: &str,
) -> Result<(String, String, Option<i32>), String> {
    let info = tokenstat_pty::manager()
        .spawn(&tokenstat_pty::Spawn {
            command: argv[0].clone(),
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
    run.live_pty_ids.push(info.id.clone());
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
    let matched = loop {
        if deadline.is_some_and(|d| Instant::now() >= d) {
            let _ = manager.kill(&info.id);
        }
        match manager.read_for_viewer(&info.id, reader, offset) {
            Ok(chunk) => {
                if !chunk.bytes.is_empty() {
                    raw.extend_from_slice(&chunk.bytes);
                    let piece = parser.push(&chunk.bytes);
                    if !piece.is_empty() {
                        readable.push_str(&piece);
                        if readable.len() > OUTPUT_CAP {
                            readable = cap_output(&readable);
                        }
                    }
                    offset = chunk.next_offset;
                    if wait_output {
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
        let alive = manager.info(&info.id).map(|i| i.alive).unwrap_or(false);
        if !alive {
            let settle = Instant::now() + EXIT_SETTLE;
            while Instant::now() < settle {
                if let Ok(chunk) = manager.read_for_viewer(&info.id, reader, offset) {
                    if !chunk.bytes.is_empty() {
                        raw.extend_from_slice(&chunk.bytes);
                        readable.push_str(&parser.push(&chunk.bytes));
                        offset = chunk.next_offset;
                    }
                }
                std::thread::sleep(DRAIN_POLL);
            }
            break false;
        }
        std::thread::sleep(DRAIN_POLL);
    };
    if readable.trim().is_empty() && !raw.is_empty() {
        readable = String::from_utf8_lossy(&raw).into_owned();
    }
    let info = manager.info(&info.id).ok();
    let exit = info.as_ref().and_then(|i| i.exit_code);
    let alive = info.as_ref().map(|i| i.alive).unwrap_or(false);
    if !matched {
        run.live_pty_ids
            .retain(|id| id != &info.as_ref().map(|i| i.id.clone()).unwrap_or_default());
        let _ = manager.close(&info.as_ref().map(|i| i.id.clone()).unwrap_or_default());
    }
    let status = if matched {
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
}
