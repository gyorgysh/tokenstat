// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! MCP server over the local tokenstat archive, and (when hostd is up) the
//! local kanban board and automations.
//!
//! Speaks JSON-RPC 2.0 with MCP Content-Length framing on stdio. Archive
//! tools stay local. Task, automation and workflow tools talk to the host
//! helper over its unix socket, never the network. Nothing is sent off the
//! machine.

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

    if id.is_null() && method.starts_with("notifications/") {
        return Value::Null;
    }

    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "tokenstat",
                "version": VERSION,
            },
            "instructions": "Local token usage archive. Sync is opt-in and sends aggregate counters only."
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools() })),
        "tools/call" => call_tool(engine, msg.get("params")),
        "resources/list" => Ok(json!({ "resources": [] })),
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
    vec![
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
            "Token usage grouped by project.",
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
            "Create a kanban card. Agent and workspace are optional until you delegate.",
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
    ]
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
        "task_list" => {
            let mut body = host_call(engine, "todo.list", json!({}))?;
            if let Some(column) = args.get("column").and_then(Value::as_str) {
                if let Some(cards) = body.as_array_mut() {
                    cards.retain(|c| c.get("column").and_then(Value::as_str) == Some(column));
                }
            }
            body
        }
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
        "structuredContent": body
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
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line)?;
        if n == 0 {
            return Ok(None);
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        let (key, value) = trimmed
            .split_once(':')
            .map(|(k, v)| (k.trim(), v.trim()))
            .unwrap_or((trimmed, ""));
        if key.eq_ignore_ascii_case("Content-Length") {
            content_length = Some(value.parse().context("Content-Length")?);
        }
    }
    let len = content_length.context("missing Content-Length header")?;
    let mut buf = vec![0u8; len];
    std::io::Read::read_exact(reader, &mut buf)?;
    let msg: Value = serde_json::from_slice(&buf).context("parsing JSON-RPC body")?;
    Ok(Some(msg))
}

fn write_message(out: &mut impl Write, msg: &Value) -> Result<()> {
    if msg.is_null() {
        return Ok(());
    }
    let body = serde_json::to_vec(msg)?;
    write!(out, "Content-Length: {}\r\n\r\n", body.len())?;
    out.write_all(&body)?;
    out.flush()?;
    Ok(())
}
