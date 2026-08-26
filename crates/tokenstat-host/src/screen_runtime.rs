// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Local IPC seam between the macOS capture helper and encrypted streams.

use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, OnceLock};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::screen_stream::{Frame, FrameKind, MAX_INPUT_BYTES};

const FRAME_SLOTS: usize = 3;

/// How many queued input events one poll may take.
///
/// High enough that a fast drag is delivered whole rather than a poll at a
/// time, bounded so an authorized controller flooding the queue cannot make
/// one response arbitrarily large. The queue itself is already capped.
const MAX_INPUT_BATCH: usize = 64;

struct CaptureSession {
    peer: String,
    control: bool,
    frames: SyncSender<Vec<u8>>,
    input: VecDeque<Vec<u8>>,
    dropped: u64,
}

/// Why a screen session ended.
///
/// Named rather than inferred, because the relay only records that a channel
/// went away and the log then says nothing about the cause. With three
/// sessions interleaving their failures the log was unreadable, and one live
/// session per peer plus a reason on every teardown is what makes it legible.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum EndReason {
    /// A newer session for the same peer took over.
    Superseded,
    /// The grant was removed or narrowed while the session was live.
    Revoked,
    /// The capture helper asked for it to end.
    HelperClosed,
    /// The encrypted stream went away: the viewer left, or the route dropped.
    StreamClosed,
}

impl EndReason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Superseded => "superseded",
            Self::Revoked => "revoked",
            Self::HelperClosed => "helper closed",
            Self::StreamClosed => "stream closed",
        }
    }
}

/// One line per teardown, on the one channel the daemon already logs to.
fn note_end(id: &str, peer: &str, reason: EndReason) {
    // The peer key is long and its head is enough to follow one device
    // through a log without printing a full public key on every line.
    let short: String = peer.chars().take(8).collect();
    eprintln!(
        "[screen] session {id} for {short}… ended: {}",
        reason.as_str()
    );
}

fn sessions() -> &'static Mutex<HashMap<String, Arc<Mutex<CaptureSession>>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Mutex<CaptureSession>>>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// End sessions whose grant was removed or reduced. Dropping the sender wakes
/// the capture pump, which then closes both halves of the encrypted stream.
pub(crate) fn revoke_peer(peer: &str, view: bool, control: bool) -> Result<(), String> {
    let mut held = sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?;
    held.retain(|id, session| {
        let Ok(session) = session.lock() else {
            return false;
        };
        let keep = session.peer != peer || (view && (!session.control || control));
        if !keep {
            note_end(id, &session.peer, EndReason::Revoked);
        }
        keep
    });
    Ok(())
}

/// End every live session belonging to one peer.
///
/// A device gets one screen at a time. Without this, `create` happily added a
/// second capture beside the first, so a viewer that reconnected left the old
/// `SCStream` running and started another: the same desktop shared twice, then
/// three times, each one still pushing frames.
fn end_sessions_for(peer: &str, reason: EndReason) -> Result<usize, String> {
    let mut held = sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?;
    let before = held.len();
    held.retain(|id, session| {
        let Ok(session) = session.lock() else {
            return false;
        };
        if session.peer == peer {
            note_end(id, &session.peer, reason);
            return false;
        }
        true
    });
    Ok(before - held.len())
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
        if let Ok(mut held) = sessions().lock()
            && let Some(session) = held.remove(&self.id)
        {
            // Only when this drop is what removed it. A superseded or revoked
            // session is already gone from the map and has already said why,
            // and logging twice would name the wrong cause the second time.
            if let Ok(session) = session.lock() {
                note_end(&self.id, &session.peer, EndReason::StreamClosed);
            }
        }
    }
}

pub(crate) fn create(id: String, peer: String, control: bool) -> Result<CaptureReceiver, String> {
    // One live session per peer. Dropping the old sender wakes its pump, which
    // closes its stream and stops its capture, so the replacement is a
    // handover rather than a second share.
    end_sessions_for(&peer, EndReason::Superseded)?;
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
        .is_some_and(|kind| kind == "display");
    if !held.control && !session_command {
        return Err("this screen session is view-only".into());
    }
    // One poll's worth of queue. Beyond that the oldest goes: a pointer
    // position nobody has read yet is worth less than the one after it.
    if held.input.len() >= MAX_INPUT_BATCH {
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
                    out.push(json!({"id": id, "peerId": session.peer, "control": session.control, "dropped": session.dropped}));
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
                // Everything that is waiting, not the oldest one.
                //
                // The helper polls this on a timer, so popping a single event
                // per call capped a controller at one pointer move per poll
                // and let the rest pile up behind it: the pointer arrived
                // late and then kept arriving, seconds after the finger had
                // stopped. A batch is what the queue is for.
                let mut batch = Vec::with_capacity(held.input.len().min(MAX_INPUT_BATCH));
                while batch.len() < MAX_INPUT_BATCH {
                    match held.input.pop_front() {
                        Some(value) => batch.push(crate::base64::encode(&value)),
                        None => break,
                    }
                }
                // `data` stays for a helper built before batching existed. It
                // is the first of the batch, never a second copy of an event
                // the batch does not carry.
                Ok(json!({"data": batch.first(), "batch": batch}))
            }
            "screen.capture.close" => {
                let p: IdParams = serde_json::from_str(params).map_err(|e| e.to_string())?;
                let removed = sessions()
                    .lock()
                    .map_err(|_| "screen capture registry poisoned")?
                    .remove(&p.id);
                if let Some(session) = &removed
                    && let Ok(session) = session.lock()
                {
                    note_end(&p.id, &session.peer, EndReason::HelperClosed);
                }
                Ok(json!({"closed": removed.is_some()}))
            }
            _ => Err(format!("unknown screen capture method: {method}")),
        }
    })())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_session_for_one_peer_replaces_the_first() {
        let first = create("first".into(), "one-screen-peer".into(), true).unwrap();
        assert!(queue_input(&first.id, br#"{"type":"display","id":1}"#.to_vec()).is_ok());
        let second = create("second".into(), "one-screen-peer".into(), true).unwrap();
        // The replacement works and the original is gone, so the peer is not
        // being shown the same desktop twice.
        assert!(queue_input(&second.id, br#"{"type":"display","id":1}"#.to_vec()).is_ok());
        assert!(
            queue_input(&first.id, br#"{"type":"display","id":1}"#.to_vec()).is_err(),
            "the superseded session must not still be live"
        );
    }

    #[test]
    fn one_peer_does_not_end_another_peers_session() {
        let mine = create("mine".into(), "peer-a".into(), true).unwrap();
        let _theirs = create("theirs".into(), "peer-b".into(), true).unwrap();
        assert!(
            queue_input(&mine.id, br#"{"type":"display","id":1}"#.to_vec()).is_ok(),
            "another peer connecting must not end this one"
        );
    }

    // Every test names its own peer. The registry is process-wide and the
    // tests run in parallel, so two of them sharing a peer would now end each
    // other's sessions and fail for a reason that is not the rule under test.
    #[test]
    fn view_only_session_rejects_control_input() {
        let receiver = create("view-only".into(), "view-only-peer".into(), false).unwrap();
        assert!(queue_input(&receiver.id, vec![1]).is_err());
        assert!(queue_input(&receiver.id, br#"{"type":"display","id":2}"#.to_vec()).is_ok());
        assert!(
            queue_input(&receiver.id, br#"{"type":"clipboard","text":"x"}"#.to_vec()).is_err(),
            "view-only must not write the host pasteboard"
        );
    }

    #[test]
    fn narrowing_a_grant_to_view_ends_a_control_session() {
        let control = create("narrow-control".into(), "narrow-peer".into(), true).unwrap();
        revoke_peer("narrow-peer", true, false).unwrap();
        assert!(
            !sessions().lock().unwrap().contains_key(&control.id),
            "a control session must end when control is taken away"
        );
    }

    #[test]
    fn narrowing_a_grant_to_view_keeps_a_view_session() {
        let view = create("keep-view".into(), "keep-peer".into(), false).unwrap();
        revoke_peer("keep-peer", true, false).unwrap();
        assert!(sessions().lock().unwrap().contains_key(&view.id));
        revoke_peer("keep-peer", false, false).unwrap();
        assert!(
            !sessions().lock().unwrap().contains_key(&view.id),
            "removing the grant entirely must end it"
        );
    }
}
