// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Bounded wire frames for end-to-end encrypted screen sessions.
//!
//! The remote transport already encrypts and authenticates each message. This
//! module only defines the bytes inside that tunnel and the queueing rule at a
//! slow viewer: stale encoded pictures are discarded, never accumulated.

use std::collections::VecDeque;

const MAGIC: &[u8; 4] = b"TSCR";
const VERSION: u8 = 1;
const HEADER_LEN: usize = 32;

/// One encoded picture is deliberately below the remote connection's message
/// allocation ceiling. VideoToolbox should react to pressure by lowering its
/// bitrate; an endpoint that still emits a larger access unit is refused.
pub const MAX_VIDEO_BYTES: usize = 1_048_576;
/// Keyboard and pointer batches are tiny. The bound prevents an authorized
/// controller bug from turning the input path into an allocation primitive.
pub const MAX_INPUT_BYTES: usize = 4_096;
/// At most a few compressed pictures wait for a viewer. Latency matters more
/// than preserving obsolete frames in an interactive screen session.
pub const MAX_QUEUED_VIDEO_BYTES: usize = 3 * MAX_VIDEO_BYTES;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum FrameKind {
    Video = 1,
    Input = 2,
    End = 3,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub kind: FrameKind,
    pub sequence: u64,
    pub timestamp_us: u64,
    pub width: u16,
    pub height: u16,
    /// A video keyframe, or an input batch that may be applied independently.
    pub independent: bool,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let limit = match self.kind {
            FrameKind::Video => MAX_VIDEO_BYTES,
            FrameKind::Input => MAX_INPUT_BYTES,
            FrameKind::End => 0,
        };
        if self.payload.len() > limit {
            return Err(format!(
                "screen {:?} frame is {} bytes; limit is {limit}",
                self.kind,
                self.payload.len()
            ));
        }
        if self.kind == FrameKind::End && !self.payload.is_empty() {
            return Err("screen end frame must not carry a payload".into());
        }
        let payload_len = u32::try_from(self.payload.len()).map_err(|_| "frame too large")?;
        let mut out = Vec::with_capacity(HEADER_LEN + self.payload.len());
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        out.push(self.kind as u8);
        out.push(u8::from(self.independent));
        out.push(0);
        out.extend_from_slice(&self.sequence.to_be_bytes());
        out.extend_from_slice(&self.timestamp_us.to_be_bytes());
        out.extend_from_slice(&self.width.to_be_bytes());
        out.extend_from_slice(&self.height.to_be_bytes());
        out.extend_from_slice(&payload_len.to_be_bytes());
        out.extend_from_slice(&self.payload);
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() < HEADER_LEN || &bytes[..4] != MAGIC {
            return Err("invalid screen frame header".into());
        }
        if bytes[4] != VERSION {
            return Err(format!("unsupported screen frame version {}", bytes[4]));
        }
        let kind = match bytes[5] {
            1 => FrameKind::Video,
            2 => FrameKind::Input,
            3 => FrameKind::End,
            other => return Err(format!("unknown screen frame kind {other}")),
        };
        let sequence = u64::from_be_bytes(bytes[8..16].try_into().unwrap());
        let timestamp_us = u64::from_be_bytes(bytes[16..24].try_into().unwrap());
        let width = u16::from_be_bytes(bytes[24..26].try_into().unwrap());
        let height = u16::from_be_bytes(bytes[26..28].try_into().unwrap());
        let payload_len = u32::from_be_bytes(bytes[28..32].try_into().unwrap()) as usize;
        let expected = HEADER_LEN
            .checked_add(payload_len)
            .ok_or("screen frame length overflow")?;
        if bytes.len() != expected {
            return Err("screen frame payload length does not match header".into());
        }
        let frame = Self {
            kind,
            sequence,
            timestamp_us,
            width,
            height,
            independent: bytes[6] & 1 == 1,
            payload: bytes[HEADER_LEN..].to_vec(),
        };
        // Reuse the encoder's semantic and size validation without retaining
        // its allocation.
        frame.encode()?;
        Ok(frame)
    }
}

/// A decoder-safe latest-frame queue.
///
/// Dropping an H.264 delta picture invalidates every later delta that depends
/// on it. When pressure forces a drop, the whole queue is cleared and deltas
/// are ignored until the endpoint supplies another keyframe.
#[derive(Debug, Default)]
pub struct VideoQueue {
    frames: VecDeque<Frame>,
    bytes: usize,
    waiting_for_keyframe: bool,
    dropped: u64,
    last_sequence: Option<u64>,
}

impl VideoQueue {
    pub fn push(&mut self, frame: Frame) -> Result<bool, String> {
        if frame.kind != FrameKind::Video {
            return Err("only video frames belong in the video queue".into());
        }
        if frame.payload.len() > MAX_VIDEO_BYTES {
            return Err("video frame exceeds the bounded queue frame limit".into());
        }
        let gap = self
            .last_sequence
            .is_some_and(|last| frame.sequence != last.saturating_add(1));
        self.last_sequence = Some(frame.sequence);
        if gap && !frame.independent {
            self.dropped += self.frames.len() as u64 + 1;
            self.frames.clear();
            self.bytes = 0;
            self.waiting_for_keyframe = true;
            return Ok(false);
        }
        if self.waiting_for_keyframe && !frame.independent {
            self.dropped += 1;
            return Ok(false);
        }
        if frame.independent && self.waiting_for_keyframe {
            self.waiting_for_keyframe = false;
        }
        if self.bytes.saturating_add(frame.payload.len()) > MAX_QUEUED_VIDEO_BYTES {
            self.dropped += self.frames.len() as u64;
            self.bytes = 0;
            self.frames.clear();
            if !frame.independent {
                self.waiting_for_keyframe = true;
                self.dropped += 1;
                return Ok(false);
            }
        }
        self.bytes += frame.payload.len();
        self.frames.push_back(frame);
        Ok(true)
    }

    pub fn pop(&mut self) -> Option<Frame> {
        let frame = self.frames.pop_front()?;
        self.bytes = self.bytes.saturating_sub(frame.payload.len());
        Some(frame)
    }

    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    pub fn queued_bytes(&self) -> usize {
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn video(sequence: u64, size: usize, keyframe: bool) -> Frame {
        Frame {
            kind: FrameKind::Video,
            sequence,
            timestamp_us: sequence * 1_000,
            width: 1920,
            height: 1080,
            independent: keyframe,
            payload: vec![sequence as u8; size],
        }
    }

    #[test]
    fn frame_round_trips_without_json_or_base64() {
        let frame = video(42, 128, true);
        assert_eq!(Frame::decode(&frame.encode().unwrap()).unwrap(), frame);
    }

    #[test]
    fn malformed_and_oversized_frames_are_refused() {
        assert!(video(1, MAX_VIDEO_BYTES + 1, true).encode().is_err());
        let mut encoded = video(1, 8, true).encode().unwrap();
        encoded[31] = 9;
        assert!(Frame::decode(&encoded).is_err());
    }

    #[test]
    fn pressure_drops_stale_dependency_chain_until_a_keyframe() {
        let mut queue = VideoQueue::default();
        assert!(queue.push(video(1, MAX_VIDEO_BYTES, true)).unwrap());
        assert!(queue.push(video(2, MAX_VIDEO_BYTES, false)).unwrap());
        assert!(queue.push(video(3, MAX_VIDEO_BYTES, false)).unwrap());
        assert!(!queue.push(video(4, 1, false)).unwrap());
        assert_eq!(queue.queued_bytes(), 0);
        assert!(!queue.push(video(5, 1, false)).unwrap());
        assert!(queue.push(video(6, 16, true)).unwrap());
        assert_eq!(queue.pop().unwrap().sequence, 6);
        assert_eq!(queue.dropped(), 5);
    }

    #[test]
    fn a_transport_sequence_gap_waits_for_a_new_keyframe() {
        let mut queue = VideoQueue::default();
        assert!(queue.push(video(1, 8, true)).unwrap());
        assert!(!queue.push(video(3, 8, false)).unwrap());
        assert!(!queue.push(video(4, 8, false)).unwrap());
        assert!(queue.push(video(5, 8, true)).unwrap());
        assert_eq!(queue.pop().unwrap().sequence, 5);
    }
}
