// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Bounded, reported activity. Assistant prose and ordinary tool output are
//! never searched for goals, plans or agents.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

const STEPS: usize = 128;
const AGENTS: usize = 64;
const CALLS: usize = 256;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct Activity {
    pub goal: Option<Goal>,
    pub plan: Vec<Step>,
    pub plan_source: Option<String>,
    pub agents: Vec<Agent>,
    pub goal_reported: bool,
    pub plan_reported: bool,
    pub agents_reported: bool,
    pub partial: bool,
    /// Set by the store from the current run owner, never by agent output.
    pub live: bool,
    #[serde(skip)]
    calls: BTreeMap<String, Call>,
    #[serde(skip)]
    task_steps: Vec<(String, Step)>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Goal {
    pub objective: String,
    pub status: String,
    pub token_budget: Option<u64>,
    pub tokens_used: Option<u64>,
    pub time_budget_seconds: Option<u64>,
    pub time_used_seconds: Option<u64>,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Step {
    pub text: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Agent {
    pub id: String,
    pub name: Option<String>,
    pub task: Option<String>,
    pub status: String,
    pub model: Option<String>,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq)]
struct Call {
    tool: String,
    input: Value,
}

fn text(value: &Value, limit: usize) -> Option<String> {
    let value = value.as_str()?.trim();
    if value.is_empty()
        || value
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\t')
    {
        return None;
    }
    let mut end = value.len().min(limit);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    Some(value[..end].to_owned())
}

fn id(value: &Value) -> Option<String> {
    let result = text(value, 160)?;
    // Truncating an identity could join two agents or calls.
    (value.as_str()?.trim().len() <= 160 && !result.chars().any(char::is_control)).then_some(result)
}

fn step_status(value: &Value) -> String {
    match value.as_str() {
        Some("pending" | "not_started") => "pending",
        Some("inProgress" | "in_progress") => "inProgress",
        Some("completed" | "complete") => "completed",
        _ => "unknown",
    }
    .into()
}

fn agent_status(value: &Value) -> String {
    match value.as_str() {
        Some("pendingInit" | "pending" | "queued") => "pending",
        Some("running" | "in_progress" | "inProgress") => "running",
        Some("waiting" | "idle") => "waiting",
        Some("paused") => "waiting",
        Some("completed" | "complete" | "success") => "completed",
        Some("errored" | "error" | "failed") => "failed",
        Some("shutdown" | "interrupted" | "stopped" | "cancelled" | "canceled" | "killed") => {
            "stopped"
        }
        _ => "unknown",
    }
    .into()
}

fn goal_status(value: &Value) -> String {
    match value.as_str() {
        Some("active") => "active",
        Some("paused") => "paused",
        Some("blocked") => "blocked",
        Some("usageLimited") => "usageLimited",
        Some("budgetLimited") => "budgetLimited",
        Some("complete" | "completed") => "completed",
        _ => "unknown",
    }
    .into()
}

fn codex_agent_status(value: &Value) -> String {
    if value.is_string() {
        return agent_status(value);
    }
    if value["status"].is_string() {
        return agent_status(&value["status"]);
    }
    // Legacy Rust enum payloads carry terminal detail under one variant
    // key. Only the key is used; result and error text are never copied.
    if let Some(object) = value.as_object().filter(|object| object.len() == 1) {
        if let Some(key) = object.keys().next().filter(|key| {
            matches!(
                key.as_str(),
                "pendingInit"
                    | "running"
                    | "interrupted"
                    | "completed"
                    | "errored"
                    | "shutdown"
                    | "notFound"
            )
        }) {
            return agent_status(&json!(key));
        }
    }
    "unknown".into()
}

impl Activity {
    pub fn presentation(&mut self, current_run: bool, running: bool) {
        self.partial |= self.plan.len() > STEPS || self.agents.len() > AGENTS;
        self.plan.truncate(STEPS);
        self.agents.truncate(AGENTS);
        self.plan.retain_mut(|step| {
            let Some(bounded) = text(&json!(step.text), 1000) else {
                return false;
            };
            step.text = bounded;
            step.status = step_status(&json!(step.status));
            true
        });
        self.agents.retain_mut(|agent| {
            if id(&json!(agent.id)).is_none() {
                return false;
            }
            agent.name = agent
                .name
                .as_ref()
                .and_then(|value| text(&json!(value), 160));
            agent.task = agent
                .task
                .as_ref()
                .and_then(|value| text(&json!(value), 1200));
            agent.model = agent
                .model
                .as_ref()
                .and_then(|value| text(&json!(value), 160));
            agent.status = agent_status(&json!(agent.status));
            agent.source = if agent.source == "tool" {
                "tool"
            } else {
                "agent"
            }
            .into();
            true
        });
        if let Some(goal) = self.goal.as_mut() {
            if let Some(objective) = text(&json!(goal.objective), 4000) {
                goal.objective = objective;
                goal.status = goal_status(&json!(goal.status));
                goal.source = if goal.source == "tool" {
                    "tool"
                } else {
                    "agent"
                }
                .into();
            } else {
                self.goal = None;
                self.goal_reported = false;
            }
        }
        self.live = current_run && running;
        if running && !current_run {
            // The next run has reserved this chat but has not reported yet.
            self.plan.clear();
            self.plan_source = None;
            self.plan_reported = false;
            self.agents.clear();
            self.agents_reported = false;
        }
        if !self.live {
            for agent in &mut self.agents {
                if matches!(agent.status.as_str(), "pending" | "running" | "waiting") {
                    agent.status = "unknown".into();
                }
            }
        }
    }

    pub fn observe(&mut self, backend: &str, value: &Value) -> bool {
        let previous = self.clone();
        match backend {
            "codex" => self.codex(value),
            "claude" => self.claude(value),
            "cursor" => self.cursor(value),
            "grok" => self.grok(value),
            "opencode" | "opencode2" => self.opencode(backend, value),
            "agy" => self.agy(value),
            "muse" => self.muse(value),
            _ => {}
        }
        *self != previous
    }

    fn plan(&mut self, values: &Value, text_key: &str, source: &str) {
        let Some(values) = values.as_array() else {
            return;
        };
        self.partial |= values.len() > STEPS;
        self.plan = values
            .iter()
            .take(STEPS)
            .filter_map(|step| {
                Some(Step {
                    text: text(&step[text_key], 1000)?,
                    status: step_status(&step["status"]),
                })
            })
            .collect();
        self.plan_source = Some(source.into());
        self.plan_reported = true;
    }

    fn agent(&mut self, mut agent: Agent) {
        self.agents_reported = true;
        if let Some(previous) = self.agents.iter_mut().find(|old| old.id == agent.id) {
            agent.name = agent.name.or_else(|| previous.name.clone());
            agent.task = agent.task.or_else(|| previous.task.clone());
            agent.model = agent.model.or_else(|| previous.model.clone());
            *previous = agent;
        } else if self.agents.len() < AGENTS {
            self.agents.push(agent);
        } else {
            self.partial = true;
        }
    }

    fn codex(&mut self, value: &Value) {
        match value["type"].as_str() {
            Some("tokenstat.activity") => match value["kind"].as_str() {
                Some("goal") if value.get("goal").is_some() => {
                    self.reported_goal(&value["goal"], "agent");
                }
                Some("plan") => self.plan(&value["plan"], "step", "agent"),
                _ => {}
            },
            Some("item.started" | "item.updated" | "item.completed") => {
                let item = &value["item"];
                match item["type"].as_str() {
                    Some("todo_list") => {
                        if let Some(items) = item["items"].as_array() {
                            let steps = items.iter().take(STEPS).map(|step| json!({
                                "text":step["text"],
                                "status":if step["completed"] == true {"completed"} else {"pending"}
                            })).collect::<Vec<_>>();
                            self.partial |= items.len() > STEPS;
                            self.plan(&json!(steps), "text", "agent");
                        }
                    }
                    Some("collab_agent_tool_call" | "collab_tool_call") => self.codex_agents(item),
                    Some("sub_agent_activity") => {
                        let Some(agent_id) = id(&item["agentThreadId"]) else {
                            return;
                        };
                        let status = match item["kind"].as_str() {
                            Some("started") => "running",
                            Some("completed") => "completed",
                            Some("interrupted") => "stopped",
                            _ => "unknown",
                        };
                        self.agent(Agent {
                            id: agent_id,
                            name: text(&item["agentPath"], 160),
                            task: None,
                            status: status.into(),
                            model: text(&item["model"], 160),
                            source: "agent".into(),
                        });
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn reported_goal(&mut self, goal: &Value, source: &str) {
        if goal.is_null() {
            self.goal = None;
            self.goal_reported = true;
        } else if let Some(objective) = text(&goal["objective"], 4000) {
            self.goal = Some(Goal {
                objective,
                status: goal_status(&goal["status"]),
                token_budget: goal["tokenBudget"].as_u64(),
                tokens_used: goal["tokensUsed"].as_u64(),
                time_budget_seconds: None,
                time_used_seconds: goal["timeUsedSeconds"].as_u64(),
                source: source.into(),
            });
            self.goal_reported = true;
        }
    }

    fn codex_agents(&mut self, item: &Value) {
        let states = item["agentsStates"].as_object();
        let receivers = item["receiverThreadIds"].as_array();
        let mut agent_ids = Vec::new();
        if let Some(receivers) = receivers {
            self.partial |= receivers.len() > AGENTS;
            agent_ids.extend(receivers.iter().take(AGENTS).filter_map(id));
        }
        if let Some(states) = states {
            self.partial |= states.len() > AGENTS;
            for key in states.keys().take(AGENTS) {
                if let Some(key) = id(&json!(key))
                    && !agent_ids.contains(&key)
                {
                    agent_ids.push(key);
                }
            }
        }
        // Earlier app-server versions use a single recipient and an
        // optional singular agentStatus. Keep that explicit identity too.
        let singular = id(&item["newThreadId"]).or_else(|| id(&item["receiverThreadId"]));
        if let Some(singular) = singular.as_ref()
            && !agent_ids.contains(singular)
        {
            agent_ids.push(singular.clone());
        }
        self.partial |= agent_ids.len() > AGENTS;
        for agent_id in agent_ids.into_iter().take(AGENTS) {
            let state = states.and_then(|states| states.get(&agent_id));
            // A tool finishing does not mean its recipient has finished.
            let status = state
                .map(codex_agent_status)
                .or_else(|| {
                    (singular.as_ref() == Some(&agent_id))
                        .then(|| codex_agent_status(&item["agentStatus"]))
                })
                .unwrap_or_else(|| "unknown".into());
            let task = matches!(
                item["tool"].as_str(),
                Some("spawnAgent" | "followupTask" | "spawn_agent" | "followup_task")
            )
            .then(|| text(&item["prompt"], 1200))
            .flatten();
            self.agent(Agent {
                id: agent_id,
                name: None,
                task,
                status,
                model: text(&item["model"], 160),
                source: "agent".into(),
            });
        }
    }

    fn remember(&mut self, call_id: String, tool: &str, input: Value) {
        if self.calls.len() < CALLS || self.calls.contains_key(&call_id) {
            self.calls.insert(
                call_id,
                Call {
                    tool: tool.into(),
                    input,
                },
            );
        } else {
            self.partial = true;
        }
    }

    fn claude(&mut self, value: &Value) {
        // Subagent assistant records use parent_tool_use_id. Their todos are
        // not the main agent's plan.
        if value["type"] == "assistant" && value["parent_tool_use_id"].is_null() {
            if let Some(blocks) = value.pointer("/message/content").and_then(Value::as_array) {
                for block in blocks.iter().take(CALLS) {
                    if block["type"] != "tool_use" {
                        continue;
                    }
                    let Some(call_id) = id(&block["id"]) else {
                        continue;
                    };
                    let Some(tool) = block["name"].as_str() else {
                        continue;
                    };
                    let input = &block["input"];
                    match tool {
                        "TodoWrite" => {
                            if let Some(todos) = input["todos"].as_array() {
                                self.partial |= todos.len() > STEPS;
                                let todos: Vec<_> = todos.iter().take(STEPS).filter_map(|step| Some(json!({
                                    "content":text(&step["content"], 1000)?, "status":step_status(&step["status"])
                                }))).collect();
                                self.remember(call_id, tool, json!({"todos":todos}));
                            }
                        }
                        "Agent" | "Task" => {
                            self.agent(Agent {
                                id: call_id.clone(),
                                name: text(&input["name"], 160)
                                    .or_else(|| text(&input["subagent_type"], 160)),
                                task: text(&input["description"], 1200)
                                    .or_else(|| text(&input["prompt"], 1200)),
                                status: "pending".into(),
                                model: text(&input["model"], 160),
                                source: "tool".into(),
                            });
                            // Only a small allowlist survives the call join.
                            self.remember(
                                call_id,
                                tool,
                                json!({"run_in_background":input["run_in_background"]}),
                            );
                        }
                        "TaskCreate" | "TaskUpdate" | "TaskList" | "TaskGet" => {
                            self.remember(call_id, tool, json!({"taskId":id(&input["taskId"]),
                                "subject":text(&input["subject"], 1000), "status":text(&input["status"], 40)}));
                        }
                        _ => {}
                    }
                }
            }
        }
        if value["type"] == "user" {
            if let Some(blocks) = value.pointer("/message/content").and_then(Value::as_array) {
                for block in blocks.iter().take(CALLS) {
                    if block["type"] != "tool_result" {
                        continue;
                    }
                    let Some(call_id) = id(&block["tool_use_id"]) else {
                        continue;
                    };
                    let Some(call) = self.calls.remove(&call_id) else {
                        continue;
                    };
                    if call.tool == "TodoWrite" && block["is_error"] != true {
                        self.plan(&call.input["todos"], "content", "tool");
                    }
                    if matches!(
                        call.tool.as_str(),
                        "TaskCreate" | "TaskUpdate" | "TaskList" | "TaskGet"
                    ) && block["is_error"] != true
                    {
                        self.claude_tasks(&call, &value["tool_use_result"], block);
                    }
                    let agent_id = call.input["agentId"].as_str().unwrap_or(&call_id);
                    if let Some(agent) = self.agents.iter_mut().find(|agent| agent.id == agent_id) {
                        agent.status = if block["is_error"] == true {
                            "failed"
                        } else if call.input["run_in_background"] == true {
                            // Background launch completion is not child
                            // completion. Keep a native status if known.
                            agent.status.as_str()
                        } else {
                            "completed"
                        }
                        .into();
                    }
                }
            }
        }
        if value["type"] == "system" {
            let subtype = value["subtype"].as_str().unwrap_or("");
            if matches!(
                subtype,
                "task_started" | "task_progress" | "task_updated" | "task_notification"
            ) {
                let Some(task_id) = id(&value["task_id"]) else {
                    return;
                };
                let call_id = id(&value["tool_use_id"]);
                let known = self
                    .agents
                    .iter()
                    .any(|agent| agent.id == task_id || call_id.as_ref() == Some(&agent.id));
                if !known && !(subtype == "task_started" && value["task_type"] == "local_agent") {
                    return;
                }
                if subtype == "task_started"
                    && value["task_type"]
                        .as_str()
                        .is_some_and(|kind| kind != "local_agent")
                {
                    return;
                }
                // Replace the provisional call identity with the real task id.
                if let Some(call_id) = call_id.as_deref() {
                    if call_id != task_id
                        && let Some(index) =
                            self.agents.iter().position(|agent| agent.id == call_id)
                    {
                        let mut provisional = self.agents.remove(index);
                        provisional.id = task_id.clone();
                        self.agent(provisional);
                    }
                    if let Some(call) = self.calls.get_mut(call_id) {
                        call.input["agentId"] = json!(task_id);
                    }
                }
                let status = match subtype {
                    "task_started" | "task_progress" => "running".into(),
                    "task_updated" => agent_status(&value["patch"]["status"]),
                    _ => agent_status(&value["status"]),
                };
                let status = if subtype == "task_updated" && value["patch"].get("status").is_none()
                {
                    self.agents
                        .iter()
                        .find(|agent| agent.id == task_id)
                        .map(|agent| agent.status.clone())
                        .unwrap_or(status)
                } else {
                    status
                };
                self.agent(Agent {
                    id: task_id,
                    name: text(&value["subagent_type"], 160),
                    task: text(&value["description"], 1200)
                        .or_else(|| text(&value["patch"]["description"], 1200)),
                    status,
                    model: None,
                    source: "agent".into(),
                });
            }
        }
    }

    fn claude_tasks(&mut self, call: &Call, result: &Value, block: &Value) {
        let content = block["content"]
            .as_str()
            .or_else(|| block.pointer("/content/0/text").and_then(Value::as_str))
            .unwrap_or("");
        match call.tool.as_str() {
            "TaskCreate" => {
                let task_id = id(&result["task"]["id"]).or_else(|| {
                    let prefix = content.strip_prefix("Task #")?;
                    let (task_id, _) = prefix.split_once(" created successfully:")?;
                    id(&json!(task_id))
                });
                let subject = text(&result["task"]["subject"], 1000)
                    .or_else(|| text(&call.input["subject"], 1000));
                if let (Some(task_id), Some(subject)) = (task_id, subject) {
                    self.task_step(
                        task_id,
                        Step {
                            text: subject,
                            status: "pending".into(),
                        },
                    );
                }
            }
            "TaskUpdate" => {
                let Some(task_id) = id(&call.input["taskId"]) else {
                    return;
                };
                if result["success"] != true
                    && !content.starts_with(&format!("Updated task #{task_id} "))
                {
                    return;
                }
                if call.input["status"] == "deleted" {
                    self.task_steps.retain(|(id, _)| id != &task_id);
                    self.publish_tasks();
                    return;
                }
                let previous = self
                    .task_steps
                    .iter()
                    .find(|(id, _)| id == &task_id)
                    .map(|(_, step)| step.clone());
                let subject = text(&call.input["subject"], 1000)
                    .or_else(|| previous.as_ref().map(|step| step.text.clone()));
                if let Some(subject) = subject {
                    let status = if call.input["status"].is_string() {
                        step_status(&call.input["status"])
                    } else {
                        previous
                            .map(|step| step.status)
                            .unwrap_or_else(|| "unknown".into())
                    };
                    self.task_step(
                        task_id,
                        Step {
                            text: subject,
                            status,
                        },
                    );
                }
            }
            "TaskGet" => {
                let task = &result["task"];
                if let (Some(task_id), Some(subject)) =
                    (id(&task["id"]), text(&task["subject"], 1000))
                {
                    self.task_step(
                        task_id,
                        Step {
                            text: subject,
                            status: step_status(&task["status"]),
                        },
                    );
                }
            }
            "TaskList" => {
                let tasks = result
                    .get("tasks")
                    .and_then(Value::as_array)
                    .or_else(|| result.as_array());
                if let Some(tasks) = tasks {
                    self.partial |= tasks.len() > STEPS;
                    self.task_steps = tasks
                        .iter()
                        .take(STEPS)
                        .filter_map(|task| {
                            Some((
                                id(&task["id"])?,
                                Step {
                                    text: text(&task["subject"], 1000)?,
                                    status: step_status(&task["status"]),
                                },
                            ))
                        })
                        .collect();
                    self.publish_tasks();
                }
            }
            _ => {}
        }
    }

    fn task_step(&mut self, task_id: String, step: Step) {
        if let Some((_, previous)) = self.task_steps.iter_mut().find(|(id, _)| id == &task_id) {
            *previous = step;
        } else if self.task_steps.len() < STEPS {
            self.task_steps.push((task_id, step));
        } else {
            self.partial = true;
        }
        self.publish_tasks();
    }

    fn publish_tasks(&mut self) {
        self.plan = self
            .task_steps
            .iter()
            .map(|(_, step)| step.clone())
            .collect();
        self.plan_source = Some("tool".into());
        self.plan_reported = true;
    }

    fn grok(&mut self, value: &Value) {
        let update = value.pointer("/params/update").unwrap_or(value);
        let kind = update["sessionUpdate"]
            .as_str()
            .or_else(|| update["type"].as_str());
        match kind {
            Some("plan") => self.plan(&update["entries"], "content", "agent"),
            Some("subagent_spawned" | "subagent_finished") => {
                let Some(agent_id) = id(&update["subagent_id"]) else {
                    return;
                };
                let status = if kind == Some("subagent_spawned") {
                    "running".into()
                } else {
                    agent_status(&update["status"])
                };
                self.agent(Agent {
                    id: agent_id,
                    name: text(&update["subagent_type"], 160),
                    task: text(&update["description"], 1200),
                    status,
                    model: text(&update["model"], 160),
                    source: "agent".into(),
                });
            }
            _ => {}
        }
    }

    fn agy(&mut self, value: &Value) {
        if value["event"] != "step_update" {
            return;
        }
        let Some(agents) = value
            .pointer("/step_update/subagent_info/subagents")
            .and_then(Value::as_array)
        else {
            return;
        };
        self.partial |= agents.len() > AGENTS;
        for agent in agents.iter().take(AGENTS) {
            let Some(agent_id) = id(&agent["conversation_id"]) else {
                continue;
            };
            // The containing spawn step's DONE is not a child completion.
            self.agent(Agent {
                id: agent_id,
                name: text(&agent["type_name"], 160),
                task: text(&agent["role"], 1200),
                status: "unknown".into(),
                model: None,
                source: "agent".into(),
            });
        }
        self.agents_reported = true;
    }

    fn muse(&mut self, value: &Value) {
        let payload = &value["payload"];
        let event = &payload["event"];
        if value["payload_type"] == "todo.snapshot.updated" {
            self.plan(&payload["items"], "text", "agent");
        } else if value["payload_type"] == "runtime.session"
            && event["kind"] == "todo_snapshot_updated"
        {
            self.plan(&event["items"], "text", "agent");
        }
        if value["payload_type"] == "session.goal_control.applied"
            && payload["kind"] == "goal_control_applied"
        {
            let record = &payload["record"];
            if record["action"] == "clear" {
                self.reported_goal(&Value::Null, "agent");
            } else if record.get("goal").is_some() {
                self.reported_goal(&record["goal"], "agent");
            }
        }
        // Runtime task lifecycle also contains ordinary tools. Only the
        // explicit subagent control record establishes a child agent.
        if payload["kind"] != "subagent_control" {
            return;
        }
        let record = &payload["record"];
        let Some(agent_id) = id(&record["subagent_id"]) else {
            return;
        };
        let status = match record["kind"].as_str() {
            Some("spawn_accepted") => "pending".into(),
            Some("start_attested") => "running".into(),
            Some("status_updated") => match record["control_status"].as_str() {
                Some("accepted" | "starting") => "pending".into(),
                Some("running") => "running".into(),
                _ => self
                    .agents
                    .iter()
                    .find(|agent| agent.id == agent_id)
                    .map(|agent| agent.status.clone())
                    .unwrap_or_else(|| "unknown".into()),
            },
            Some("result_ready") => if record["error_kind"].is_string() {
                "failed"
            } else {
                "completed"
            }
            .into(),
            _ => return,
        };
        self.agent(Agent {
            id: agent_id,
            name: text(&record["role"], 160),
            task: text(&record["objective"], 1200),
            status,
            model: None,
            source: "agent".into(),
        });
    }

    fn cursor(&mut self, value: &Value) {
        if value["type"] != "tool_call" {
            return;
        }
        let map = &value["tool_call"];
        if value["subtype"] == "started" {
            let task = &map["taskToolCall"];
            let Some(call_id) = id(&value["call_id"]) else {
                return;
            };
            if !task.is_object() {
                return;
            }
            let input = &task["args"];
            let agent_id = id(&input["agentId"])
                .or_else(|| id(&input["resume"]))
                .unwrap_or_else(|| call_id.clone());
            self.agent(Agent {
                id: agent_id.clone(),
                name: text(&input["subagentType"], 160),
                task: text(&input["description"], 1200).or_else(|| text(&input["prompt"], 1200)),
                status: "pending".into(),
                model: text(&input["model"], 160),
                source: "tool".into(),
            });
            self.remember(call_id, "cursorTask", json!({"agentId":agent_id}));
            return;
        }
        if value["subtype"] != "completed" {
            return;
        }
        for tool in [
            "updateTodosToolCall",
            "readTodosToolCall",
            "createPlanToolCall",
        ] {
            let call = &map[tool];
            if call.is_null() {
                continue;
            }
            let result = &call["result"]["success"];
            if !result.is_object() {
                continue;
            }
            // Full successful result lists are authoritative even for a
            // merge request. Never replace a plan with just the merge input.
            let todos = result
                .get("todos")
                .or_else(|| (tool == "createPlanToolCall").then(|| &call["args"]["todos"]));
            if let Some(todos) = todos.and_then(Value::as_array) {
                self.partial |= todos.len() > STEPS;
                let entries: Vec<_> = todos
                    .iter()
                    .take(STEPS)
                    .map(|step| {
                        json!({
                            "content":step["content"],"status":cursor_todo_status(&step["status"])
                        })
                    })
                    .collect();
                self.plan(&json!(entries), "content", "tool");
            }
        }
        let create = &map["createGoalToolCall"];
        if create["result"]["success"].is_object() {
            if let Some(objective) = text(&create["args"]["objective"], 4000) {
                self.goal = Some(Goal {
                    objective,
                    status: "active".into(),
                    token_budget: None,
                    tokens_used: None,
                    time_budget_seconds: None,
                    time_used_seconds: None,
                    source: "tool".into(),
                });
                self.goal_reported = true;
            }
        }
        let update = &map["updateGoalToolCall"];
        if update["result"]["success"].is_object() {
            let status = &update["result"]["success"]["status"];
            let status = if status.is_null() {
                &update["args"]["status"]
            } else {
                status
            };
            let status = match status.as_str() {
                Some("ACTIVE" | "GOAL_STATUS_ACTIVE" | "active") => "active",
                Some("PAUSED" | "GOAL_STATUS_PAUSED" | "paused") => "paused",
                Some("COMPLETE" | "GOAL_STATUS_COMPLETE" | "complete" | "completed") => "completed",
                Some("CLEARED" | "GOAL_STATUS_CLEARED" | "cleared") => "cleared",
                _ => match status.as_u64() {
                    Some(1) => "active",
                    Some(2) => "paused",
                    Some(3) => "completed",
                    Some(4) => "cleared",
                    _ => "unknown",
                },
            };
            if status == "cleared" {
                self.goal = None;
                self.goal_reported = true;
            } else if let Some(goal) = self.goal.as_mut() {
                goal.status = status.into();
                self.goal_reported = true;
            }
        }
        let task = &map["taskToolCall"];
        if !task.is_object() {
            return;
        }
        let input = &task["args"];
        let result = &task["result"];
        let provisional = id(&value["call_id"])
            .and_then(|call_id| self.calls.remove(&call_id))
            .filter(|call| call.tool == "cursorTask")
            .and_then(|call| id(&call.input["agentId"]));
        let Some(agent_id) = id(&result["success"]["agentId"])
            .or_else(|| id(&input["agentId"]))
            .or_else(|| id(&input["resume"]))
            .or_else(|| provisional.clone())
            .or_else(|| id(&value["call_id"]))
        else {
            return;
        };
        if let Some(provisional) = provisional.filter(|provisional| provisional != &agent_id) {
            if let Some(index) = self.agents.iter().position(|agent| agent.id == provisional) {
                let mut agent = self.agents.remove(index);
                agent.id = agent_id.clone();
                self.agent(agent);
            }
        }
        let status = if result["error"].is_object() {
            "failed"
        } else if result["success"].is_object() {
            if result["success"]["isBackground"] == true {
                "running"
            } else {
                "completed"
            }
        } else {
            "unknown"
        };
        self.agent(Agent {
            id: agent_id,
            name: text(&input["subagentType"], 160),
            task: text(&input["description"], 1200).or_else(|| text(&input["prompt"], 1200)),
            status: status.into(),
            model: text(&input["model"], 160),
            source: "tool".into(),
        });
    }

    fn opencode(&mut self, backend: &str, value: &Value) {
        if value["type"] != "tool_use" {
            return;
        }
        let part = value.get("part").unwrap_or(value);
        let tool = part["tool"].as_str().unwrap_or("");
        let state = &part["state"];
        let input = state
            .get("input")
            .or_else(|| part.get("input"))
            .unwrap_or(&Value::Null);
        if tool == "todowrite" && state["status"] == "completed" {
            self.plan(&input["todos"], "content", "tool");
        }
        if tool == "task" {
            let metadata = state
                .pointer("/metadata/metadata")
                .filter(|value| value.is_object())
                .unwrap_or(&state["metadata"]);
            let Some(call_id) = id(&metadata["sessionId"])
                .or_else(|| id(&part["callID"]))
                .or_else(|| id(&part["id"]))
            else {
                return;
            };
            let status = if state["status"] == "completed" && metadata["background"] == true {
                "running".into()
            } else if backend == "opencode2"
                && state["status"] == "completed"
                && !metadata["background"].is_boolean()
            {
                // V2's CLI reports tool completion; absent an explicit child
                // lifecycle field, it cannot establish child completion.
                "unknown".into()
            } else {
                agent_status(&state["status"])
            };
            self.agent(Agent {
                id: call_id,
                name: text(&input["subagent_type"], 160).or_else(|| text(&input["agent"], 160)),
                task: text(&input["description"], 1200).or_else(|| text(&input["prompt"], 1200)),
                status,
                model: None,
                source: "tool".into(),
            });
        }
    }
}

fn cursor_todo_status(value: &Value) -> &'static str {
    match value.as_str() {
        Some("PENDING" | "TODO_STATUS_PENDING" | "pending") => "pending",
        Some("IN_PROGRESS" | "TODO_STATUS_IN_PROGRESS" | "in_progress") => "inProgress",
        Some("COMPLETED" | "TODO_STATUS_COMPLETED" | "completed") => "completed",
        _ => match value.as_u64() {
            Some(1) => "pending",
            Some(2) => "inProgress",
            Some(3) => "completed",
            _ => "unknown",
        },
    }
}

/// Keep app-server ownership checks at its boundary, before normalizing a
/// notification into the per-turn NDJSON stream. Missing identity is not a
/// match for a different thread's activity.
pub(crate) fn codex_notification(value: &Value, thread: &str, turn: &str) -> Option<Value> {
    let params = &value["params"];
    if params["threadId"].as_str() != Some(thread) {
        return None;
    }
    match value["method"].as_str()? {
        "thread/goal/updated" if params["goal"]["threadId"].as_str() == Some(thread) => {
            Some(json!({"type":"tokenstat.activity","kind":"goal","goal":params["goal"]}))
        }
        "thread/goal/cleared" => {
            Some(json!({"type":"tokenstat.activity","kind":"goal","goal":null}))
        }
        "turn/plan/updated" if !turn.is_empty() && params["turnId"].as_str() == Some(turn) => {
            Some(json!({"type":"tokenstat.activity","kind":"plan","plan":params["plan"]}))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn goal_absence_is_distinct_from_zero_and_clear_is_reported() {
        let mut activity = Activity::default();
        assert!(!activity.goal_reported);
        activity.observe("codex", &json!({"type":"tokenstat.activity","kind":"goal","goal":{"objective":"Finish this","status":"usageLimited","tokensUsed":0}}));
        let goal = activity.goal.as_ref().unwrap();
        assert_eq!(goal.tokens_used, Some(0));
        assert_eq!(goal.token_budget, None);
        assert_eq!(goal.status, "usageLimited");
        activity.observe(
            "codex",
            &json!({"type":"tokenstat.activity","kind":"goal","goal":null}),
        );
        assert!(activity.goal_reported);
        assert!(activity.goal.is_none());
    }

    #[test]
    fn codex_notifications_require_owned_thread_and_plan_turn() {
        let mut plan = json!({"method":"turn/plan/updated","params":{"threadId":"mine","turnId":"now","plan":[{"step":"Ship","status":"inProgress"}]}});
        assert!(codex_notification(&plan, "other", "now").is_none());
        assert!(codex_notification(&plan, "mine", "old").is_none());
        let mut activity = Activity::default();
        activity.observe("codex", &codex_notification(&plan, "mine", "now").unwrap());
        assert_eq!(activity.plan[0].status, "inProgress");
        plan["params"]["turnId"] = json!(null);
        assert!(codex_notification(&plan, "mine", "now").is_none());
        let goal = json!({"method":"thread/goal/updated","params":{"threadId":"mine","goal":{"threadId":"other","objective":"wrong"}}});
        assert!(codex_notification(&goal, "mine", "now").is_none());
    }

    #[test]
    fn collaboration_completion_is_not_agent_completion() {
        let mut activity = Activity::default();
        activity.observe("codex", &json!({"type":"item.completed","item":{"type":"collab_agent_tool_call","tool":"spawnAgent","status":"completed","prompt":"Inspect parser","receiverThreadIds":["child"],"model":"model","agentsStates":{"child":{"status":"running"}}}}));
        assert_eq!(activity.agents[0].status, "running");
        assert_eq!(activity.agents[0].task.as_deref(), Some("Inspect parser"));
        activity.observe("codex", &json!({"type":"item.completed","item":{"type":"collab_agent_tool_call","tool":"wait","status":"completed","receiverThreadIds":["child"],"agentsStates":{"child":{"status":"completed","message":"full output is private"}}}}));
        assert_eq!(activity.agents.len(), 1);
        assert_eq!(activity.agents[0].status, "completed");
        assert!(
            !serde_json::to_string(&activity)
                .unwrap()
                .contains("full output")
        );
    }

    #[test]
    fn legacy_collaboration_uses_recipient_status_without_inventing_completion() {
        let mut activity = Activity::default();
        activity.observe("codex", &json!({"type":"item.completed","item":{"type":"collab_tool_call","tool":"spawnAgent","status":"completed","newThreadId":"legacy","prompt":"Review"}}));
        assert_eq!(activity.agents[0].id, "legacy");
        assert_eq!(activity.agents[0].status, "unknown");
        activity.observe("codex", &json!({"type":"item.completed","item":{"type":"collab_tool_call","tool":"wait","status":"completed","receiverThreadId":"legacy","agentStatus":{"status":"running"}}}));
        assert_eq!(activity.agents[0].status, "running");
        activity.observe("codex", &json!({"type":"item.completed","item":{"type":"collab_tool_call","tool":"wait","status":"completed","receiverThreadId":"legacy","agentStatus":{"completed":"private result"}}}));
        assert_eq!(activity.agents[0].status, "completed");
        assert_eq!(activity.agents.len(), 1);
        assert!(
            !serde_json::to_string(&activity)
                .unwrap()
                .contains("private result")
        );
    }

    #[test]
    fn stale_running_agents_are_unknown_and_new_turn_hides_old_plan() {
        let mut activity = Activity::default();
        activity.observe("opencode", &json!({"type":"tool_use","part":{"id":"part","callID":"agent","tool":"task","state":{"status":"running","input":{"description":"Review"}}}}));
        activity.observe(
            "grok",
            &json!({"type":"plan","entries":[{"content":"Review","status":"in_progress"}]}),
        );
        activity.presentation(true, false);
        assert_eq!(activity.agents[0].status, "unknown");
        assert!(activity.plan_reported);
        activity.presentation(false, true);
        assert!(!activity.live);
        assert!(activity.plan.is_empty());
        assert!(!activity.plan_reported);
        assert!(activity.agents.is_empty());
    }

    #[test]
    fn prose_nested_tool_outputs_and_subagent_todos_are_not_main_activity() {
        let mut activity = Activity::default();
        for value in [
            json!({"type":"assistant","message":{"content":[{"type":"text","text":"Goal: hello; plan: ship"}]}}),
            json!({"type":"user","message":{"content":[{"type":"tool_result","content":{"type":"plan","entries":[{"content":"fake"}]}}]}}),
            json!({"type":"assistant","parent_tool_use_id":"child","message":{"content":[{"type":"tool_use","id":"todos","name":"TodoWrite","input":{"todos":[{"content":"child plan","status":"pending"}]}}]}}),
        ] {
            activity.observe("claude", &value);
        }
        assert_eq!(activity, Activity::default());
    }

    #[test]
    fn activity_is_bounded_and_persisted_without_ephemeral_call_input() {
        let mut activity = Activity::default();
        let entries: Vec<_> = (0..200)
            .map(|_| json!({"content":"🦀".repeat(400),"status":"unexpected"}))
            .collect();
        activity.observe("grok", &json!({"type":"plan","entries":entries}));
        assert_eq!(activity.plan.len(), STEPS);
        assert_eq!(activity.plan[0].text.len(), 1000);
        assert_eq!(activity.plan[0].status, "unknown");
        assert!(activity.partial);
        let restored: Activity =
            serde_json::from_str(&serde_json::to_string(&activity).unwrap()).unwrap();
        assert_eq!(restored, activity);
    }

    #[test]
    fn claude_correlates_local_agents_and_successful_task_tools() {
        let mut activity = Activity::default();
        activity.observe("claude", &json!({"type":"system","subtype":"task_started","task_id":"bash","task_type":"local_bash","description":"not a child agent"}));
        assert!(!activity.agents_reported);
        activity.observe("claude", &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent-call","name":"Agent","input":{"description":"Review parser","subagent_type":"reviewer","run_in_background":true,"secret":"ignored"}}]}}));
        activity.observe("claude", &json!({"type":"system","subtype":"task_started","task_id":"child","tool_use_id":"agent-call","task_type":"local_agent","subagent_type":"reviewer","description":"Review parser"}));
        activity.observe("claude", &json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent-call","content":"Launched"}]}}));
        assert_eq!(activity.agents.len(), 1);
        assert_eq!(activity.agents[0].id, "child");
        assert_eq!(activity.agents[0].status, "running");
        activity.observe("claude", &json!({"type":"system","subtype":"task_notification","task_id":"child","status":"completed","summary":"not copied"}));
        assert_eq!(activity.agents[0].status, "completed");
        activity.observe("claude", &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"resume-call","name":"Agent","input":{"description":"Continue review","resume":"child","model":"review-model","run_in_background":true}}]}}));
        activity.observe("claude", &json!({"type":"system","subtype":"task_started","task_id":"child","tool_use_id":"resume-call","task_type":"local_agent","description":"Continue review"}));
        assert_eq!(
            activity.agents.len(),
            1,
            "resuming a native task merges its provisional call id"
        );
        assert_eq!(activity.agents[0].id, "child");
        assert_eq!(activity.agents[0].status, "running");
        assert_eq!(activity.agents[0].model.as_deref(), Some("review-model"));
        activity.observe("claude", &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"create","name":"TaskCreate","input":{"subject":"Verify parser"}}]}}));
        assert!(!activity.plan_reported);
        activity.observe("claude", &json!({"type":"user","tool_use_result":{"task":{"id":"1","subject":"Verify parser"}},"message":{"content":[{"type":"tool_result","tool_use_id":"create","content":"Task #1 created successfully: Verify parser"}]}}));
        assert_eq!(activity.plan[0].status, "pending");
        activity.observe("claude", &json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"update","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}));
        activity.observe("claude", &json!({"type":"user","tool_use_result":{"success":true,"taskId":"1"},"message":{"content":[{"type":"tool_result","tool_use_id":"update","content":"Updated task #1 status"}]}}));
        assert_eq!(activity.plan[0].status, "inProgress");
        assert!(
            !serde_json::to_string(&activity)
                .unwrap()
                .contains("ignored")
        );
    }

    #[test]
    fn cursor_uses_full_successful_todos_and_preserves_background_children() {
        let mut activity = Activity::default();
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"started","tool_call":{"createGoalToolCall":{"args":{"objective":"not yet accepted"}}}}));
        assert!(!activity.goal_reported);
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"completed","tool_call":{"createGoalToolCall":{"args":{"objective":"Ship"},"result":{"success":{}}}}}));
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"completed","tool_call":{"updateTodosToolCall":{"args":{"merge":true,"todos":[{"content":"one patch"}]},"result":{"success":{"todos":[{"content":"Whole plan","status":"IN_PROGRESS"},{"content":"Existing step","status":3}]}}}}}));
        assert_eq!(activity.plan.len(), 2);
        assert_eq!(activity.plan[0].status, "inProgress");
        assert_eq!(activity.plan[1].status, "completed");
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"started","call_id":"call","tool_call":{"taskToolCall":{"args":{"description":"Review","subagentType":"reviewer"}}}}));
        assert_eq!(activity.agents[0].status, "pending");
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"completed","call_id":"call","tool_call":{"taskToolCall":{"args":{"description":"Review","subagentType":"reviewer"},"result":{"success":{"agentId":"child","isBackground":true}}}}}));
        assert_eq!(activity.agents[0].status, "running");
        assert_eq!(activity.agents[0].id, "child");
        assert_eq!(activity.agents.len(), 1);
        activity.observe("cursor", &json!({"type":"tool_call","subtype":"completed","tool_call":{"updateGoalToolCall":{"args":{"status":4},"result":{"success":{"status":4}}}}}));
        assert!(activity.goal.is_none());
        assert!(activity.goal_reported);
    }

    #[test]
    fn grok_and_muse_native_activity_is_not_generic_task_lifecycle() {
        let mut activity = Activity::default();
        activity.observe("grok", &json!({"params":{"update":{"sessionUpdate":"plan","entries":[{"content":"Inspect","status":"in_progress"}]}}}));
        activity.observe("grok", &json!({"type":"subagent_spawned","subagent_id":"grok-child","description":"Inspect","subagent_type":"explore","model":"model"}));
        assert_eq!(activity.agents[0].status, "running");
        activity.observe("grok", &json!({"type":"subagent_finished","subagent_id":"grok-child","status":"cancelled","output":"ignored output"}));
        assert_eq!(activity.agents[0].status, "stopped");
        let mut muse = Activity::default();
        muse.observe("muse", &json!({"payload_type":"task.lifecycle.scheduled","payload":{"task_id":"shell","event":{"task_kind":"tool.bash"}}}));
        assert!(!muse.agents_reported);
        muse.observe("muse", &json!({"payload_type":"runtime.session","payload":{"event":{"kind":"todo_snapshot_updated","items":[{"text":"Verify","status":"in_progress"}]}}}));
        assert_eq!(muse.plan[0].status, "inProgress");
        muse.observe("muse", &json!({"payload_type":"session.goal_control.applied","payload":{"kind":"goal_control_applied","record":{"action":"pause","goal":{"objective":"Ship","status":"paused","percent_complete":30,"current_work":"not copied"}}}}));
        assert_eq!(muse.goal.as_ref().unwrap().objective, "Ship");
        assert_eq!(muse.goal.as_ref().unwrap().status, "paused");
        assert_eq!(muse.goal.as_ref().unwrap().tokens_used, None);
        for (kind, status) in [
            ("spawn_accepted", "pending"),
            ("start_attested", "running"),
            ("result_ready", "completed"),
        ] {
            muse.observe("muse", &json!({"payload_type":format!("subagent.control.{kind}"),"payload":{"kind":"subagent_control","record":{"kind":kind,"subagent_id":"muse-child","role":"reviewer","objective":"Review","error_kind":null}}}));
            assert_eq!(muse.agents[0].status, status);
        }
        assert_eq!(muse.agents.len(), 1);
    }

    #[test]
    fn open_code_background_and_agy_spawn_steps_do_not_claim_child_completion() {
        let mut activity = Activity::default();
        activity.observe("opencode", &json!({"type":"tool_use","part":{"id":"call","tool":"task","state":{"status":"completed","input":{"description":"Review"},"metadata":{"sessionId":"child","background":true}}}}));
        assert_eq!(activity.agents[0].id, "child");
        assert_eq!(activity.agents[0].status, "running");
        activity.observe("opencode2", &json!({"type":"tool_use","part":{"id":"call2","tool":"task","state":{"status":"completed","input":{"description":"Review","agent":"reviewer"},"metadata":{"metadata":{"sessionId":"child2"}}}}}));
        assert_eq!(activity.agents[1].status, "unknown");
        activity.observe("agy", &json!({"event":"step_update","step_update":{"state":"DONE","subagent_info":{"subagents":[{"conversation_id":"agy-child","type_name":"reviewer","role":"Review","log_uri":"not copied"}]}}}));
        assert_eq!(activity.agents[2].status, "unknown");
        assert!(
            !serde_json::to_string(&activity)
                .unwrap()
                .contains("not copied")
        );
    }

    #[test]
    fn split_protocol_records_publish_activity_without_transcript_text() {
        let mut parser = crate::transcript::Parser::new("codex");
        let record = json!({"type":"tokenstat.activity","kind":"plan","plan":[{"step":"Inspect 🦀","status":"inProgress"}]}).to_string() + "\n";
        let split = record.find('🦀').unwrap() + 1;
        assert!(parser.push_events(&record.as_bytes()[..split]).is_empty());
        assert!(parser.take_inspection().is_none());
        assert!(parser.push_events(&record.as_bytes()[split..]).is_empty());
        let snapshot = parser.take_inspection().unwrap();
        assert_eq!(snapshot.activity.plan[0].text, "Inspect 🦀");
        assert_eq!(snapshot.activity.plan[0].status, "inProgress");
    }
}
