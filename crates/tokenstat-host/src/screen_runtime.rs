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
    /// How the viewer reached this machine.
    ///
    /// The capture helper reads it and picks how much picture to spend. A
    /// relay channel is metered bandwidth pueev pays for by the gigabyte; a
    /// direct one is the person's own network, and the same desktop can be far
    /// sharper on it for nothing.
    route: crate::remote::Route,
    /// What the viewer asked for, when it asked for anything. A name from a
    /// fixed set, never a number: nothing arbitrary crosses this boundary.
    quality: Option<ScreenQuality>,
    frames: SyncSender<Vec<u8>>,
    input: VecDeque<Vec<u8>>,
    dropped: u64,
}

/// The pictures a viewer may ask for.
///
/// A closed set, so a device cannot name a bitrate. Auto is the default and
/// means the host decides from the route.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ScreenQuality {
    Auto,
    Sharp,
    Smooth,
    DataSaver,
}

impl ScreenQuality {
    fn parse(name: &str) -> Option<Self> {
        match name {
            "auto" => Some(Self::Auto),
            "sharp" => Some(Self::Sharp),
            "smooth" => Some(Self::Smooth),
            "dataSaver" => Some(Self::DataSaver),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Sharp => "sharp",
            Self::Smooth => "smooth",
            Self::DataSaver => "dataSaver",
        }
    }
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

pub(crate) fn create(
    id: String,
    peer: String,
    control: bool,
    quality: Option<String>,
    route: crate::remote::Route,
) -> Result<CaptureReceiver, String> {
    // An unrecognised name is a refusal, not a shrug into auto. A viewer that
    // asked for something this host has never heard of should be told rather
    // than quietly given a different picture.
    let quality = match quality {
        Some(name) => Some(
            ScreenQuality::parse(&name).ok_or_else(|| format!("unknown screen quality: {name}"))?,
        ),
        None => None,
    };
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
                route,
                quality,
                frames: tx,
                input: VecDeque::new(),
                dropped: 0,
            })),
        );
    Ok(CaptureReceiver { id, receiver: rx })
}

/// Turn input on or off on a session that is already running.
///
/// Control used to be decided once, when the stream opened, so the only way to
/// hand a phone the mouse was to tear the session down and dial a fresh one.
/// That reopen is what the relay refuses with `screen_already_open`: it counts
/// one screen channel per account, and the old channel is still closing when
/// the new one asks. Flipping the flag on the live session means there is no
/// second channel to refuse.
///
/// The caller has already checked the capability. `peer` is checked here too,
/// so a capability that verified for one device cannot be aimed at another
/// device's session id.
pub(crate) fn set_control(id: &str, peer: &str, control: bool) -> Result<(), String> {
    let session = sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?
        .get(id)
        .cloned()
        .ok_or("screen capture session is no longer active")?;
    let mut held = session.lock().map_err(|_| "capture session poisoned")?;
    if held.peer != peer {
        return Err("that screen session belongs to another device".into());
    }
    // Input queued under the old answer is not what the new one means. Handing
    // control back with a press still in the queue would deliver it after the
    // viewer believed it had let go.
    if held.control != control {
        held.input.clear();
    }
    held.control = control;
    Ok(())
}

/// Change what a live session may spend.
///
/// No reopen, for the same reason control does not reopen: the relay allows one
/// screen channel per account and the replacement arrives before the old one
/// has finished closing. The capture helper reads this off the session list it
/// already polls, so the picture changes without stopping.
pub(crate) fn set_quality(id: &str, peer: &str, quality: &str) -> Result<(), String> {
    let quality = ScreenQuality::parse(quality)
        .ok_or_else(|| format!("unknown screen quality: {quality}"))?;
    let session = sessions()
        .lock()
        .map_err(|_| "screen capture registry poisoned")?
        .get(id)
        .cloned()
        .ok_or("screen capture session is no longer active")?;
    let mut held = session.lock().map_err(|_| "capture session poisoned")?;
    if held.peer != peer {
        return Err("that screen session belongs to another device".into());
    }
    held.quality = Some(quality);
    Ok(())
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
                    out.push(json!({
                        "id": id,
                        "peerId": session.peer,
                        "control": session.control,
                        "dropped": session.dropped,
                        "route": session.route.as_str(),
                        "quality": session.quality.map(ScreenQuality::as_str),
                    }));
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
        let first = create(
            "first".into(),
            "one-screen-peer".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        assert!(queue_input(&first.id, br#"{"type":"display","id":1}"#.to_vec()).is_ok());
        let second = create(
            "second".into(),
            "one-screen-peer".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
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
        let mine = create(
            "mine".into(),
            "peer-a".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        let _theirs = create(
            "theirs".into(),
            "peer-b".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
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
        let receiver = create(
            "view-only".into(),
            "view-only-peer".into(),
            false,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        assert!(queue_input(&receiver.id, vec![1]).is_err());
        assert!(queue_input(&receiver.id, br#"{"type":"display","id":2}"#.to_vec()).is_ok());
        assert!(
            queue_input(&receiver.id, br#"{"type":"clipboard","text":"x"}"#.to_vec()).is_err(),
            "view-only must not write the host pasteboard"
        );
    }

    #[test]
    fn narrowing_a_grant_to_view_ends_a_control_session() {
        let control = create(
            "narrow-control".into(),
            "narrow-peer".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        revoke_peer("narrow-peer", true, false).unwrap();
        assert!(
            !sessions().lock().unwrap().contains_key(&control.id),
            "a control session must end when control is taken away"
        );
    }

    #[test]
    fn control_is_handed_over_on_the_live_session() {
        let session = create(
            "flip".into(),
            "flip-peer".into(),
            false,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        assert!(
            queue_input(&session.id, br#"{"type":"move","x":0.5,"y":0.5}"#.to_vec()).is_err(),
            "a view-only session must not carry a pointer"
        );
        set_control(&session.id, "flip-peer", true).unwrap();
        assert!(
            queue_input(&session.id, br#"{"type":"move","x":0.5,"y":0.5}"#.to_vec()).is_ok(),
            "the same session carries input once control is granted"
        );
        set_control(&session.id, "flip-peer", false).unwrap();
        assert!(
            queue_input(&session.id, br#"{"type":"move","x":0.5,"y":0.5}"#.to_vec()).is_err(),
            "handing control back must take the pointer away again"
        );
    }

    #[test]
    fn handing_control_back_drops_what_was_queued() {
        let session = create(
            "flip-queue".into(),
            "flip-queue-peer".into(),
            true,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        queue_input(
            &session.id,
            br#"{"type":"mouse","button":0,"down":true}"#.to_vec(),
        )
        .unwrap();
        set_control(&session.id, "flip-queue-peer", false).unwrap();
        let held = sessions()
            .lock()
            .unwrap()
            .get(&session.id)
            .cloned()
            .unwrap();
        assert!(
            held.lock().unwrap().input.is_empty(),
            "a press queued before control went back must not be delivered after it"
        );
    }

    #[test]
    fn one_device_cannot_flip_control_on_another_devices_session() {
        let session = create(
            "flip-theirs".into(),
            "flip-owner".into(),
            false,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        assert!(
            set_control(&session.id, "flip-intruder", true).is_err(),
            "a capability verified for one device must not reach another device's session"
        );
        assert!(set_control("no-such-session", "flip-owner", true).is_err());
    }

    #[test]
    fn narrowing_a_grant_to_view_keeps_a_view_session() {
        let view = create(
            "keep-view".into(),
            "keep-peer".into(),
            false,
            None,
            crate::remote::Route::Relay,
        )
        .unwrap();
        revoke_peer("keep-peer", true, false).unwrap();
        assert!(sessions().lock().unwrap().contains_key(&view.id));
        revoke_peer("keep-peer", false, false).unwrap();
        assert!(
            !sessions().lock().unwrap().contains_key(&view.id),
            "removing the grant entirely must end it"
        );
    }
}
