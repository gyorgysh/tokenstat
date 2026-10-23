// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A guardian-owned MCP service for the accepted Ask snapshot and an optional
//! pinned lane. It never opens the personal Engine, host socket or management
//! dispatcher. File effects stop and drain before landing or fence release.

use crate::lease_clock::{Deadline, Stamp};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Read, Write},
    net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokenstat_sync::teams::HostRunAuthority;
use zeroize::Zeroize;
mod files;

const REQUEST: usize = 512 * 1024;
// MCP text plus structuredContent can encode the same frozen JSON twice;
// escaping the text copy needs additional headroom. The source stays bounded.
const CONTEXT: usize = 4 * 1024 * 1024;
// Legacy inline fixtures keep their original bound. Production snapshots
// page their frozen authenticated archive without expanding it at startup.
#[cfg(test)]
const SNAPSHOT: usize = 32 * 1024 * 1024;
const PAGE: usize = 256 * 1024;
const RESPONSE: usize = 16 * 1024 * 1024;
const IO_BUDGET: Duration = Duration::from_secs(2);
const ADDRESS: &str = "TOKENSTAT_TEAM_SDK_ADDRESS";
const TOKEN: &str = "TOKENSTAT_TEAM_SDK_TOKEN";
const GENERATION: &str = "TOKENSTAT_TEAM_SDK_GENERATION";
const GUIDE: &str = "This connection belongs to one Team run. team_context returns the frozen shared conversation and original Ask approved for this run. When the result includes nextCursor, call team_context again with that cursor to read the next page. The original Ask is on every page. Later discussion does not change the snapshot. team_run_status describes this run only. Use chart_schema and chart_examples to choose a portable chart, then chart_create to validate it and return the tokenstat-chart block verbatim in your reply. Use observed data and label quantities and units. Personal archives, other chats, workspace management and launching agents are unavailable here.";

fn unavailable() -> io::Error {
    io::Error::other("The Team run SDK is unavailable.")
}
fn wall_ms() -> Option<u128> {
    Some(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_millis(),
    )
}
struct Budget {
    deadline: Deadline,
    wall_end: u128,
}
impl Budget {
    fn capture(authority: &HostRunAuthority) -> io::Result<Self> {
        // Sample before remaining(), so scheduling cannot enlarge the copy.
        let start = Stamp::now().ok_or_else(unavailable)?;
        let remaining = authority.remaining().map_err(|_| unavailable())?;
        Ok(Self {
            deadline: Deadline::at(start, remaining).ok_or_else(unavailable)?,
            wall_end: u128::from(authority.lease().claims().exp) * 1000,
        })
    }
    fn live(&self) -> bool {
        self.deadline.remaining().is_some() && wall_ms().is_some_and(|now| now < self.wall_end)
    }
}
struct Gate {
    budget: Budget,
    state: &'static str,
    retired: bool,
}
struct Shared {
    token: [u8; 32],
    context: Value,
    context_bytes: usize,
    frozen: Option<crate::chat::sharing::SdkContext>,
    run: String,
    gate: Mutex<Gate>,
    current: Box<dyn Fn() -> bool + Send + Sync>,
    workers: AtomicUsize,
    lane: Option<Mutex<Option<files::LaneFiles>>>,
    files_enabled: AtomicBool,
    generation: AtomicU64,
}
impl Drop for Shared {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}
impl Shared {
    fn live(&self) -> io::Result<()> {
        // Account/publication checks may read local storage. Never hold the
        // gate across them: Stop and expiry must be able to retire it.
        let current = (self.current)();
        if !current {
            self.retire();
            return Err(unavailable());
        }
        self.budget_live()
    }
    fn budget_live(&self) -> io::Result<()> {
        let mut gate = self.gate.lock().map_err(|_| unavailable())?;
        if gate.retired || !gate.budget.live() {
            gate.retired = true;
            return Err(unavailable());
        }
        Ok(())
    }
    fn retire(&self) {
        if let Ok(mut gate) = self.gate.lock() {
            gate.retired = true;
        }
    }
    fn file_live(&self, generation: u64) -> io::Result<()> {
        if !self.files_enabled.load(Ordering::Acquire)
            || self.generation.load(Ordering::Acquire) != generation
        {
            return Err(unavailable());
        }
        self.live()?;
        if !self.files_enabled.load(Ordering::Acquire)
            || self.generation.load(Ordering::Acquire) != generation
        {
            return Err(unavailable());
        }
        Ok(())
    }
    fn authenticated(&self, token: &str) -> bool {
        if !token_shape(token) {
            return false;
        }
        let Ok(bytes) = tokenstat_identity::public_key_from_hex(token) else {
            return false;
        };
        // Fixed work for a correctly shaped token. Never compare its first
        // differing byte or include a supplied token in diagnostics.
        bytes
            .iter()
            .zip(&self.token)
            .fold(0u8, |diff, (a, b)| diff | std::hint::black_box(a ^ b))
            == 0
    }
}

pub(crate) struct Service {
    address: SocketAddr,
    shared: Arc<Shared>,
    listener: Option<std::thread::JoinHandle<()>>,
}
impl Service {
    pub(crate) fn start(
        authority: &HostRunAuthority,
        context: crate::chat::sharing::SdkContext,
        run: String,
        lane: Option<&std::path::Path>,
        current: impl Fn() -> bool + Send + Sync + 'static,
    ) -> io::Result<Self> {
        let bytes = context.byte_bound().map_err(|_| unavailable())?;
        context.count().map_err(|_| unavailable())?;
        let metadata = context.metadata.clone();
        if !metadata.is_object()
            || serde_json::to_vec(&metadata)
                .map_err(|_| unavailable())?
                .len()
                > CONTEXT
        {
            return Err(unavailable());
        }
        Self::bind_context(
            Budget::capture(authority)?,
            metadata,
            bytes,
            Some(context),
            run,
            Box::new(current),
            lane.map(files::LaneFiles::bind).transpose()?,
        )
    }
    #[cfg(test)]
    fn bind(
        budget: Budget,
        context: Value,
        run: String,
        current: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> io::Result<Self> {
        let encoded = serde_json::to_vec(&context).map_err(|_| unavailable())?;
        if encoded.len() > SNAPSHOT
            || (encoded.len() > CONTEXT
                && context.get("events").and_then(Value::as_array).is_none())
        {
            return Err(unavailable());
        }
        Self::bind_context(budget, context, encoded.len(), None, run, current, None)
    }
    fn bind_context(
        budget: Budget,
        context: Value,
        context_bytes: usize,
        frozen: Option<crate::chat::sharing::SdkContext>,
        run: String,
        current: Box<dyn Fn() -> bool + Send + Sync>,
        lane: Option<files::LaneFiles>,
    ) -> io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        let mut token = [0; 32];
        getrandom::fill(&mut token).map_err(|_| unavailable())?;
        let shared = Arc::new(Shared {
            token,
            context,
            context_bytes,
            frozen,
            run,
            current,
            workers: AtomicUsize::new(0),
            lane: lane.map(|lane| Mutex::new(Some(lane))),
            files_enabled: AtomicBool::new(true),
            generation: AtomicU64::new(0),
            gate: Mutex::new(Gate {
                budget,
                state: "launching",
                retired: false,
            }),
        });
        shared.live()?;
        let held = shared.clone();
        let task = std::thread::Builder::new()
            .name("team-sdk-listener".into())
            .spawn(move || {
                while held.budget_live().is_ok() {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            if held
                                .workers
                                .try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                                    (n < 4).then_some(n + 1)
                                })
                                .is_err()
                            {
                                continue;
                            }
                            let worker = held.clone();
                            if std::thread::Builder::new()
                                .name("team-sdk-request".into())
                                .spawn(move || {
                                    let _permit = Worker(worker.clone());
                                    let _ = serve(stream, &worker);
                                })
                                .is_err()
                            {
                                held.workers.fetch_sub(1, Ordering::AcqRel);
                            }
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(20));
                        }
                        Err(_) => break,
                    }
                }
                held.retire();
            })?;
        Ok(Self {
            address,
            shared,
            listener: Some(task),
        })
    }
    pub(crate) fn configure(&self, program: &mut crate::team_process::Program) {
        program.env.insert(
            GENERATION.into(),
            self.shared.generation.load(Ordering::Acquire).to_string(),
        );
        program.env.insert(ADDRESS.into(), self.address.to_string());
        program
            .env
            .insert(TOKEN.into(), tokenstat_identity::hex(&self.shared.token));
    }
    pub(crate) fn running(&self) -> io::Result<()> {
        self.shared.live()?;
        let mut gate = self.shared.gate.lock().map_err(|_| unavailable())?;
        if gate.retired {
            return Err(unavailable());
        }
        gate.state = "running";
        Ok(())
    }
    pub(crate) fn renew(&self, authority: &HostRunAuthority) -> io::Result<()> {
        self.shared.live()?;
        let next = Budget::capture(authority)?;
        let mut gate = self.shared.gate.lock().map_err(|_| unavailable())?;
        if gate.retired || !gate.budget.live() {
            gate.retired = true;
            return Err(unavailable());
        }
        gate.budget = next;
        Ok(())
    }
    pub(crate) fn retire(&self) {
        self.shared.retire();
        self.pause_files();
        if let Some(lane) = &self.shared.lane {
            // Also release directory handles before Windows worktree cleanup.
            drop(
                lane.lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .take(),
            );
        }
    }
    pub(crate) fn pause_files(&self) {
        if self.shared.files_enabled.swap(false, Ordering::AcqRel) {
            self.shared.generation.fetch_add(1, Ordering::AcqRel);
        }
        if let Some(lane) = &self.shared.lane {
            // A guardian worker is outside the owned backend process group.
            // Drain it before committing/landing or releasing its writer fence.
            drop(lane.lock().unwrap_or_else(|error| error.into_inner()));
        }
    }
    pub(crate) fn resume_files(&self) -> io::Result<()> {
        self.shared.live()?;
        self.shared.files_enabled.store(true, Ordering::Release);
        Ok(())
    }
    pub(crate) fn ensure_live(&self) -> io::Result<()> {
        self.shared.live()
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        self.retire();
        if let Some(task) = self.listener.take() {
            let _ = task.join();
        }
    }
}
struct Worker(Arc<Shared>);
impl Drop for Worker {
    fn drop(&mut self) {
        self.0.workers.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u8,
    token: String,
    generation: u64,
    request: Value,
}
fn read_frame(
    stream: &mut TcpStream,
    limit: usize,
    live: impl Fn() -> io::Result<()>,
) -> io::Result<Vec<u8>> {
    let end = Instant::now() + IO_BUDGET;
    let mut bytes = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        live()?;
        let remaining = end
            .checked_duration_since(Instant::now())
            .ok_or_else(unavailable)?;
        stream.set_read_timeout(Some(remaining.min(Duration::from_millis(100))))?;
        let n = match stream.read(&mut chunk) {
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            other => other?,
        };
        if n == 0 || bytes.len() + n > limit {
            return Err(unavailable());
        }
        // Scan only newly received bytes; rescanning the accumulated context
        // would make large frozen replies quadratic in their length.
        if chunk[..n].contains(&b'\n') {
            if chunk[n - 1] != b'\n' || chunk[..n - 1].contains(&b'\n') {
                return Err(unavailable());
            }
            bytes.extend_from_slice(&chunk[..n - 1]);
            return Ok(bytes);
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
}
fn write_frame(
    stream: &mut TcpStream,
    value: &impl Serialize,
    limit: usize,
    live: impl Fn() -> io::Result<()>,
) -> io::Result<()> {
    let bytes = encode_frame(value, limit)?;
    write_bytes(stream, &bytes, live)
}
fn encode_frame(value: &impl Serialize, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(value).map_err(|_| unavailable())?;
    if bytes.len() >= limit {
        return Err(unavailable());
    }
    bytes.push(b'\n');
    Ok(bytes)
}
fn write_bytes(
    stream: &mut TcpStream,
    bytes: &[u8],
    live: impl Fn() -> io::Result<()>,
) -> io::Result<()> {
    let end = Instant::now() + IO_BUDGET;
    let mut offset = 0;
    while offset < bytes.len() {
        live()?;
        let remaining = end
            .checked_duration_since(Instant::now())
            .ok_or_else(unavailable)?;
        stream.set_write_timeout(Some(remaining.min(Duration::from_millis(100))))?;
        match stream.write(&bytes[offset..bytes.len().min(offset + 8192)]) {
            Ok(0) => return Err(unavailable()),
            Ok(n) => offset += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}
fn serve(mut stream: TcpStream, shared: &Shared) -> io::Result<()> {
    let bytes = read_frame(&mut stream, REQUEST, || shared.budget_live())?;
    let envelope: Envelope = serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
    if envelope.version != 1
        || !shared.authenticated(&envelope.token)
        || envelope.generation != shared.generation.load(Ordering::Acquire)
    {
        return Err(unavailable());
    }
    shared.live()?;
    let response = handle(shared, envelope.request, envelope.generation);
    let bytes = encode_frame(&response, RESPONSE)?;
    // Check the exact local publication again after serialization and before
    // the first response byte. Subsequent chunks use cheap clock/Stop checks.
    shared.live()?;
    if envelope.generation != shared.generation.load(Ordering::Acquire) {
        return Err(unavailable());
    }
    write_bytes(&mut stream, &bytes, || shared.budget_live())
}
fn keys(value: &Value, allowed: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|object| object.keys().all(|key| allowed.contains(&key.as_str())))
}
fn token_shape(token: &str) -> bool {
    token.len() == 64
        && token
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn empty(value: &Value) -> bool {
    value.as_object().is_some_and(|object| object.is_empty())
}
fn tool(name: &str, description: &str, chart: bool) -> Value {
    json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":if chart {json!({"chart":{"type":"object"}})} else {json!({})},"required":if chart {vec!["chart"]}else{vec![]},"additionalProperties":false}})
}
fn tools() -> Vec<Value> {
    vec![
        json!({"name":"team_context","description":"Read one page of the accepted shared context and the original Ask. Pass the previous nextCursor to continue. Omit it for the first page.","inputSchema":{"type":"object","properties":{"cursor":{"type":"string","pattern":"^(0|[1-9][0-9]{0,19})$"}},"additionalProperties":false}}),
        tool("team_run_status", "Read this run's status.", false),
        tool("chart_schema", "Read the portable chart schema.", false),
        tool(
            "chart_examples",
            "Read validated examples of supported charts.",
            false,
        ),
        tool(
            "chart_create",
            "Validate a chart and return its interactive chat block.",
            true,
        ),
        tool("chart_validate", "Validate a portable chart.", true),
    ]
}

/// Provider-native permission policies mirror the actual SDK roster rather
/// than maintaining a second list that can silently lose chart/file tools.
pub(crate) fn registered_tool_names() -> Vec<String> {
    registered_tool_schemas()
        .into_iter()
        .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
        .collect()
}

pub(crate) fn registered_tool_schemas() -> Vec<Value> {
    tools().into_iter().chain(files::tools()).collect()
}
fn context_cursor(args: &Value) -> Result<usize, &'static str> {
    if empty(args) {
        return Ok(0);
    }
    if !keys(args, &["cursor"]) {
        return Err("This tool accepts no target or arguments.");
    }
    let text = args["cursor"]
        .as_str()
        .filter(|text| {
            !text.is_empty()
                && text.len() <= 10
                && text.bytes().all(|b| b.is_ascii_digit())
                && !(text.starts_with('0') && *text != "0")
        })
        .ok_or("Provide a context cursor.")?;
    text.parse().map_err(|_| "Provide a context cursor.")
}
fn context_page(source: &Value, events: &[Value], total: usize, next: Option<String>) -> Value {
    let mut object = serde_json::Map::new();
    if let Some(fields) = source.as_object() {
        for (key, value) in fields {
            if key != "events" && key != "nextCursor" && key != "eventCount" {
                object.insert(key.clone(), value.clone());
            }
        }
    }
    object.insert("events".into(), json!(events));
    object.insert("eventCount".into(), json!(total));
    object.insert(
        "nextCursor".into(),
        next.map(Value::String).unwrap_or(Value::Null),
    );
    Value::Object(object)
}
fn page_context(shared: &Shared, args: &Value) -> Result<Value, &'static str> {
    if let Some(context) = &shared.frozen {
        return page_frozen_context(context, args);
    }
    let cursor = context_cursor(args)?;
    // The accepted context never changes. Measuring the full snapshot for
    // every page needlessly copies megabytes while a caller waits.
    if cursor == 0
        && shared.context_bytes <= CONTEXT
        && !args
            .as_object()
            .is_some_and(|object| object.contains_key("cursor"))
    {
        return Ok(shared.context.clone());
    }
    let events = shared
        .context
        .get("events")
        .and_then(Value::as_array)
        .ok_or("This context cannot be paged.")?;
    if cursor > events.len() {
        return Err("That context page is unavailable.");
    }
    // Measure each event once. Rendering the growing page on every event would
    // copy the whole page again, which gets expensive near the 32 MiB cap.
    let mut bytes = serde_json::to_vec(&context_page(&shared.context, &[], events.len(), None))
        .map_err(|_| "The run is unavailable.")?
        .len();
    let mut chosen = Vec::new();
    let mut next = cursor;
    while next < events.len() {
        let event = serde_json::to_vec(&events[next]).map_err(|_| "The run is unavailable.")?;
        let separator = usize::from(!chosen.is_empty());
        // Leave room for the nextCursor string, which is absent from the base.
        if bytes + separator + event.len() + 32 > PAGE {
            if chosen.is_empty() {
                return Err("This context page is too large.");
            }
            break;
        }
        bytes += separator + event.len();
        chosen.push(events[next].clone());
        next += 1;
    }
    let next_cursor = (next < events.len()).then(|| next.to_string());
    Ok(context_page(
        &shared.context,
        &chosen,
        events.len(),
        next_cursor,
    ))
}
fn page_frozen_context(
    context: &crate::chat::sharing::SdkContext,
    args: &Value,
) -> Result<Value, &'static str> {
    let after = if empty(args) {
        None
    } else {
        if !keys(args, &["cursor"]) {
            return Err("This tool accepts no target or arguments.");
        }
        let text = args["cursor"]
            .as_str()
            .filter(|text| {
                !text.is_empty()
                    && text.len() <= 20
                    && text.bytes().all(|b| b.is_ascii_digit())
                    && !(text.starts_with('0') && *text != "0")
            })
            .ok_or("Provide a context cursor.")?;
        Some(
            text.parse::<u64>()
                .map_err(|_| "Provide a context cursor.")?,
        )
    };
    if after.is_none()
        && let Some(value) = context
            .full_if_small(CONTEXT)
            .map_err(|_| "The frozen context is unavailable.")?
    {
        return Ok(value);
    }
    let count = context
        .count()
        .map_err(|_| "The frozen context is unavailable.")?;
    let (events, more) = context
        .page(after, 100, PAGE)
        .map_err(|_| "The frozen context is unavailable.")?;
    let next = if more {
        Some(
            events
                .last()
                .and_then(|event| event["seq"].as_u64())
                .filter(|seq| after.is_none_or(|previous| *seq > previous))
                .ok_or("The frozen context did not advance.")?
                .to_string(),
        )
    } else {
        None
    };
    let value = context_page(&context.metadata, &events, count, next);
    if serde_json::to_vec(&value)
        .map_err(|_| "The frozen context is unavailable.")?
        .len()
        > CONTEXT
    {
        return Err("This context page is too large.");
    }
    Ok(value)
}
fn content(data: Value) -> Value {
    json!({"content":[{"type":"text","text":data.to_string()}],"structuredContent":{"data":data}})
}
fn call(shared: &Shared, params: &Value, generation: u64) -> Result<Value, &'static str> {
    if !keys(params, &["name", "arguments"]) {
        return Err("Invalid tool arguments.");
    }
    let name = params["name"].as_str().ok_or("Missing tool name.")?;
    let fallback = json!({});
    let args = params.get("arguments").unwrap_or(&fallback);
    if name.starts_with("team_file") || name == "team_directory_create" {
        shared
            .file_live(generation)
            .map_err(|_| "The run is unavailable.")?;
        let lane = shared
            .lane
            .as_ref()
            .ok_or("This run has no lane file access.")?
            .lock()
            .map_err(|_| "The lane is unavailable.")?;
        return Ok(content(
            lane.as_ref()
                .ok_or("The lane is unavailable.")?
                .call(name, args, || shared.file_live(generation))?,
        ));
    }
    if matches!(name, "chart_create" | "chart_validate") {
        if !keys(args, &["chart"]) || !args["chart"].is_object() {
            return Err("Provide one chart.");
        }
        let chart = tokenstat_core::chart::Chart::parse(&args["chart"].to_string())
            .map_err(|_| "The chart is invalid. Check chart_schema.")?;
        let fence = chart.fence().map_err(|_| "The chart is invalid.")?;
        return Ok(
            json!({"content":[{"type":"text","text":fence}],"structuredContent":{"chart":chart,"markdown":fence,"valid":true}}),
        );
    }
    if name == "team_context" {
        return Ok(content(page_context(shared, args)?));
    }
    if !empty(args) {
        return Err("This tool accepts no target or arguments.");
    }
    Ok(content(match name {
        "team_run_status" => {
            let gate = shared.gate.lock().map_err(|_| "The run is unavailable.")?;
            json!({"runId":shared.run,"state":gate.state})
        }
        "chart_schema" => tokenstat_core::chart::schema(),
        "chart_examples" => tokenstat_core::chart::examples(),
        _ => return Err("This tool is unavailable in a Team run."),
    }))
}
fn handle(shared: &Shared, request: Value, generation: u64) -> Value {
    let id = request
        .get("id")
        .filter(|id| id.as_i64().is_some() || id.as_str().is_some_and(|s| s.len() <= 128))
        .cloned()
        .unwrap_or(Value::Null);
    let error =
        |code, message| json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}});
    if !keys(&request, &["jsonrpc", "id", "method", "params"]) || request["jsonrpc"] != "2.0" {
        return error(-32600, "Invalid request.");
    }
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    if request.get("id").is_none() {
        // Notifications cannot open alternate methods or carry effects.
        return Value::Null;
    }
    if id.is_null() {
        return error(-32600, "Invalid request identifier.");
    }
    let result = match request["method"].as_str() {
        Some("initialize") if keys(&params, &["protocolVersion", "capabilities", "clientInfo"]) => {
            json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"tokenstat-team-run","version":tokenstat_core::VERSION},"instructions":GUIDE})
        }
        Some("ping") if empty(&params) => json!({}),
        Some("tools/list") if empty(&params) => {
            let mut available = tools();
            if shared.lane.is_some() {
                available.extend(files::tools());
            }
            // Antigravity otherwise defers MCP tools behind a native discovery
            // tool. Team runs deny native tools, so offer the scoped roster
            // directly. Other MCP clients ignore vendor metadata.
            for tool in &mut available {
                tool["_meta"] = json!({"antigravity/alwaysLoad":true});
            }
            json!({"tools":available})
        }
        Some("team/tool-policy") if keys(&params, &["name"]) => {
            let name = params["name"].as_str().unwrap_or("");
            let allowed = name
                .strip_prefix("mcp__tokenstat_team__")
                .is_some_and(|name| {
                    if (name.starts_with("team_file") || name == "team_directory_create")
                        && !shared.files_enabled.load(Ordering::Acquire)
                    {
                        return false;
                    }
                    tools()
                        .into_iter()
                        .chain(if shared.lane.is_some() {
                            files::tools()
                        } else {
                            Vec::new()
                        })
                        .any(|tool| tool["name"] == name)
                });
            json!({"allow":allowed})
        }
        Some("tools/call") => match call(shared, &params, generation) {
            Ok(value) => value,
            Err(message) => json!({"isError":true,"content":[{"type":"text","text":message}]}),
        },
        _ => return error(-32601, "This method is unavailable in a Team run."),
    };
    json!({"jsonrpc":"2.0","id":id,"result":result})
}

/// Stdio bridge used only by a backend's explicit per-run MCP configuration.
/// Missing or malformed scope is fatal; there is no personal-mode fallback.
pub fn main() -> Result<(), String> {
    bridge().map_err(|_| "The Team run SDK is unavailable.".into())
}

/// The Team hook asks only its guardian's scoped endpoint. It never opens the
/// personal host socket, reads a chat turn token, or falls back to personal mode.
pub fn allows_tool(name: &str) -> io::Result<bool> {
    let address = std::env::var(ADDRESS)
        .map_err(|_| unavailable())?
        .parse::<SocketAddr>()
        .map_err(|_| unavailable())?;
    if address.ip() != Ipv4Addr::LOCALHOST || address.port() == 0 {
        return Err(unavailable());
    }
    let generation = std::env::var(GENERATION)
        .map_err(|_| unavailable())?
        .parse::<u64>()
        .map_err(|_| unavailable())?;
    let token = std::env::var(TOKEN).map_err(|_| unavailable())?;
    if !token_shape(&token) {
        return Err(unavailable());
    }
    let mut stream = TcpStream::connect_timeout(&address, IO_BUDGET)?;
    write_frame(
        &mut stream,
        &Envelope {
            version: 1,
            token,
            generation,
            request: json!({"jsonrpc":"2.0","id":1,"method":"team/tool-policy","params":{"name":name}}),
        },
        REQUEST,
        || Ok(()),
    )?;
    let response: Value = serde_json::from_slice(&read_frame(&mut stream, RESPONSE, || Ok(()))?)
        .map_err(|_| unavailable())?;
    response["result"]["allow"]
        .as_bool()
        .ok_or_else(unavailable)
}
fn bridge() -> io::Result<()> {
    let address = std::env::var(ADDRESS)
        .map_err(|_| unavailable())?
        .parse::<SocketAddr>()
        .map_err(|_| unavailable())?;
    if address.ip() != Ipv4Addr::LOCALHOST || address.port() == 0 {
        return Err(unavailable());
    }
    let generation = std::env::var(GENERATION)
        .map_err(|_| unavailable())?
        .parse::<u64>()
        .map_err(|_| unavailable())?;
    let token = std::env::var(TOKEN).map_err(|_| unavailable())?;
    if !token_shape(&token) {
        return Err(unavailable());
    }
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut line = Vec::new();
        let n = Read::take(&mut input, REQUEST as u64).read_until(b'\n', &mut line)?;
        if n == 0 {
            return Ok(());
        }
        if line.len() >= REQUEST || line.pop() != Some(b'\n') {
            return Err(unavailable());
        }
        let request = serde_json::from_slice(&line).map_err(|_| unavailable())?;
        let mut stream = TcpStream::connect_timeout(&address, IO_BUDGET)?;
        write_frame(
            &mut stream,
            &Envelope {
                version: 1,
                token: token.clone(),
                generation,
                request,
            },
            REQUEST,
            || Ok(()),
        )?;
        let response: Value =
            serde_json::from_slice(&read_frame(&mut stream, RESPONSE, || Ok(()))?)
                .map_err(|_| unavailable())?;
        if !response.is_null() {
            serde_json::to_writer(&mut output, &response).map_err(|_| unavailable())?;
            output.write_all(b"\n")?;
            output.flush()?;
        }
    }
}

#[cfg(test)]
#[path = "team_sdk/tests.rs"]
mod tests;
