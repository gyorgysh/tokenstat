// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! OSC 7501 revision 0.4, observed by the process owner, including without a
//! frontend. Reports are untrusted display metadata, never approval authority.
//! Text stays in memory to distinguish attention episodes; status metadata
//! exports only structured fields, never a program's message or description.

use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use serde::Serialize;

const SEQUENCE_LIMIT: usize = 4096;
const RECORD_LIMIT: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl State {
    pub fn activity(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Idle | Self::Blocked => "idle",
            Self::Done => "done",
            Self::Error => "error",
        }
    }

    // A worker still running keeps the session working after the root turn
    // finishes. A blocked worker always wins, even over a working root.
    fn priority(self) -> u8 {
        match self {
            Self::Blocked => 5,
            Self::Error => 4,
            Self::Working => 3,
            Self::Done => 2,
            Self::Idle => 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Permission,
    Question,
    Auth,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Permission => "permission",
            Self::Question => "question",
            Self::Auth => "auth",
        }
    }
}

/// The most urgent record, with a revision identifying this attention episode.
/// Missing optional fields remain missing; reports replace rather than patch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramStatus {
    pub state: State,
    pub kind: Option<Kind>,
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub id: Option<String>,
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Record {
    state: State,
    kind: Option<Kind>,
    progress: Option<u8>,
    app: Option<String>,
    title: Option<String>,
    msg: Option<String>,
}

enum Report {
    Set(String, Record),
    Clear(String),
}

#[derive(Default)]
enum ParserState {
    #[default]
    Ground,
    Escape,
    Osc,
    OscEscape,
    // Do not interpret an OSC embedded inside another control string.
    String,
    StringEscape,
}

#[derive(Default)]
pub(crate) struct Tracker {
    parser: ParserState,
    pending: Vec<u8>,
    length: usize,
    records: BTreeMap<String, (Record, u64, u64)>,
    revision: u64,
}

impl Tracker {
    /// Observe a chunk without changing output bytes or transport offsets.
    /// The only generated input is the fixed feature-detection reply.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut replies = Vec::new();
        for &byte in bytes {
            match self.parser {
                ParserState::Ground => {
                    if byte == 0x1b {
                        self.parser = ParserState::Escape;
                    }
                }
                ParserState::Escape => self.escape(byte),
                ParserState::Osc => match byte {
                    0x07 => self.finish(1, &mut replies),
                    0x1b => self.parser = ParserState::OscEscape,
                    0x18 | 0x1a => self.parser = ParserState::Ground,
                    _ => {
                        self.length = self.length.saturating_add(1);
                        if self.length <= SEQUENCE_LIMIT {
                            self.pending.push(byte);
                        }
                    }
                },
                ParserState::OscEscape => {
                    if byte == b'\\' {
                        self.finish(2, &mut replies);
                    } else {
                        self.escape(byte);
                    }
                }
                ParserState::String => match byte {
                    0x1b => self.parser = ParserState::StringEscape,
                    0x18 | 0x1a => self.parser = ParserState::Ground,
                    _ => {}
                },
                ParserState::StringEscape => {
                    self.parser = match byte {
                        b'\\' | 0x18 | 0x1a => ParserState::Ground,
                        0x1b => ParserState::StringEscape,
                        _ => ParserState::String,
                    };
                }
            }
        }
        replies
    }

    fn escape(&mut self, byte: u8) {
        self.parser = match byte {
            b']' => {
                self.pending.clear();
                self.length = 2; // ESC ]
                ParserState::Osc
            }
            b'P' | b'X' | b'^' | b'_' => ParserState::String,
            b'c' => {
                self.records.clear(); // RIS; alternate-screen switches do not clear.
                ParserState::Ground
            }
            0x1b => ParserState::Escape,
            _ => ParserState::Ground,
        };
    }

    fn finish(&mut self, terminator: usize, replies: &mut Vec<u8>) {
        self.parser = ParserState::Ground;
        if self.length.saturating_add(terminator) > SEQUENCE_LIMIT {
            return;
        }
        if self.pending.starts_with(b"133;A") && matches!(self.pending.get(5), None | Some(b';')) {
            self.process_exited();
            return;
        }
        let Some(body) = self.pending.strip_prefix(b"7501;") else {
            return;
        };
        if body == b"?" {
            replies.extend_from_slice(b"\x1b]7501;?");
            replies.extend_from_slice(if terminator == 1 { b"\x07" } else { b"\x1b\\" });
            return;
        }
        let Some(report) = parse(body) else { return };
        match report {
            Report::Clear(id) => {
                let prefix = format!("{id}/");
                self.records
                    .retain(|key, _| !id.is_empty() && key != &id && !key.starts_with(&prefix));
            }
            Report::Set(id, record) => {
                // Repeated identical reports are not a new attention episode.
                // Still update recency for the protocol's eviction rule.
                self.revision = self.revision.saturating_add(1);
                if !self.records.contains_key(&id)
                    && self.records.len() == RECORD_LIMIT
                    && let Some(oldest) = self
                        .records
                        .iter()
                        .min_by_key(|(_, (_, _, at))| *at)
                        .map(|(id, _)| id.clone())
                {
                    self.records.remove(&oldest);
                }
                let revision = self
                    .records
                    .get(&id)
                    .filter(|(old, _, _)| {
                        old == &record
                            || (old.state == State::Blocked
                                && record.state == State::Blocked
                                && old.kind == record.kind
                                && old.msg == record.msg
                                && old.title == record.title)
                    })
                    .map_or(self.revision, |(_, at, _)| *at);
                self.records.insert(id, (record, revision, self.revision));
            }
        }
    }

    pub fn process_exited(&mut self) {
        self.records
            .retain(|_, (r, _, _)| !matches!(r.state, State::Working | State::Blocked));
    }

    pub fn snapshot(&self) -> Option<ProgramStatus> {
        let (id, (record, revision, _)) = self
            .records
            .iter()
            .max_by_key(|(_, (record, _, updated))| (record.state.priority(), *updated))?;
        let mut app = record.app.clone();
        let mut parent = id.as_str();
        while app.is_none() && !parent.is_empty() {
            parent = parent.rsplit_once('/').map_or("", |(p, _)| p);
            app = self.records.get(parent).and_then(|(r, _, _)| r.app.clone());
        }
        Some(ProgramStatus {
            state: record.state,
            kind: record.kind,
            progress: record.progress,
            app,
            id: (!id.is_empty()).then(|| id.clone()),
            revision: *revision,
        })
    }
}

fn token(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(&b))
}

fn text(value: &str, encoded_limit: usize, decoded_limit: usize) -> Option<String> {
    if value.len() > encoded_limit {
        return None;
    }
    let bytes = STANDARD
        .decode(value)
        .or_else(|_| STANDARD_NO_PAD.decode(value))
        .ok()?;
    if bytes.len() > decoded_limit {
        return None;
    }
    let text = String::from_utf8(bytes).ok()?;
    (!text.chars().any(char::is_control)).then_some(text)
}

fn parse(body: &[u8]) -> Option<Report> {
    let mut fields = BTreeMap::new();
    for pair in body.split(|&byte| byte == b':') {
        // Malformed pairs, including non-UTF-8 bytes, do not discard valid
        // pairs elsewhere in the report. Free text itself must be base64.
        let Ok(pair) = std::str::from_utf8(pair) else {
            continue;
        };
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        if key.is_empty()
            || !key.bytes().all(|b| b.is_ascii_lowercase())
            || !value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b))
        {
            continue;
        }
        // Validate every pair, including duplicates and unknown keys, before
        // applying anything. Later duplicates cannot hide an oversized field.
        if key.len() > 16 {
            return None;
        }
        match key {
            "app" if value.len() > 32 => return None,
            "id" if value.len() > 128
                || value.split('/').count() > 8
                || value.split('/').any(|segment| segment.len() > 32) =>
            {
                return None;
            }
            "title" => {
                text(value, 256, 192)?;
            }
            "msg" => {
                text(value, 2732, 2048)?;
            }
            _ => {}
        }
        fields.insert(key, value);
    }
    let id = fields.get("id").copied().unwrap_or("");
    if fields.contains_key("id")
        && (id.is_empty()
            || id.split('/').count() > 8
            || !id.split('/').all(|part| part.len() <= 32 && token(part)))
    {
        return None;
    }
    let state = match *fields.get("state")? {
        "clear" => return Some(Report::Clear(id.into())),
        "idle" => State::Idle,
        "working" => State::Working,
        "done" => State::Done,
        "blocked" => State::Blocked,
        "error" => State::Error,
        _ => return None,
    };
    let kind = if state == State::Blocked {
        match fields.get("kind").copied() {
            Some("permission") => Some(Kind::Permission),
            Some("question") => Some(Kind::Question),
            Some("auth") => Some(Kind::Auth),
            _ => None,
        }
    } else {
        None
    };
    let progress = if matches!(state, State::Working | State::Blocked) {
        fields
            .get("progress")
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|s| s.parse::<u8>().ok())
            .filter(|&n| n <= 100)
    } else {
        None
    };
    Some(Report::Set(
        id.into(),
        Record {
            state,
            kind,
            progress,
            app: fields.get("app").filter(|s| token(s)).map(|s| (*s).into()),
            title: fields.get("title").and_then(|s| text(s, 256, 192)),
            msg: fields.get("msg").and_then(|s| text(s, 2732, 2048)),
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(t: &mut Tracker, body: &str) {
        t.feed(format!("\x1b]7501;{body}\x1b\\").as_bytes());
    }

    #[test]
    fn detection_and_reports_survive_every_read_boundary() {
        let bytes = b"text\x1b]7501;?\x1b\\\x1b]7501;state=blocked:kind=question:app=claude-code:progress=42\x07";
        for split in 0..=bytes.len() {
            let mut t = Tracker::default();
            let mut reply = t.feed(&bytes[..split]);
            reply.extend(t.feed(&bytes[split..]));
            assert_eq!(reply, b"\x1b]7501;?\x1b\\");
            let status = t.snapshot().unwrap();
            assert_eq!(
                (status.state, status.kind, status.progress),
                (State::Blocked, Some(Kind::Question), Some(42))
            );
        }
        assert_eq!(
            Tracker::default().feed(b"\x1b]7501;?\x07"),
            b"\x1b]7501;?\x07"
        );
    }

    #[test]
    fn records_replace_and_children_inherit_app_and_clear_by_path() {
        let mut t = Tracker::default();
        report(&mut t, "state=working:app=claude-code:progress=30");
        report(&mut t, "state=blocked:kind=auth:id=worker/login");
        assert_eq!(t.snapshot().unwrap().app.as_deref(), Some("claude-code"));
        report(&mut t, "state=clear:id=worker");
        assert_eq!(t.snapshot().unwrap().state, State::Working);
        report(&mut t, "state=idle");
        let status = t.snapshot().unwrap();
        assert_eq!((status.app, status.progress), (None, None));
        report(&mut t, "state=clear");
        assert!(t.snapshot().is_none());
    }

    #[test]
    fn invalid_reports_do_not_partially_replace_valid_status() {
        let mut t = Tracker::default();
        report(&mut t, "state=working:app=claude-code");
        let original = t.snapshot();
        for body in [
            "state=unknown",
            "state=blocked:id=bad//id",
            "state=blocked:msg=Cg==",
            "state=blocked:title=/w==",
            "state=blocked:msg=A",
            "state=blocked:id=",
            "state=blocked:abcdefghijklmnopq=x",
        ] {
            report(&mut t, body);
            assert_eq!(t.snapshot(), original, "{body}");
        }
        report(&mut t, &format!("state=blocked:msg={}", "A".repeat(2733)));
        assert_eq!(t.snapshot(), original);
        report(
            &mut t,
            &format!("state=blocked:unknown={}", "x".repeat(4096)),
        );
        assert_eq!(t.snapshot(), original);
        report(
            &mut t,
            "junk:state=idle:state=blocked:kind=other:progress=101:new=value",
        );
        let status = t.snapshot().unwrap();
        assert_eq!(
            (status.state, status.kind, status.progress),
            (State::Blocked, None, None)
        );
        assert!(matches!(
            parse(b"invalid=\xff:state=idle"),
            Some(Report::Set(
                _,
                Record {
                    state: State::Idle,
                    ..
                }
            ))
        ));
    }

    #[test]
    fn exit_prompt_and_reset_follow_lifetimes() {
        let mut t = Tracker::default();
        report(&mut t, "state=done");
        report(&mut t, "state=working:id=worker");
        assert_eq!(t.snapshot().unwrap().state, State::Working);
        t.feed(b"\x1b[?1049h");
        assert_eq!(t.records.len(), 2);
        t.feed(b"\x1b]133;A;redraw=0\x07");
        assert_eq!(t.snapshot().unwrap().state, State::Done);
        report(&mut t, "state=blocked:id=worker");
        t.process_exited();
        assert_eq!(t.snapshot().unwrap().state, State::Done);
        t.feed(b"\x1bc");
        assert!(t.snapshot().is_none());
    }

    #[test]
    fn attention_revisions_change_for_new_questions_only() {
        let mut t = Tracker::default();
        report(&mut t, "state=blocked:kind=permission:msg=Rmlyc3Q=");
        let first = t.snapshot().unwrap().revision;
        report(&mut t, "state=blocked:kind=permission:msg=Rmlyc3Q=");
        assert_eq!(t.snapshot().unwrap().revision, first);
        report(&mut t, "state=blocked:kind=permission:msg=U2Vjb25k");
        assert!(t.snapshot().unwrap().revision > first);
        let second = t.snapshot().unwrap().revision;
        report(
            &mut t,
            "state=blocked:kind=permission:msg=U2Vjb25k:progress=50",
        );
        assert_eq!(t.snapshot().unwrap().revision, second);
        // Text is not present in the structured snapshot.
        assert_eq!(t.snapshot().unwrap().kind, Some(Kind::Permission));
    }

    #[test]
    fn control_strings_cannot_forge_reports_and_records_are_bounded() {
        let mut t = Tracker::default();
        t.feed(b"\x1bP\x1b]7501;state=blocked\x07\x1b\\");
        assert!(t.snapshot().is_none());
        for i in 0..=RECORD_LIMIT {
            report(&mut t, &format!("state=idle:id=worker{i}"));
        }
        assert_eq!(t.records.len(), RECORD_LIMIT);
        assert!(!t.records.contains_key("worker0"));
        let body = format!("state=blocked:msg={}:msg=QQ==", "A".repeat(2733));
        assert!(parse(body.as_bytes()).is_none());
        let mut t = Tracker::default();
        for i in 0..RECORD_LIMIT {
            report(&mut t, &format!("state=idle:id=worker{i}"));
        }
        report(&mut t, "state=idle:id=worker0");
        report(&mut t, "state=idle:id=new");
        assert!(
            t.records.contains_key("worker0"),
            "identical reports refresh eviction recency"
        );
        assert!(!t.records.contains_key("worker1"));
        assert!(parse(format!("state=idle:id={}:id=ok", "x".repeat(33)).as_bytes()).is_none());
    }

    #[test]
    fn oversized_sequences_are_bounded_and_do_not_poison_the_next_report() {
        let mut t = Tracker::default();
        let oversized = format!("\x1b]7501;state=blocked:extra={}\x07", "x".repeat(100_000));
        for chunk in oversized.as_bytes().chunks(7) {
            t.feed(chunk);
            assert!(t.pending.len() <= SEQUENCE_LIMIT);
        }
        assert!(t.snapshot().is_none());
        report(&mut t, "state=done:app=claude-code");
        assert_eq!(t.snapshot().unwrap().state, State::Done);
    }
}
