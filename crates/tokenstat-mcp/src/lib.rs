// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! MCP server over the local tokenstat archive, and (when hostd is up) the
//! workspaces, tasks, notes, automations and workflows.
//!
//! Speaks newline-delimited JSON-RPC 2.0 over MCP stdio. Archive
//! tools stay local. Task, automation and workflow tools talk to the host
//! helper over its unix socket, never the network. Nothing is sent off the
//! machine by the transport; delegated agents and workflows can use the network.

#![forbid(unsafe_code)]

use std::io::{self, BufRead, Write};
#[cfg(unix)]
use std::path::PathBuf;

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokenstat_core::{Engine, GroupBy, Query, VERSION};

/// Serve MCP on stdin/stdout until EOF.
pub fn serve() -> Result<()> {
    let mut engine = Engine::open(None, None).context("opening tokenstat archive")?;
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    let mut reader = stdin.lock();

    loop {
        let Some(msg) = read_message(&mut reader)? else {
            break;
        };
        let response = handle(&mut engine, msg);
        write_message(&mut stdout, &response)?;
    }
    Ok(())
}

fn handle(engine: &mut Engine, msg: Value) -> Value {
    let id = msg.get("id").cloned().unwrap_or(Value::Null);
    let method = msg
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();

    if msg.get("id").is_none() {
        return Value::Null;
    }

    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2025-06-18",
            "capabilities": { "tools": {}, "resources": {} },
            "serverInfo": {
                "name": "tokenstat",
                "version": VERSION,
            },
            "instructions": GUIDE
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "tools/call" => match call_tool(engine, msg.get("params")) {
            Ok(result) => Ok(result),
            Err(error) => {
                Ok(json!({"isError": true, "content": [{"type": "text", "text": error}]}))
            }
        },
        "resources/list" => Ok(
            json!({ "resources": [{"uri": "tokenstat://guide", "name": "tokenstat agent guide", "description": "Connection, workspace IDs, tasks, notes and execution workflow", "mimeType": "text/markdown"}] }),
        ),
        "resources/read" => match msg.pointer("/params/uri").and_then(Value::as_str) {
            Some("tokenstat://guide") => Ok(
                json!({"contents": [{"uri": "tokenstat://guide", "mimeType": "text/markdown", "text": GUIDE}]}),
            ),
            _ => Err("unknown resource; read tokenstat://guide".into()),
        },
        "prompts/list" => Ok(json!({ "prompts": [] })),
        other => Err(format!("method not found: {other}")),
    };

    match result {
        Ok(value) => json!({ "jsonrpc": "2.0", "id": id, "result": value }),
        Err(e) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32601, "message": e }
        }),
    }
}

fn tools() -> Vec<Value> {
    let mut catalog = vec![
        tool(
            "totals",
            "Headline token counters for the local archive (optional since/until/model/project filters).",
            json!({
                "type": "object",
                "properties": {
                    "since": { "type": "string", "description": "YYYY-MM-DD" },
                    "until": { "type": "string", "description": "YYYY-MM-DD" },
                    "model": { "type": "string" },
                    "project": { "type": "string" }
                }
            }),
        ),
        tool(
            "models",
            "Token usage grouped by model, highest volume first.",
            json!({
                "type": "object",
                "properties": {
                    "since": { "type": "string" },
                    "until": { "type": "string" },
                    "limit": { "type": "integer", "minimum": 1 }
                }
            }),
        ),
        tool(
            "daily",
            "Token usage grouped by local calendar day.",
            json!({
                "type": "object",
                "properties": {
                    "since": { "type": "string" },
                    "until": { "type": "string" },
                    "limit": { "type": "integer", "minimum": 1 }
                }
            }),
        ),
        tool(
            "weekly",
            "Token usage grouped by ISO week (YYYY-Www).",
            json!({
                "type": "object",
                "properties": {
                    "since": { "type": "string" },
                    "until": { "type": "string" },
                    "limit": { "type": "integer", "minimum": 1 }
                }
            }),
        ),
        tool(
            "projects",
            "Historical token usage grouped by project. For registered folder IDs used by tasks and notes, use workspace_list.",
            json!({
                "type": "object",
                "properties": {
                    "since": { "type": "string" },
                    "until": { "type": "string" },
                    "limit": { "type": "integer", "minimum": 1 }
                }
            }),
        ),
        tool(
            "budget_status",
            "Today and this month list-rate spend vs soft budget caps (never billed money).",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "doctor",
            "Archive health: event count, confidence, Claude rollup reconciliation, db path.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "scan",
            "Read new local tool logs into the archive. Local only; does not call tokenstat.ai.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "task_list",
            "List kanban cards on this machine.",
            json!({
                "type": "object",
                "properties": {
                    "column": { "type": "string", "enum": ["backlog", "doing", "done"] }
                }
            }),
        ),
        tool(
            "task_create",
            "Create a task or note without executing it. Use workspace_list to find the project/folder ID; omit workspaceId for an unassigned card. Body/prompt goes in notes. Backend is optional until task_delegate.",
            json!({
                "type": "object",
                "properties": {
                    "title": { "type": "string" },
                    "notes": { "type": "string" },
                    "column": { "type": "string", "enum": ["backlog", "doing", "done"] },
                    "backend": { "type": "string" },
                    "workspaceId": { "type": "string" },
                    "budgetSeconds": { "type": "integer", "minimum": 0 }
                },
                "required": ["title"]
            }),
        ),
        tool(
            "task_update",
            "Update a kanban card: title, notes, column, order, or agent.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "title": { "type": "string" },
                    "notes": { "type": "string" },
                    "column": { "type": "string" },
                    "order": { "type": "integer" },
                    "backend": { "type": "string" },
                    "workspaceId": { "type": "string" },
                    "budgetSeconds": { "type": "integer", "minimum": 0 }
                },
                "required": ["id"]
            }),
        ),
        tool(
            "task_remove",
            "Delete a kanban card.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "task_delegate",
            "Hand a card to an agent. Requires a workspace and backend on the card.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "automation_list",
            "List scheduled agent jobs on this machine.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "automation_create",
            "Schedule an agent job. Pass the same job object the host accepts.",
            json!({
                "type": "object",
                "properties": { "job": { "type": "object" } },
                "required": ["job"]
            }),
        ),
        tool(
            "automation_update",
            "Update a scheduled job.",
            json!({
                "type": "object",
                "properties": { "job": { "type": "object" } },
                "required": ["job"]
            }),
        ),
        tool(
            "automation_enable",
            "Enable or disable a scheduled job.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "enabled": { "type": "boolean" }
                },
                "required": ["id", "enabled"]
            }),
        ),
        tool(
            "automation_run",
            "Queue a scheduled job to run now.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "automation_runs",
            "List recent automation runs.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "automation_queue",
            "Read scheduler settings: default time limit and max concurrent jobs.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "automation_set_queue",
            "Set scheduler settings. 0 budget is no time limit. 0 concurrent is no cap.",
            json!({
                "type": "object",
                "properties": {
                    "defaultBudgetSeconds": { "type": "integer", "minimum": 0 },
                    "maxConcurrent": { "type": "integer", "minimum": 0 }
                }
            }),
        ),
        tool(
            "workflow_list",
            "List host-owned workflow graphs (global and per-workspace).",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "workflow_get",
            "Read one workflow graph by id.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "workflow_create",
            "Save a workflow graph. Pass the same workflow object the host accepts.",
            json!({
                "type": "object",
                "properties": { "workflow": { "type": "object" } },
                "required": ["workflow"]
            }),
        ),
        tool(
            "workflow_update",
            "Replace a saved workflow graph.",
            json!({
                "type": "object",
                "properties": { "workflow": { "type": "object" } },
                "required": ["workflow"]
            }),
        ),
        tool(
            "workflow_remove",
            "Delete a saved workflow graph.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "workflow_run",
            "Start a workflow. workspaceId is the folder to run in. A workspace graph uses its bound folder if you omit it. input is the starting prompt.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "input": { "type": "string" },
                    "workspaceId": { "type": "string" }
                },
                "required": ["id"]
            }),
        ),
        tool(
            "workflow_runs",
            "List recent workflow runs.",
            json!({ "type": "object", "properties": {} }),
        ),
        tool(
            "workflow_transcript",
            "Read one step's transcript from a workflow run, from offset.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "nodeId": { "type": "string" },
                    "offset": { "type": "integer", "minimum": 0 }
                },
                "required": ["id", "nodeId"]
            }),
        ),
        tool(
            "workflow_kill",
            "Stop a live workflow run.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "workflow_continue",
            "Continue a run that is waiting on a gate.",
            json!({
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"]
            }),
        ),
        tool(
            "workflow_design",
            "Ask a cheap local backend for a workflow JSON draft. Does not save or run it.",
            json!({
                "type": "object",
                "properties": {
                    "prompt": { "type": "string" },
                    "workspaceId": { "type": "string" },
                    "backend": { "type": "string" },
                    "model": { "type": "string" },
                    "effort": { "type": "string" }
                },
                "required": ["prompt"]
            }),
        ),
    ];
    catalog.extend(discovery_tools());
    for entry in &mut catalog {
        let name = entry["name"].as_str().unwrap_or_default().to_string();
        if matches!(name.as_str(), "task_create" | "task_update") {
            let props = &mut entry["inputSchema"]["properties"];
            props["kind"] = json!({"type":"string", "enum":["task","note"], "description":"Tasks can be delegated; notes are private reminders and cannot run."});
            props["model"] =
                json!({"type":"string", "description":"Model alias from backend_list."});
            props["effort"] =
                json!({"type":"string", "description":"Reasoning effort from backend_list."});
            props["workspaceId"] = workspace_id_schema();
            props["column"] = json!({"type":"string", "enum":["backlog","doing","done","archive"]});
            props["title"]["minLength"] = json!(1);
            if name == "task_create" || name == "task_update" {
                props["priority"] = json!({"type":"string", "enum":["low","normal","high"]});
            }
        }
        if matches!(name.as_str(), "automation_create" | "automation_update") {
            entry["description"] = json!(
                "Save a scheduled agent job without running it immediately. Discover workspace IDs with workspace_list and backend/model/effort with backend_list. For updates, read automation_list first and send the complete job object with its existing id."
            );
            entry["inputSchema"]["properties"]["job"] = json!({
                "type":"object",
                "properties": {
                    "id":{"type":"string", "description":"Empty string on create generates an ID; existing ID on update."},
                    "name":{"type":"string"}, "backend":{"type":"string"},
                    "model":{"type":"string"}, "effort":{"type":"string"},
                    "workspaceId":workspace_id_schema(), "prompt":{"type":"string"},
                    "budgetSeconds":{"type":"integer", "minimum":0, "description":"0 means no time limit."},
                    "enabled":{"type":"boolean"},
                    "schedule":{"type":"object", "description":"Omit for a manual-only job.", "properties":{
                        "kind":{"type":"string", "enum":["once","interval","daily","weekdays","weekly","custom"]},
                        "everySeconds":{"type":"integer", "minimum":60},
                        "hour":{"type":"integer", "minimum":0, "maximum":23},
                        "minute":{"type":"integer", "minimum":0, "maximum":59},
                        "weekday":{"type":"integer", "minimum":0, "maximum":6, "description":"Monday=0."},
                        "weekdays":{"type":"integer", "minimum":0, "maximum":127, "description":"Day bitmask; Monday is bit 0."}
                    }},
                    "lastRunAtMs":{}, "nextRunAtMs":{}, "lastRunId":{}
                },
                "required":["id","name","backend","workspaceId","prompt","budgetSeconds","enabled"]
            });
        }
        if name == "task_list" {
            entry["description"] = json!(
                "List tasks and notes across all workspaces. Filter by workspaceId (empty string means unassigned), kind, column or query. Set includeArchived to recover archived cards."
            );
            entry["inputSchema"] = card_list_schema();
        }
    }
    for (name, source, description) in [
        (
            "note_create",
            "task_create",
            "Save a memo/reminder (never executable). Omit workspaceId for a global/unassigned memo; use workspace_list IDs for a specific project/folder. Body goes in notes.",
        ),
        (
            "note_update",
            "task_update",
            "Update a note by ID, including its notes body or workspaceId. Omitted fields are preserved.",
        ),
    ] {
        if let Some(source) = catalog.iter().find(|t| t["name"] == source) {
            let mut schema = source["inputSchema"].clone();
            if let Some(props) = schema["properties"].as_object_mut() {
                props.remove("kind");
            }
            catalog.push(tool(name, description, schema));
        }
    }
    catalog
}

const GUIDE: &str = "tokenstat manages local usage, registered project folders (workspaces), tasks, notes, scheduled agent jobs and workflow graphs. Start with workspace_list to discover exact IDs, names and paths; projects is historical usage, NOT the workspace registry. workspace_add registers an existing absolute folder path and returns its ID. Never invent an ID or put a path in workspaceId. workspace_context returns a memo of workspaces and their tasks/notes; omit id for all or pass an exact workspace ID. task_list/note_list omit workspaceId for all workspaces, use an empty string for unassigned/global cards. task_create/note_create omit workspaceId for unassigned cards; pass an ID to bind to a folder. Notes are cards with kind=note, body in notes, and cannot be delegated. Creation does not execute work. To execute a task, choose backend/model/effort from backend_list, bind a workspace, then task_delegate explicitly. Execution may edit files and use network services through the backend. task_stop stops a delegated task. automation_runs and automation_transcript inspect execution. Archive tools work without the app; management tools need tokenstat or tokenstat-hostd running on this Unix machine. Connect by launching tokenstat mcp or tokenstat-mcp over stdio; stdout is reserved for MCP. Read tokenstat://guide for this reference. Installer defaults: macOS and Linux use ~/.local/bin/tokenstat; Windows uses %LOCALAPPDATA%/tokenstat/tokenstat.exe (archive tools only; host management needs Unix). Resolve and verify the actual absolute path for this user; do not assume a shell expands home/environment variables in MCP JSON. The macOS app bundles the host helper, not the CLI MCP executable. Reuse an existing configured connection before locating another executable. When the user asks to remember tokenstat, save the preference, verified machine-specific command, args, transport, platform limits and this guide URI in the client-supported global memory or user-level instructions. Preserve existing instructions; never guess memory paths or copy credentials, note bodies or transcripts into global memory. Recheck paths and workspace IDs on another machine. If persistence is unavailable, explain that and return a memory note rather than claiming it was saved.";

fn workspace_id_schema() -> Value {
    json!({"type":"string", "description":"Exact ID returned by workspace_list/workspace_add, not a name or path. Empty string means unassigned/global."})
}

fn card_list_schema() -> Value {
    json!({"type":"object", "properties": {
        "workspaceId": workspace_id_schema(),
        "kind": {"type":"string", "enum":["task","note"]},
        "column": {"type":"string", "enum":["backlog","doing","done","archive"]},
        "includeArchived": {"type":"boolean", "default":false},
        "query": {"type":"string", "description":"Case-insensitive substring in title or notes."}
    }})
}

fn discovery_tools() -> Vec<Value> {
    let empty = json!({"type":"object", "properties":{}});
    let id = json!({"type":"object", "properties":{"id":{"type":"string", "minLength":1}}, "required":["id"]});
    vec![
        tool(
            "workspace_list",
            "Discover registered project/folder IDs, names, paths and Git status. Call before creating scoped tasks, notes or jobs. This is not the historical projects usage report.",
            empty.clone(),
        ),
        tool(
            "workspace_get",
            "Read current status, name and path for one registered workspace by ID.",
            id.clone(),
        ),
        tool(
            "workspace_add",
            "Register an existing local folder/project and return its workspace ID. Does not create a directory.",
            json!({"type":"object", "properties":{"path":{"type":"string", "description":"Absolute path to an existing folder."}}, "required":["path"]}),
        ),
        tool(
            "workspace_rename",
            "Rename the display label of a registered workspace.",
            json!({"type":"object", "properties":{"id":{"type":"string"},"name":{"type":"string"}}, "required":["id","name"]}),
        ),
        tool(
            "workspace_remove",
            "Forget a registered workspace. Does not delete the folder or its files.",
            id.clone(),
        ),
        tool(
            "workspace_context",
            "Read a current workspace memo: folder IDs/names/paths plus tasks and notes. Omit id for all workspaces including unassigned cards, or pass id for one folder. Use this to learn what work exists and where to add new work.",
            json!({"type":"object", "properties":{"id":{"type":"string", "minLength":1},"includeArchived":{"type":"boolean", "default":false}}}),
        ),
        tool(
            "note_list",
            "List saved memos/notes, across all workspaces or filtered by workspaceId, column and query. Notes cannot execute.",
            card_list_schema(),
        ),
        tool(
            "task_get",
            "Read one task or note by ID, including archived cards and delegation state.",
            id.clone(),
        ),
        tool(
            "note_get",
            "Read one saved note by ID, including archived notes.",
            id.clone(),
        ),
        tool(
            "note_remove",
            "Permanently delete a saved note by ID.",
            id.clone(),
        ),
        tool(
            "task_stop",
            "Stop a task's delegated agent run by card ID.",
            id.clone(),
        ),
        tool(
            "backend_list",
            "Discover installed agent backends and their available models and reasoning effort options before delegation or scheduling.",
            empty,
        ),
        tool(
            "automation_remove",
            "Delete a scheduled agent job by job ID.",
            id.clone(),
        ),
        tool(
            "automation_kill",
            "Stop a live automation run by run ID, not job ID.",
            id,
        ),
        tool(
            "automation_transcript",
            "Read an automation run transcript from a byte offset; use the run ID from automation_runs or a card's delegate.runId.",
            json!({"type":"object", "properties":{"id":{"type":"string"},"offset":{"type":"integer","minimum":0}},"required":["id"]}),
        ),
    ]
}

fn filter_cards(body: &mut Value, args: &Value) {
    if let Some(cards) = body.as_array_mut() {
        cards.retain(|card| {
            ["workspaceId", "column", "kind"]
                .iter()
                .all(|key| args.get(key).is_none_or(|v| card.get(key) == Some(v)))
                && args
                    .get("query")
                    .and_then(Value::as_str)
                    .is_none_or(|query| {
                        let query = query.to_lowercase();
                        ["title", "notes"].iter().any(|key| {
                            card.get(key)
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_lowercase()
                                .contains(&query)
                        })
                    })
        });
    }
}

fn tool(name: &str, description: &str, input_schema: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema
    })
}

fn call_tool(engine: &mut Engine, params: Option<&Value>) -> Result<Value, String> {
    let params = params.ok_or_else(|| "missing params".to_string())?;
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| "missing tool name".to_string())?;
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let definition = tools()
        .into_iter()
        .find(|tool| tool["name"] == name)
        .ok_or_else(|| format!("unknown tool: {name}"))?;
    validate_arguments(&args, &definition["inputSchema"])?;
    if matches!(
        name,
        "task_create" | "task_update" | "note_create" | "note_update"
    ) {
        if let Some(id) = args
            .get("workspaceId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        {
            host_call(engine, "workspace.status", json!({"id":id}))
                .map_err(|error| format!("Invalid or unavailable workspaceId: {error}. Use workspace_list or workspace_add first."))?;
        }
    }
    let q = query_from_args(&args);

    let body = match name {
        "totals" => {
            let t = engine.totals(&q).map_err(|e| e.to_string())?;
            let c = &t.counters;
            json!({
                "events": t.events,
                "sessions": t.sessions,
                "days": t.days,
                "input_fresh": c.input_fresh,
                "cache_read": c.cache_read,
                "cache_write_5m": c.cache_write_5m,
                "cache_write_1h": c.cache_write_1h,
                "output": c.output,
                "total": c.total(),
                "first_date": t.first_date,
                "last_date": t.last_date,
                "db": engine.db_path().display().to_string()
            })
        }
        "models" => bucket_tool(engine, GroupBy::Model, &q, &args)?,
        "daily" => bucket_tool(engine, GroupBy::Day, &q, &args)?,
        "weekly" => bucket_tool(engine, GroupBy::Week, &q, &args)?,
        "projects" => bucket_tool(engine, GroupBy::Project, &q, &args)?,
        "budget_status" => {
            let prices = tokenstat_core::PriceTable::load_with_catalog();
            let st = tokenstat_core::budget_status(engine.store(), engine.timezone(), &prices)
                .map_err(|e| e.to_string())?;
            json!({
                "today": st.today_date,
                "month": st.month_key,
                "today_usd": st.today_usd,
                "month_usd": st.month_usd,
                "daily_limit": st.limits.daily_usd,
                "monthly_limit": st.limits.monthly_usd,
                "over_daily": st.over_daily(),
                "over_monthly": st.over_monthly()
            })
        }
        "doctor" => {
            let t = engine
                .totals(&Query::default())
                .map_err(|e| e.to_string())?;
            let confidence = engine
                .store()
                .confidence_breakdown()
                .map_err(|e| e.to_string())?;
            let rec = tokenstat_core::reconcile(engine.store()).map_err(|e| e.to_string())?;
            let reconciliation = rec.map(|r| {
                json!({
                    "vendor_in_out": r.vendor_in_out,
                    "archive_in_out": r.archive_in_out,
                    "vendor_sessions": r.vendor_sessions,
                    "archive_sessions": r.archive_sessions,
                    "missing": r.missing(),
                    "ahead": r.ahead(),
                    "significant_gap": r.is_significant()
                })
            });
            json!({
                "db": engine.db_path().display().to_string(),
                "events": t.events,
                "sessions": t.sessions,
                "confidence": confidence.into_iter().map(|(k,v)| json!({"level": k, "events": v})).collect::<Vec<_>>(),
                "last_scan_ms": engine.store().meta("last_scan_ms").ok().flatten(),
                "reconciliation": reconciliation
            })
        }
        "scan" => {
            let report = engine.scan().map_err(|e| e.to_string())?;
            json!({
                "files_found": report.files_found,
                "files_read": report.files_read,
                "events_new": report.events_new,
                "elapsed_ms": report.elapsed_ms
            })
        }
        "workspace_list" => host_call(engine, "workspace.list", args)?,
        "workspace_get" => host_call(engine, "workspace.status", args)?,
        "workspace_add" => host_call(engine, "workspace.add", args)?,
        "workspace_rename" => host_call(engine, "workspace.rename", args)?,
        "workspace_remove" => host_call(engine, "workspace.remove", args)?,
        "workspace_context" => {
            let workspaces = if args.get("id").is_some() {
                json!([host_call(engine, "workspace.status", args.clone())?])
            } else {
                host_call(engine, "workspace.list", json!({}))?
            };
            let mut cards = host_call(engine, "todo.list", args.clone())?;
            let mut filters = json!({});
            if let Some(id) = args.get("id") {
                filters["workspaceId"] = id.clone();
            }
            filter_cards(&mut cards, &filters);
            json!({"workspaces":workspaces, "cards":cards, "guidance":GUIDE})
        }
        "task_list" | "note_list" => {
            let mut filters = args.clone();
            if name == "note_list" {
                filters["kind"] = json!("note");
            }
            let mut body = host_call(engine, "todo.list", args)?;
            filter_cards(&mut body, &filters);
            body
        }
        "task_get" | "note_get" | "note_update" | "note_remove" => {
            let cards = host_call(engine, "todo.list", json!({"includeArchived":true}))?;
            let card = cards
                .as_array()
                .and_then(|cards| cards.iter().find(|c| c.get("id") == args.get("id")))
                .ok_or_else(|| {
                    "card not found; use task_list/note_list with includeArchived=true".to_string()
                })?;
            if name.starts_with("note_") && card["kind"] != "note" {
                return Err("card is a task, not a note".into());
            }
            match name {
                "note_update" => host_call(engine, "todo.update", args)?,
                "note_remove" => host_call(engine, "todo.remove", args)?,
                _ => card.clone(),
            }
        }
        "note_create" => {
            let mut args = args;
            args["kind"] = json!("note");
            host_call(engine, "todo.create", args)?
        }
        "task_stop" => host_call(engine, "todo.stop", args)?,
        "backend_list" => host_call(engine, "automation.backends", args)?,
        "automation_remove" => host_call(engine, "automation.remove", args)?,
        "automation_kill" => host_call(engine, "automation.kill", args)?,
        "automation_transcript" => host_call(engine, "automation.transcript", args)?,
        "task_create" => host_call(engine, "todo.create", args)?,
        "task_update" => host_call(engine, "todo.update", args)?,
        "task_remove" => host_call(engine, "todo.remove", args)?,
        "task_delegate" => host_call(engine, "todo.delegate", args)?,
        "automation_list" => host_call(engine, "automation.list", json!({}))?,
        "automation_create" => host_call(engine, "automation.create", args)?,
        "automation_update" => host_call(engine, "automation.update", args)?,
        "automation_enable" => {
            let enabled = args.get("enabled").and_then(Value::as_bool).unwrap_or(true);
            let method = if enabled {
                "automation.enable"
            } else {
                "automation.disable"
            };
            host_call(engine, method, args)?
        }
        "automation_run" => host_call(engine, "automation.run", args)?,
        "automation_runs" => host_call(engine, "automation.runs", json!({}))?,
        "automation_queue" => host_call(engine, "automation.queue", json!({}))?,
        "automation_set_queue" => host_call(engine, "automation.setQueue", args)?,
        "workflow_list" => host_call(engine, "workflow.list", json!({}))?,
        "workflow_get" => host_call(engine, "workflow.get", args)?,
        "workflow_create" => host_call(engine, "workflow.create", args)?,
        "workflow_update" => host_call(engine, "workflow.update", args)?,
        "workflow_remove" => host_call(engine, "workflow.remove", args)?,
        "workflow_run" => host_call(engine, "workflow.run", args)?,
        "workflow_runs" => host_call(engine, "workflow.runs", json!({}))?,
        "workflow_transcript" => host_call(engine, "workflow.transcript", args)?,
        "workflow_kill" => host_call(engine, "workflow.kill", args)?,
        "workflow_continue" => host_call(engine, "workflow.continue", args)?,
        "workflow_design" => host_call(engine, "workflow.design", args)?,
        other => return Err(format!("unknown tool: {other}")),
    };

    Ok(json!({
        "content": [{ "type": "text", "text": serde_json::to_string_pretty(&body).unwrap_or_default() }],
        "structuredContent": if body.is_object() { body } else { json!({"items":body}) }
    }))
}

#[cfg(unix)]
fn host_socket(engine: &Engine) -> PathBuf {
    engine
        .db_path()
        .parent()
        .map(|p| p.join("host.sock"))
        .unwrap_or_else(|| PathBuf::from("host.sock"))
}

/// Talk to hostd over its local unix socket. Archive tools never come here.
fn host_call(engine: &Engine, method: &str, params: Value) -> Result<Value, String> {
    #[cfg(not(unix))]
    {
        let _ = (engine, method, params);
        return Err("the host helper is not available on this platform".into());
    }
    #[cfg(unix)]
    {
        use std::io::BufReader;
        use std::os::unix::net::UnixStream;

        let path = host_socket(engine);
        let mut stream = UnixStream::connect(&path).map_err(|e| {
            format!("host helper is not running ({e}). Start tokenstat or tokenstat-hostd.")
        })?;
        let req = json!({"id": 1, "method": method, "params": params});
        let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        stream
            .write_all(line.as_bytes())
            .and_then(|_| stream.write_all(b"\n"))
            .map_err(|e| e.to_string())?;
        let mut reader = BufReader::new(stream);
        let mut reply = String::new();
        reader.read_line(&mut reply).map_err(|e| e.to_string())?;
        let value: Value = serde_json::from_str(&reply).map_err(|e| e.to_string())?;
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(value.get("result").cloned().unwrap_or(Value::Null))
        } else {
            Err(value
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("the host helper refused the request")
                .to_string())
        }
    }
}

fn bucket_tool(engine: &Engine, group: GroupBy, q: &Query, args: &Value) -> Result<Value, String> {
    let mut rows = engine.report(group, q).map_err(|e| e.to_string())?;
    if let Some(limit) = args.get("limit").and_then(Value::as_u64) {
        rows.truncate(limit as usize);
    }
    Ok(json!(
        rows.into_iter()
            .map(|r| {
                json!({
                    "key": r.key,
                    "input_fresh": r.counters.input_fresh,
                    "cache_read": r.counters.cache_read,
                    "cache_write_5m": r.counters.cache_write_5m,
                    "cache_write_1h": r.counters.cache_write_1h,
                    "output": r.counters.output,
                    "total": r.counters.total(),
                    "events": r.events,
                    "sessions": r.sessions
                })
            })
            .collect::<Vec<_>>()
    ))
}

fn query_from_args(args: &Value) -> Query {
    Query {
        since: args
            .get("since")
            .and_then(Value::as_str)
            .map(str::to_string),
        until: args
            .get("until")
            .and_then(Value::as_str)
            .map(str::to_string),
        model: args
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_string),
        project: args
            .get("project")
            .and_then(Value::as_str)
            .map(str::to_string),
        billing: None,
        limit: None,
    }
}

fn read_message(reader: &mut impl BufRead) -> Result<Option<Value>> {
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(None);
    }
    Ok(Some(
        serde_json::from_str(&line).context("parsing newline-delimited JSON-RPC")?,
    ))
}

fn write_message(out: &mut impl Write, msg: &Value) -> Result<()> {
    if msg.is_null() {
        return Ok(());
    }
    serde_json::to_writer(&mut *out, msg)?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}

fn validate_arguments(args: &Value, schema: &Value) -> Result<(), String> {
    let object = args.as_object().ok_or("arguments must be an object")?;
    if let Some(required) = schema["required"].as_array() {
        for field in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(field) {
                return Err(format!("missing required argument: {field}"));
            }
        }
    }
    for (key, value) in object {
        let rule = &schema["properties"][key];
        if rule.is_null() {
            return Err(format!("unknown argument: {key}; check tools/list"));
        }
        let valid = match rule["type"].as_str() {
            Some("string") => value.is_string(),
            Some("integer") => value.is_i64() || value.is_u64(),
            Some("boolean") => value.is_boolean(),
            Some("object") => value.is_object(),
            _ => true,
        };
        if !valid {
            return Err(format!("invalid type for {key}"));
        }
        if let Some(options) = rule["enum"].as_array() {
            if !options.contains(value) {
                return Err(format!("invalid {key}; expected one of {options:?}"));
            }
        }
        if let Some(min) = rule["minimum"].as_f64() {
            if value.as_f64().is_some_and(|v| v < min) {
                return Err(format!("{key} must be at least {min}"));
            }
        }
        if rule["minLength"].as_u64().is_some_and(|min| {
            value
                .as_str()
                .is_some_and(|s| s.trim().len() < min as usize)
        }) {
            return Err(format!("{key} must not be empty"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stdio_roundtrip_multiple_messages_and_notifications() {
        let mut bytes = Vec::new();
        write_message(&mut bytes, &json!({"id":1,"result":{"text":"a\nb"}})).unwrap();
        write_message(&mut bytes, &Value::Null).unwrap();
        write_message(&mut bytes, &json!({"id":2,"result":{}})).unwrap();
        assert_eq!(bytes.iter().filter(|&&b| b == b'\n').count(), 2);
        let mut reader = io::Cursor::new(bytes);
        assert_eq!(read_message(&mut reader).unwrap().unwrap()["id"], 1);
        assert_eq!(read_message(&mut reader).unwrap().unwrap()["id"], 2);
        assert!(read_message(&mut reader).unwrap().is_none());
    }

    #[test]
    fn scoped_memos_and_unassigned_cards_are_distinct() {
        let cards = json!([
            {"id":"a", "workspaceId":"one", "kind":"note", "column":"backlog", "notes":"Deploy checklist"},
            {"id":"b", "workspaceId":"two", "kind":"task", "column":"doing", "title":"Deploy"},
            {"id":"c", "workspaceId":"", "kind":"note", "column":"backlog", "title":"Personal"}
        ]);
        let mut all = cards.clone();
        filter_cards(&mut all, &json!({}));
        assert_eq!(all.as_array().unwrap().len(), 3);
        let mut scoped = cards.clone();
        filter_cards(
            &mut scoped,
            &json!({"workspaceId":"one", "kind":"note", "query":"DEPLOY"}),
        );
        assert_eq!(scoped.as_array().unwrap().len(), 1);
        assert_eq!(scoped[0]["id"], "a");
        let mut global = cards;
        filter_cards(&mut global, &json!({"workspaceId":""}));
        assert_eq!(global.as_array().unwrap().len(), 1);
        assert_eq!(global[0]["id"], "c");
    }

    #[test]
    fn catalog_and_validation_prevent_silent_mistargeting() {
        let catalog = tools();
        let mut names = std::collections::HashSet::new();
        for tool in &catalog {
            assert!(names.insert(tool["name"].as_str().unwrap()));
        }
        let schema = &catalog.iter().find(|t| t["name"] == "task_create").unwrap()["inputSchema"];
        assert!(
            validate_arguments(
                &json!({"title":"Work", "workspaceId":"one", "kind":"note"}),
                schema
            )
            .is_ok()
        );
        for invalid in [
            json!({}),
            json!({"title":" "}),
            json!({"title":"Work", "workspace_id":"one"}),
            json!({"title":"Work", "workspaceId":null}),
            json!({"title":"Work", "column":"invalid"}),
            json!({"title":"Work", "budgetSeconds":-1}),
        ] {
            assert!(validate_arguments(&invalid, schema).is_err(), "{invalid}");
        }
    }

    #[test]
    fn initialization_resources_and_tool_errors() {
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::open(Some(&dir.path().join("test.db")), Some("UTC")).unwrap();
        let response = handle(
            &mut engine,
            json!({"jsonrpc":"2.0", "id":1, "method":"initialize"}),
        );
        assert!(
            response["result"]["instructions"]
                .as_str()
                .unwrap()
                .contains("workspace_list")
        );
        assert!(
            handle(
                &mut engine,
                json!({"jsonrpc":"2.0", "method":"notifications/initialized"})
            )
            .is_null()
        );
        let resource = handle(
            &mut engine,
            json!({"id":2,"method":"resources/read", "params":{"uri":"tokenstat://guide"}}),
        );
        assert_eq!(resource["result"]["contents"][0]["text"], GUIDE);
        let error = handle(
            &mut engine,
            json!({"id":3,"method":"tools/call", "params":{"name":"task_create", "arguments":{"title":"Work", "workspace_id":"wrong"}}}),
        );
        assert_eq!(error["result"]["isError"], true);
    }

    #[cfg(unix)]
    #[test]
    fn host_bridge_scopes_context_and_creates_note_with_verified_workspace() {
        use std::os::unix::net::UnixListener;
        let dir = tempfile::tempdir().unwrap();
        let mut engine = Engine::open(Some(&dir.path().join("test.db")), Some("UTC")).unwrap();
        let listener = UnixListener::bind(host_socket(&engine)).unwrap();
        let worker = std::thread::spawn(move || {
            for (method, result) in [
                ("workspace.status", json!({"id":"one","path":"/project"})),
                (
                    "todo.list",
                    json!([{"id":"a","workspaceId":"one","kind":"note"},{"id":"b","workspaceId":"two","kind":"task"}]),
                ),
                ("workspace.status", json!({"id":"one","path":"/project"})),
                (
                    "todo.create",
                    json!({"id":"new","workspaceId":"one","kind":"note"}),
                ),
            ] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut line = String::new();
                io::BufReader::new(&stream).read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                if method == "todo.create" {
                    assert_eq!(request["params"]["kind"], "note");
                    assert_eq!(request["params"]["workspaceId"], "one");
                }
                writeln!(stream, "{}", json!({"ok":true,"result":result})).unwrap();
            }
        });
        let context = call_tool(
            &mut engine,
            Some(&json!({"name":"workspace_context", "arguments":{"id":"one"}})),
        )
        .unwrap();
        assert_eq!(
            context["structuredContent"]["cards"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(context["structuredContent"]["cards"][0]["id"], "a");
        let note = call_tool(
            &mut engine,
            Some(&json!({"name":"note_create", "arguments":{"title":"Memo", "workspaceId":"one"}})),
        )
        .unwrap();
        assert_eq!(note["structuredContent"]["kind"], "note");
        worker.join().unwrap();
    }
}
