// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local IPC seam between the macOS capture helper and encrypted streams.

use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::screen_stream::{Frame, FrameKind, MAX_INPUT_BYTES};

const FRAME_SLOTS: usize = 3;

struct CaptureSession {
    peer: String,
    control: bool,
    frames: SyncSender<Vec<u8>>,
    input: VecDeque<Vec<u8>>,
    dropped: u64,
}

fn sessions() -> &'static Mutex<HashMap<String, Arc<Mutex<CaptureSession>>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<CaptureSession>>>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) struct CaptureReceiver {
    pub id: String,
    receiver: Receiver<Vec<u8>>,
}

impl CaptureReceiver {
    pub fn receive(&self) -> Result<Vec<u8>, String> {
        self.receiver
            .recv()
            .map_err(|_| "capture helper closed".into())
    }
}

impl Drop for CaptureReceiver {
    fn drop(&mut self) {
        if let Ok(mut held) = sessions().lock() {
            held.remove(&self.id);
        }
    }
}

pub(crate) fn create(id: String, peer: String, control: bool) -> Result<CaptureReceiver, String> {
    let (tx, rx) = mpsc::sync_channel(FRAME_SLOTS);
    sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?
        .insert(
            id.clone(),
            Arc::new(Mutex::new(CaptureSession {
                peer,
                control,
                frames: tx,
                input: VecDeque::new(),
                dropped: 0,
            })),
        );
    Ok(CaptureReceiver { id, receiver: rx })
}

pub(crate) fn queue_input(id: &str, payload: Vec<u8>) -> Result<(), String> {
    if payload.len() > MAX_INPUT_BYTES {
        return Err("screen input batch exceeds 4 KiB".into());
    }
    let session = sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?
        .get(id)
        .cloned()
        .ok_or("screen capture session is no longer active")?;
    let mut held = session.lock().map_err(|_| "capture session poisoned")?;
    let session_command = serde_json::from_slice::<Value>(&payload)
        .ok()
        .and_then(|value| value.get("type").and_then(Value::as_str).map(str::to_owned))
        .is_some_and(|kind| matches!(kind.as_str(), "display" | "clipboard"));
    if !held.control && !session_command {
        return Err("this screen session is view-only".into());
    }
    if held.input.len() >= 64 {
        held.input.pop_front();
    }
    held.input.push_back(payload);
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdParams {
    id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PushParams {
    id: String,
    frame: String,
}

pub(crate) fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    if !method.starts_with("screen.capture.") {
        return None;
    }
    Some((|| {
        if crate::request_context::remote_peer().is_some() {
            return Err("screen capture helper methods are local-only".into());
        }
        match method {
            "screen.capture.list" => {
                let held = sessions()
                    .lock()
                    .map_err(|_| "screen capture registry poisoned")?;
                let mut out = Vec::with_capacity(held.len());
                for (id, session) in held.iter() {
                    let session = session.lock().map_err(|_| "capture session poisoned")?;
                    out.push(json!({"id": id, "peerID": session.peer, "control": session.control, "dropped": session.dropped}));
                }
                Ok(Value::Array(out))
            }
            "screen.capture.push" => {
                let p: PushParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let bytes = crate::base64::decode(&p.frame)?;
                let frame = Frame::decode(&bytes)?;
                if !matches!(
                    frame.kind,
                    FrameKind::Video | FrameKind::Metadata | FrameKind::Audio | FrameKind::Error
                ) {
                    return Err(
                        "capture helper may push only video, audio, error, or metadata frames"
                            .into(),
                    );
                }
                let session = sessions()
                    .lock()
                    .map_err(|_| "screen capture registry poisoned")?
                    .get(&p.id)
                    .cloned()
                    .ok_or("screen capture session is no longer active")?;
                let mut held = session.lock().map_err(|_| "capture session poisoned")?;
                match held.frames.try_send(bytes) {
                    Ok(()) => Ok(json!({"accepted": true, "dropped": held.dropped})),
                    Err(TrySendError::Full(_)) => {
                        held.dropped += 1;
                        Ok(json!({"accepted": false, "dropped": held.dropped}))
                    }
                    Err(TrySendError::Disconnected(_)) => Err("screen viewer disconnected".into()),
                }
            }
            "screen.capture.input" => {
                let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let session = sessions()
                    .lock()
                    .map_err(|_| "screen capture registry poisoned")?
                    .get(&p.id)
                    .cloned()
                    .ok_or("screen capture session is no longer active")?;
                let mut held = session.lock().map_err(|_| "capture session poisoned")?;
                let data = held.input.pop_front().map(|v| crate::base64::encode(&v));
                Ok(json!({"data": data}))
            }
            "screen.capture.close" => {
                let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let removed = sessions()
                    .lock()
                    .map_err(|_| "screen capture registry poisoned")?
                    .remove(&p.id)
                    .is_some();
                Ok(json!({"closed": removed}))
            }
            _ => Err(format!("unknown screen capture method: {method}")),
        }
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_only_session_rejects_control_input() {
        let receiver = create("view-only".into(), "phone".into(), false).unwrap();
        assert!(queue_input(&receiver.id, vec![1]).is_err());
        assert!(queue_input(&receiver.id, br#"{"type":"display","id":2}"#.to_vec()).is_ok());
    }
}
