// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Viewer-side ownership of a dedicated encrypted screen connection.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_remote::StreamWriter;

use crate::screen_stream::{
    Frame, FrameKind, MAX_AUDIO_BYTES, MAX_INPUT_BYTES, MAX_METADATA_BYTES, MAX_VIDEO_BYTES,
    VideoQueue,
};

struct Viewer {
    state: Mutex<ViewerState>,
    changed: Condvar,
}

struct ViewerState {
    frames: VideoQueue,
    writer: Option<StreamWriter>,
    active: bool,
    error: Option<String>,
    input_sequence: u64,
    metadata: Option<Vec<u8>>,
    audio: std::collections::VecDeque<Vec<u8>>,
}

fn viewers() -> &'static Mutex<HashMap<String, Arc<Viewer>>> {
    static VIEWERS: OnceLock<Mutex<HashMap<String, Arc<Viewer>>>> = OnceLock::new();
    VIEWERS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenParams {
    peer: String,
    capability: String,
    #[serde(default)]
    control: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReadParams {
    id: String,
    #[serde(default = "default_wait")]
    wait_ms: u64,
}

fn default_wait() -> u64 {
    250
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputParams {
    id: String,
    data: String,
}

#[derive(Deserialize)]
struct IdParams {
    id: String,
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("screen.viewer.") {
        return None;
    }
    Some((|| {
        crate::request_context::refuse_remote("screen viewer methods")?;
        match method {
            "screen.viewer.open" => open(params),
            "screen.viewer.read" => read(params),
            "screen.viewer.input" => input(params),
            "screen.viewer.close" => close(params),
            _ => Err(format!("unknown screen viewer method: {method}")),
        }
    })())
}

fn open(params: &str) -> Result<Value, String> {
    let p: OpenParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    if let Ok(candidate) = crate::remote::call_peer_result(&p.peer, "screen.direct.candidate", "{}")
        && let Some(address) = candidate.get("address").and_then(Value::as_str)
    {
        let _ = crate::remote::remember_direct_address(&p.peer, address);
    }
    let answer = crate::remote::call_peer_result(
        &p.peer,
        "stream.open",
        &json!({"kind":"screen.video", "capability":p.capability, "control":p.control}).to_string(),
    )?;
    let token = answer
        .get("token")
        .and_then(Value::as_str)
        .ok_or("screen stream returned no claim token")?;
    // The host's own id for this session, which is what `screen.control.set`
    // names. Optional, because a host built before that method existed does
    // not send one and the viewer then falls back to reopening the stream.
    let host_session = answer
        .get("sessionID")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    // Named, because this is the channel the relay meters and caps: a desktop
    // at 1.5 Mbps is the one thing on this tunnel that costs real money, and a
    // channel that does not say so is counted as "unknown" and capped by
    // nothing.
    let (mut connection, transport) =
        crate::remote::dial_peer_for(&p.peer, tokenstat_remote::tunnel::ChannelPurpose::Screen)?;
    connection
        .send(json!({"stream":token}).to_string().as_bytes())
        .map_err(|e| e.to_string())?;
    let (reader, writer) = connection.split();
    let mut random = [0u8; 12];
    getrandom::fill(&mut random).map_err(|e| e.to_string())?;
    let id = format!("viewer-{}", tokenstat_identity::hex(&random));
    let viewer = Arc::new(Viewer {
        state: Mutex::new(ViewerState {
            frames: VideoQueue::default(),
            writer: Some(writer),
            active: true,
            error: None,
            input_sequence: 0,
            metadata: None,
            audio: std::collections::VecDeque::new(),
        }),
        changed: Condvar::new(),
    });
    viewers()
        .lock()
        .map_err(|_| "screen viewer registry poisoned")?
        .insert(id.clone(), Arc::clone(&viewer));
    std::thread::spawn(move || {
        loop {
            match reader.read(MAX_VIDEO_BYTES.max(MAX_METADATA_BYTES).max(MAX_AUDIO_BYTES) + 32) {
                Ok(bytes) if bytes.is_empty() => break,
                Ok(bytes) => match Frame::decode(&bytes) {
                    Ok(frame) if frame.kind == FrameKind::Video => {
                        if let Ok(mut state) = viewer.state.lock() {
                            let _ = state.frames.push(frame);
                            viewer.changed.notify_all();
                        }
                    }
                    Ok(frame) if frame.kind == FrameKind::Metadata => {
                        if let Ok(mut state) = viewer.state.lock() {
                            state.metadata = Some(frame.payload);
                            viewer.changed.notify_all();
                        }
                    }
                    Ok(frame) if frame.kind == FrameKind::Audio => {
                        if let Ok(mut state) = viewer.state.lock() {
                            if state.audio.len() == 4 {
                                state.audio.pop_front();
                            }
                            state.audio.push_back(frame.payload);
                            viewer.changed.notify_all();
                        }
                    }
                    Ok(frame) if frame.kind == FrameKind::Error => {
                        if let Ok(mut state) = viewer.state.lock() {
                            state.error = String::from_utf8(frame.payload).ok();
                            viewer.changed.notify_all();
                        }
                        break;
                    }
                    Ok(_) => {}
                    Err(error) => {
                        if let Ok(mut state) = viewer.state.lock() {
                            state.error = Some(error);
                        }
                        break;
                    }
                },
                Err(error) => {
                    if let Ok(mut state) = viewer.state.lock() {
                        state.error = Some(error.to_string());
                    }
                    break;
                }
            }
        }
        reader.close();
        if let Ok(mut state) = viewer.state.lock() {
            state.active = false;
            state.writer = None;
            viewer.changed.notify_all();
        }
    });
    Ok(json!({"id":id, "control":p.control, "transport":transport, "sessionId":host_session}))
}

fn lookup(id: &str) -> Result<Arc<Viewer>, String> {
    viewers()
        .lock()
        .map_err(|_| "screen viewer registry poisoned")?
        .get(id)
        .cloned()
        .ok_or("screen viewer session was not found".into())
}

fn read(params: &str) -> Result<Value, String> {
    let p: ReadParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let viewer = lookup(&p.id)?;
    let mut state = viewer.state.lock().map_err(|_| "screen viewer poisoned")?;
    if state.frames.queued_bytes() == 0 && state.active {
        let waited = viewer
            .changed
            .wait_timeout(state, Duration::from_millis(p.wait_ms.min(1_000)))
            .map_err(|_| "screen viewer poisoned")?;
        state = waited.0;
    }
    let dropped = state.frames.dropped();
    let metadata = state
        .metadata
        .take()
        .map(|bytes| crate::base64::encode(&bytes));
    let audio = state
        .audio
        .pop_front()
        .map(|bytes| crate::base64::encode(&bytes));
    let frame = state
        .frames
        .pop()
        .and_then(|frame| frame.encode().ok())
        .map(|bytes| crate::base64::encode(&bytes));
    Ok(
        json!({"frame":frame, "audio":audio, "metadata":metadata, "active":state.active, "dropped":dropped, "error":state.error}),
    )
}

fn input(params: &str) -> Result<Value, String> {
    let p: InputParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let payload = crate::base64::decode(&p.data)?;
    if payload.len() > MAX_INPUT_BYTES {
        return Err("screen input batch exceeds 4 KiB".into());
    }
    let viewer = lookup(&p.id)?;
    let mut state = viewer.state.lock().map_err(|_| "screen viewer poisoned")?;
    state.input_sequence += 1;
    let frame = Frame {
        kind: FrameKind::Input,
        sequence: state.input_sequence,
        timestamp_us: 0,
        width: 0,
        height: 0,
        independent: true,
        payload,
    };
    let writer = state
        .writer
        .clone()
        .ok_or("screen viewer is disconnected")?;
    drop(state);
    writer.write(&frame.encode()?).map_err(|e| e.to_string())?;
    Ok(json!({"sent":true}))
}

fn close(params: &str) -> Result<Value, String> {
    let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
    let viewer = viewers()
        .lock()
        .map_err(|_| "screen viewer registry poisoned")?
        .remove(&p.id);
    let closed = viewer.is_some();
    if let Some(viewer) = viewer
        && let Ok(mut state) = viewer.state.lock()
    {
        state.active = false;
        if let Some(writer) = state.writer.take() {
            writer.close();
        }
        viewer.changed.notify_all();
    }
    Ok(json!({"closed":closed}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_remote_peer_cannot_drive_the_local_viewer() {
        crate::request_context::with_remote_peer("phone", || {
            for method in [
                "screen.viewer.open",
                "screen.viewer.read",
                "screen.viewer.input",
                "screen.viewer.close",
            ] {
                let refused = super::call(method, r#"{"id":"viewer-x"}"#)
                    .unwrap()
                    .expect_err(method);
                assert!(refused.contains("local-only"), "{method}: {refused}");
            }
        });
    }
}
