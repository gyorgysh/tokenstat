// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Per-session Windows capture. Runs inside hostd, including Always-On mode.
//! Permission and encryption remain owned by screen_runtime and remote_stream.

use std::collections::HashSet;
use std::ffi::c_void;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::screen_stream::{Frame, FrameKind};

#[derive(Clone, Copy, Default)]
#[repr(C)]
struct Display {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
}

unsafe extern "C" {
    fn ts_screen_displays(target: *mut Display, capacity: u32) -> u32;
    fn ts_screen_create(
        display: u32,
        width: u32,
        fps: u32,
        bitrate: u32,
        test: i32,
        error: *mut i32,
    ) -> *mut c_void;
    fn ts_screen_destroy(handle: *mut c_void);
    fn ts_screen_next(
        handle: *mut c_void,
        force: i32,
        bytes: *mut *const u8,
        length: *mut u32,
        width: *mut u32,
        height: *mut u32,
        key: *mut i32,
        stamp: *mut u64,
    ) -> i32;
    fn ts_screen_mouse(x: i32, y: i32, flags: u32, wheel: i32) -> i32;
    fn ts_screen_key(code: u16, down: i32, unicode: i32) -> i32;
}

struct Capture(*mut c_void);
impl Drop for Capture {
    fn drop(&mut self) {
        // SAFETY: the native handle is owned by this value and never moved to another thread.
        unsafe { ts_screen_destroy(self.0) };
    }
}
impl Capture {
    fn new(display: u32, quality: &str, relay: bool, test: bool) -> Result<Self, String> {
        let (width, fps, bitrate) = match quality {
            "sharp" => (1920, 20, 5_000_000),
            "smooth" => (1280, 30, 3_000_000),
            "dataSaver" => (960, 10, 700_000),
            _ if relay => (1280, 20, 1_600_000),
            _ => (1920, 30, 4_000_000),
        };
        let mut error = 0;
        // SAFETY: all output pointers refer to initialized, writable values.
        let handle =
            unsafe { ts_screen_create(display, width, fps, bitrate, i32::from(test), &mut error) };
        if handle.is_null() {
            return Err(format!(
                "Windows screen capture could not start (0x{:08X}). Check that the desktop is unlocked and Media Foundation is installed.",
                error as u32
            ));
        }
        Ok(Self(handle))
    }

    fn next(&mut self, force: bool, sequence: u64) -> Result<Option<Frame>, String> {
        let (mut bytes, mut len, mut width, mut height, mut key, mut stamp) =
            (std::ptr::null(), 0, 0, 0, 0, 0);
        // SAFETY: this live handle stays on its creation thread. The returned buffer
        // belongs to it until next(), and is copied before any subsequent native call.
        let result = unsafe {
            ts_screen_next(
                self.0,
                i32::from(force),
                &mut bytes,
                &mut len,
                &mut width,
                &mut height,
                &mut key,
                &mut stamp,
            )
        };
        if result < 0 {
            return Err(format!(
                "Windows screen capture stopped (0x{:08X}). Unlock the desktop and reconnect.",
                result as u32
            ));
        }
        if len == 0 {
            return Ok(None);
        }
        if bytes.is_null()
            || len as usize > crate::screen_stream::MAX_VIDEO_BYTES
            || width > u16::MAX.into()
            || height > u16::MAX.into()
        {
            return Err("Windows encoder returned an invalid frame".into());
        }
        // SAFETY: the native encoder owns at least len bytes, checked above and copied now.
        let payload = unsafe { std::slice::from_raw_parts(bytes, len as usize) }.to_vec();
        Ok(Some(Frame {
            kind: FrameKind::Video,
            sequence,
            timestamp_us: stamp,
            width: width as u16,
            height: height as u16,
            independent: key != 0,
            payload,
        }))
    }
}

fn inventory() -> Vec<Display> {
    let mut items = vec![Display::default(); 32];
    // SAFETY: the native function writes no more than the supplied capacity.
    let count = unsafe { ts_screen_displays(items.as_mut_ptr(), items.len() as u32) };
    items.truncate((count as usize).min(items.len()));
    items
}

fn call(method: &str, params: Value) -> Result<Value, String> {
    crate::screen_runtime::call(method, &params.to_string())
        .ok_or("screen capture method unavailable")?
}
fn push(id: &str, frame: Frame) -> Result<bool, String> {
    let bytes = frame.encode()?;
    let result = call(
        "screen.capture.push",
        json!({"id": id, "frame": crate::base64::encode(&bytes)}),
    )?;
    Ok(result["accepted"].as_bool().unwrap_or(false))
}
fn metadata(id: &str, selected: usize, displays: &[Display]) -> Result<(), String> {
    let data: Vec<Value> = displays.iter().enumerate().map(|(i, display)| json!({
        "id": i, "name": if i == 0 { "Main display".to_owned() } else { format!("Display {}", i + 1) },
        "width": display.width, "height": display.height,
    })).collect();
    push(
        id,
        Frame {
            kind: FrameKind::Metadata,
            sequence: 0,
            timestamp_us: 0,
            width: 0,
            height: 0,
            independent: true,
            payload: serde_json::to_vec(
                &json!({"type": "displays", "selected": selected, "displays": data}),
            )
            .map_err(|e| e.to_string())?,
        },
    )?;
    Ok(())
}

pub(crate) fn start(id: String) -> Result<(), String> {
    std::thread::Builder::new()
        .name("windows-screen".into())
        .spawn(move || {
            if let Err(error) = run(&id) {
                eprintln!("[screen] {id}: {error}");
                let _ = push(
                    &id,
                    Frame {
                        kind: FrameKind::Error,
                        sequence: 0,
                        timestamp_us: 0,
                        width: 0,
                        height: 0,
                        independent: true,
                        payload: error.into_bytes(),
                    },
                );
            }
            let _ = call("screen.capture.close", json!({"id": id}));
        })
        .map(|_| ())
        .map_err(|e| e.to_string())
}

fn run(id: &str) -> Result<(), String> {
    let displays = inventory();
    if displays.is_empty() {
        return Err("No Windows desktop is available to share".into());
    }
    let started = Instant::now();
    let mut selected = 0usize;
    let mut capture = None;
    let mut settings = String::new();
    let mut input = InputState::default();
    let mut next_poll = Instant::now();
    let mut next_frame = Instant::now();
    let mut control = false;
    let mut sequence = 0;
    let mut force = true;
    let mut interval = Duration::from_millis(50);
    loop {
        if Instant::now() >= next_poll {
            let list = call("screen.capture.list", json!({}))?;
            let session = list
                .as_array()
                .and_then(|items| items.iter().find(|item| item["id"].as_str() == Some(id)));
            let Some(session) = session else {
                return Ok(());
            };
            let allowed = session["control"].as_bool().unwrap_or(false);
            if control && !allowed {
                input.release();
            }
            control = allowed;
            let quality = session["quality"].as_str().unwrap_or("auto");
            let relay = session["route"].as_str() != Some("direct");
            let key = format!("{selected}:{quality}:{relay}");
            if settings != key {
                drop(capture.take()); // Drop the old COM/GDI resources on this thread first.
                capture = Some(Capture::new(selected as u32, quality, relay, false)?);
                interval = Duration::from_millis(match quality {
                    "dataSaver" => 100,
                    "sharp" => 50,
                    "smooth" => 33,
                    _ if relay => 50,
                    _ => 33,
                });
                settings = key;
                force = true;
                metadata(id, selected, &displays)?;
            }
            next_poll = Instant::now() + Duration::from_millis(100);
        }
        let pending = call("screen.capture.input", json!({"id": id}))?;
        if let Some(batch) = pending["batch"].as_array() {
            for data in batch {
                let Some(data) = data.as_str() else {
                    continue;
                };
                let Ok(bytes) = crate::base64::decode(data) else {
                    continue;
                };
                let Ok(event) = serde_json::from_slice::<Input>(&bytes) else {
                    continue;
                };
                if event.kind == "display" {
                    if let Some(index) = event
                        .id
                        .and_then(|n| usize::try_from(n).ok())
                        .filter(|n| *n < displays.len())
                    {
                        if selected != index {
                            input.release();
                            selected = index;
                            next_poll = Instant::now();
                        }
                    }
                } else if control {
                    input.apply(event, displays[selected], &displays);
                }
            }
        }
        if Instant::now() >= next_frame {
            if let Some(encoder) = capture.as_mut() {
                if let Some(mut frame) = encoder.next(force, sequence + 1)? {
                    sequence += 1;
                    frame.timestamp_us = started.elapsed().as_micros().min(u64::MAX as u128) as u64;
                    let key = frame.independent;
                    let accepted = push(id, frame)?;
                    if !accepted {
                        force = true;
                    } else if key {
                        force = false;
                    }
                }
            }
            next_frame = Instant::now() + interval;
        }
        std::thread::sleep(Duration::from_millis(8));
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    #[serde(rename = "type")]
    kind: String,
    x: Option<f64>,
    y: Option<f64>,
    id: Option<u64>,
    button: Option<u32>,
    down: Option<bool>,
    key_code: Option<u16>,
    flags: Option<u64>,
    text: Option<String>,
    dx: Option<f64>,
    dy: Option<f64>,
    click_count: Option<u32>,
}
#[derive(Default)]
struct InputState {
    keys: HashSet<u16>,
    buttons: HashSet<u32>,
}
impl Drop for InputState {
    fn drop(&mut self) {
        self.release();
    }
}
impl InputState {
    fn key(&mut self, key: u16, down: bool) {
        // SAFETY: SendInput consumes a by-value key code; no borrowed storage crosses FFI.
        if unsafe { ts_screen_key(key, i32::from(down), 0) } != 0 {
            if down {
                self.keys.insert(key);
            } else {
                self.keys.remove(&key);
            }
        }
    }
    fn button(&mut self, button: u32, down: bool) {
        let flags = match (button, down) {
            (0, true) => 2,
            (0, false) => 4,
            (1, true) => 8,
            (1, false) => 16,
            (2, true) => 32,
            (2, false) => 64,
            _ => return,
        };
        // SAFETY: SendInput consumes these scalar values synchronously.
        if unsafe { ts_screen_mouse(0, 0, flags, 0) } != 0 {
            if down {
                self.buttons.insert(button);
            } else {
                self.buttons.remove(&button);
            }
        }
    }
    fn release(&mut self) {
        for key in self.keys.clone() {
            self.key(key, false);
        }
        for button in self.buttons.clone() {
            self.button(button, false);
        }
        self.keys.clear();
        self.buttons.clear();
    }
    fn apply(&mut self, event: Input, display: Display, all: &[Display]) {
        if let Some(flags) = event.flags {
            // The shared wire uses CGEvent flags, not Windows modifier bits.
            for (mask, key) in [
                (1 << 17, 0x10),
                (1 << 18, 0x11),
                (1 << 19, 0x12),
                (1 << 20, 0x5b),
            ] {
                let down = flags & mask != 0;
                if self.keys.contains(&key) != down {
                    self.key(key, down);
                }
            }
        }
        if matches!(
            event.kind.as_str(),
            "move" | "mouse" | "pointer" | "click" | "scroll"
        ) {
            if let (Some(x), Some(y)) = (event.x, event.y) {
                if !x.is_finite() || !y.is_finite() {
                    return;
                }
                let left = all.iter().map(|d| d.left).min().unwrap_or(0);
                let top = all.iter().map(|d| d.top).min().unwrap_or(0);
                let right = all.iter().map(|d| d.left + d.width).max().unwrap_or(1);
                let bottom = all.iter().map(|d| d.top + d.height).max().unwrap_or(1);
                let px = display.left as f64 + x.clamp(0.0, 1.0) * (display.width - 1) as f64;
                let py = display.top as f64 + y.clamp(0.0, 1.0) * (display.height - 1) as f64;
                let nx =
                    ((px - left as f64) * 65535.0 / f64::from((right - left - 1).max(1))) as i32;
                let ny =
                    ((py - top as f64) * 65535.0 / f64::from((bottom - top - 1).max(1))) as i32;
                // SAFETY: absolute pointer coordinates have been clamped to the desktop.
                unsafe {
                    ts_screen_mouse(nx, ny, 0x8000 | 0x4000 | 1, 0);
                }
            }
        }
        match event.kind.as_str() {
            "pointer" => self.button(0, event.down == Some(true)),
            "mouse" => self.button(event.button.unwrap_or(0), event.down == Some(true)),
            "click" => {
                for _ in 0..event.click_count.unwrap_or(1).clamp(1, 3) {
                    self.button(event.button.unwrap_or(0), true);
                    self.button(event.button.unwrap_or(0), false);
                }
            }
            "key" => {
                if let Some(key) = event.key_code.and_then(windows_key) {
                    self.key(key, event.down == Some(true));
                }
            }
            "text" => {
                if let Some(text) = event.text.filter(|text| text.len() <= 4096) {
                    for code in text.encode_utf16() {
                        // SAFETY: individual UTF-16 code units are copied into SendInput immediately.
                        unsafe {
                            ts_screen_key(code, 1, 1);
                            ts_screen_key(code, 0, 1);
                        }
                    }
                }
            }
            "scroll" => {
                for (amount, flag) in [(event.dy, 0x0800), (event.dx, 0x1000)] {
                    if let Some(amount) = amount.filter(|n| n.is_finite()) {
                        // Convert bounded pixel motion into proportional Windows wheel units.
                        unsafe {
                            ts_screen_mouse(
                                0,
                                0,
                                flag,
                                (amount.clamp(-2000.0, 2000.0) * 3.0) as i32,
                            );
                        }
                    }
                }
            }
            _ => (),
        }
    }
}

// Physical macOS key codes are the existing cross-platform screen wire contract.
fn windows_key(key: u16) -> Option<u16> {
    Some(match key {
        0 => 0x41,
        1 => 0x53,
        2 => 0x44,
        3 => 0x46,
        4 => 0x48,
        5 => 0x47,
        6 => 0x5a,
        7 => 0x58,
        8 => 0x43,
        9 => 0x56,
        11 => 0x42,
        12 => 0x51,
        13 => 0x57,
        14 => 0x45,
        15 => 0x52,
        16 => 0x59,
        17 => 0x54,
        18 => 0x31,
        19 => 0x32,
        20 => 0x33,
        21 => 0x34,
        22 => 0x36,
        23 => 0x35,
        24 => 0xbb,
        25 => 0x39,
        26 => 0x37,
        27 => 0xbd,
        28 => 0x38,
        29 => 0x30,
        30 => 0xdd,
        31 => 0x4f,
        32 => 0x55,
        33 => 0xdb,
        34 => 0x49,
        35 => 0x50,
        36 => 0x0d,
        37 => 0x4c,
        38 => 0x4a,
        39 => 0xde,
        40 => 0x4b,
        41 => 0xba,
        42 => 0xdc,
        43 => 0xbc,
        44 => 0xbf,
        45 => 0x4e,
        46 => 0x4d,
        47 => 0xbe,
        48 => 0x09,
        49 => 0x20,
        50 => 0xc0,
        51 => 0x08,
        53 => 0x1b,
        54 => 0x5c,
        55 => 0x5b,
        56 => 0xa0,
        57 => 0x14,
        58 => 0xa4,
        59 => 0xa2,
        60 => 0xa1,
        61 => 0xa5,
        62 => 0xa3,
        65 => 0x6e,
        67 => 0x6a,
        69 => 0x6b,
        71 => 0x90,
        75 => 0x6f,
        76 => 0x0d,
        78 => 0x6d,
        82 => 0x60,
        83 => 0x61,
        84 => 0x62,
        85 => 0x63,
        86 => 0x64,
        87 => 0x65,
        88 => 0x66,
        89 => 0x67,
        91 => 0x68,
        92 => 0x69,
        96 => 0x74,
        97 => 0x75,
        98 => 0x76,
        99 => 0x72,
        100 => 0x77,
        101 => 0x78,
        103 => 0x7a,
        109 => 0x79,
        111 => 0x7b,
        114 => 0x2d,
        115 => 0x24,
        116 => 0x21,
        117 => 0x2e,
        118 => 0x73,
        119 => 0x23,
        120 => 0x71,
        121 => 0x22,
        122 => 0x70,
        123 => 0x25,
        124 => 0x27,
        125 => 0x28,
        126 => 0x26,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_encoder_produces_an_independent_annex_b_frame() {
        let mut encoder =
            Capture::new(0, "auto", false, true).expect("Windows Media Foundation encoder");
        let fixture = std::env::var_os("TOKENSTAT_SCREEN_FIXTURE").map(std::path::PathBuf::from);
        if let Some(path) = &fixture {
            std::fs::create_dir_all(path).unwrap();
        }
        let mut produced = 0;
        for sequence in 1..=30 {
            if let Some(frame) = encoder.next(sequence == 1, sequence).unwrap() {
                if produced == 0 {
                    assert!(frame.independent);
                    for nal in [5, 7, 8] {
                        assert!(
                            frame
                                .payload
                                .windows(5)
                                .any(|bytes| bytes[..4] == [0, 0, 0, 1] && bytes[4] & 31 == nal),
                            "missing NAL {nal}"
                        );
                    }
                }
                assert_eq!((frame.width, frame.height), (320, 180));
                assert!(frame.payload.starts_with(&[0, 0, 0, 1]));
                let bytes = frame.encode().unwrap();
                assert_eq!(Frame::decode(&bytes).unwrap(), frame);
                if let Some(path) = &fixture {
                    std::fs::write(path.join(format!("frame-{produced:02}.bin")), bytes).unwrap();
                }
                produced += 1;
            }
        }
        assert!(produced >= 3, "encoder did not produce enough frames");
    }

    #[test]
    fn shared_keyboard_codes_translate_to_windows() {
        assert_eq!(windows_key(0), Some(0x41));
        assert_eq!(windows_key(36), Some(0x0d));
        assert_eq!(windows_key(55), Some(0x5b));
        assert_eq!(windows_key(123), Some(0x25));
        assert_eq!(windows_key(u16::MAX), None);
    }
}
