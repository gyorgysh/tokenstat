// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Per-window account Insights reports, matching ClientInsightsModel's cache,
//! cut-specific requests and account ownership. No network is owned here.

use super::Bucket;
use crate::{chat::wire::number, work::Scope};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// UTC day index for the source chart's Gregorian calendar. Foundation uses
/// the historical Gregorian cutover, including Julian dates before it.
pub fn day_position(key: &str) -> Option<i64> {
    let mut fields = key.trim().split('-');
    let year = fields.next()?.parse::<i64>().ok()?;
    let month = fields.next()?.parse::<i64>().ok()?;
    let day = fields.next()?.parse::<i64>().ok()?;
    if fields.next().is_some() || !(1..=9999).contains(&year) || !(1..=12).contains(&month) {
        return None;
    }
    let gregorian = (year, month, day) >= (1582, 10, 15);
    let leap = year % 4 == 0 && (!gregorian || year % 100 != 0 || year % 400 == 0);
    let max_day = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    };
    if !(1..=max_day).contains(&day) {
        return None;
    }
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    let base = day + (153 * m + 2) / 5 + 365 * y + y / 4;
    let julian_day = if gregorian {
        base - y / 100 + y / 400 - 32045
    } else {
        base - 32083
    };
    Some(julian_day - 2440588)
}

#[derive(Clone, Copy, Debug, Default, Hash, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Cut {
    #[default]
    Model,
    Source,
    Day,
}
impl Cut {
    pub const ALL: [Self; 3] = [Self::Model, Self::Source, Self::Day];
    pub fn wire(self) -> &'static str {
        match self {
            Self::Model => "model",
            Self::Source => "source",
            Self::Day => "day",
        }
    }
    pub fn label_key(self) -> &'static str {
        match self {
            Self::Model => "apple.clientinsightsview.models.d17d2d78",
            Self::Source => "apple.clientinsightsview.coding_tools.6032f740",
            Self::Day => "apple.clientinsightsview.days.e08c0aa8",
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub rows: Vec<Bucket>,
    pub group: String,
    #[serde(deserialize_with = "number::i64_required")]
    pub fetched_at_ms: i64,
    pub stale: bool,
}

#[derive(Clone, Debug)]
pub struct Read {
    pub cut: Cut,
    pub owner: Scope,
    ticket: u64,
}

#[derive(Default)]
pub struct State {
    pub cut: Cut,
    owner: Option<Scope>,
    cached: HashMap<Cut, Report>,
    requests: HashMap<Cut, u64>,
    errors: HashMap<Cut, String>,
    ticket: u64,
}

impl State {
    fn synchronize_owner(&mut self, scope: Option<&Scope>) {
        if self.owner.as_ref() != scope {
            self.owner = scope.cloned();
            self.cached.clear();
            self.requests.clear();
            self.errors.clear();
        }
    }
    pub fn rows(&self, cut: Cut, current: Option<&Scope>) -> Option<&[Bucket]> {
        (self.owner.as_ref() == current)
            .then(|| self.cached.get(&cut))
            .flatten()
            .map(|r| r.rows.as_slice())
    }
    pub fn report(&self, cut: Cut, current: Option<&Scope>) -> Option<&Report> {
        (self.owner.as_ref() == current)
            .then(|| self.cached.get(&cut))
            .flatten()
    }
    pub fn loading(&self) -> bool {
        self.requests.contains_key(&self.cut)
    }
    pub fn error(&self) -> Option<&str> {
        self.errors.get(&self.cut).map(String::as_str)
    }
    pub fn needs_sign_in(&self) -> bool {
        self.error()
            .is_some_and(|s| s.to_lowercase().contains("sign in"))
    }

    fn fetch(&mut self, scope: Option<&Scope>, cancelled: bool) -> Option<Read> {
        if cancelled || self.owner.as_ref() != scope {
            return None;
        }
        let owner = self.owner.clone()?;
        self.ticket = self.ticket.wrapping_add(1);
        self.requests.insert(self.cut, self.ticket);
        Some(Read {
            cut: self.cut,
            owner,
            ticket: self.ticket,
        })
    }
    /// A cached empty report is authoritative and is not fetched again.
    pub fn load(&mut self, scope: Option<&Scope>, cancelled: bool) -> Option<Read> {
        self.synchronize_owner(scope);
        if self.cached.contains_key(&self.cut) {
            return None;
        }
        self.fetch(scope, cancelled)
    }
    /// All cuts share one underlying series; refresh retires all three.
    pub fn refresh(&mut self, scope: Option<&Scope>, cancelled: bool) -> Option<Read> {
        self.synchronize_owner(scope);
        self.requests.clear();
        self.errors.clear();
        self.cached.clear();
        self.fetch(scope, cancelled)
    }
    pub fn finish(
        &mut self,
        read: &Read,
        current: Option<&Scope>,
        cancelled: bool,
        result: Result<Report, String>,
    ) -> bool {
        let owns = self.requests.get(&read.cut) == Some(&read.ticket);
        let accepted = owns
            && !cancelled
            && self.owner.as_ref() == Some(&read.owner)
            && current == Some(&read.owner);
        if accepted {
            match result {
                Ok(report) => {
                    self.cached.insert(read.cut, report);
                    self.errors.remove(&read.cut);
                }
                Err(error) => {
                    self.errors.insert(read.cut, error);
                }
            }
        }
        // Source defer clears only this exact request, including on cancellation.
        if owns {
            self.requests.remove(&read.cut);
        }
        accepted
    }
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn account_insights(&self, cut: Cut) -> anyhow::Result<Report> {
        self.account_insights_if_current(cut, || true)
    }
    pub(crate) fn account_insights_if_current(
        &self,
        cut: Cut,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Report> {
        anyhow::ensure!(current(), "Account report was retired");
        self.prepare()?;
        anyhow::ensure!(current(), "Account report was retired");
        Ok(serde_json::from_value(self.call_with_timeout(
            "account.report",
            serde_json::json!({"group":cut.wire(), "weeks":53}),
            std::time::Duration::from_secs(600),
        )?)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn report(group: &str) -> Report {
        serde_json::from_value(json!({"rows":[],"group":group,"fetchedAtMs":1,"stale":false}))
            .unwrap()
    }

    #[test]
    fn caches_empty_cuts_and_fences_refresh_cancel_and_account_change() {
        let a = Scope::local("a");
        let b = Scope::local("b");
        let mut state = State::default();
        assert!(state.load(None, false).is_none());
        let first = state.load(Some(&a), false).unwrap();
        let successor = state.load(Some(&a), false).unwrap();
        assert!(!state.finish(&first, Some(&a), false, Ok(report("model"))));
        assert!(state.loading());
        assert!(state.finish(&successor, Some(&a), false, Ok(report("model"))));
        assert_eq!(state.rows(Cut::Model, Some(&a)).unwrap().len(), 0);
        assert!(state.load(Some(&a), false).is_none());
        state.cut = Cut::Day;
        let old_day = state.load(Some(&a), false).unwrap();
        state.cut = Cut::Source;
        let fresh = state.refresh(Some(&a), false).unwrap();
        assert!(state.rows(Cut::Model, Some(&a)).is_none());
        assert!(!state.finish(&old_day, Some(&a), false, Ok(report("day"))));
        assert!(!state.finish(&fresh, Some(&a), true, Ok(report("source"))));
        assert!(!state.loading());
        let failure = state.load(Some(&a), false).unwrap();
        assert!(state.finish(&failure, Some(&a), false, Err("Please SIGN IN".into())));
        assert!(state.needs_sign_in());
        let old = state.load(Some(&a), false).unwrap();
        assert!(state.rows(Cut::Model, Some(&b)).is_none());
        let other = state.load(Some(&b), false).unwrap();
        assert!(!state.finish(&old, Some(&b), false, Ok(report("source"))));
        assert!(state.finish(&other, Some(&b), false, Ok(report("source"))));
        assert!(state.error().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn account_report_uses_the_existing_host_with_full_required_shape() {
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        for valid in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("host.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let worker = std::thread::spawn(move || {
                drop(listener.accept().unwrap());
                for (method, result) in [
                    ("protocol", json!({"protocolVersion":"53"})),
                    (
                        "account.report",
                        if valid {
                            json!({"rows":[],"group":"day","fetchedAtMs":0,"stale":false})
                        } else {
                            json!({"rows":[]})
                        },
                    ),
                ] {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["method"], method);
                    if method == "account.report" {
                        assert_eq!(request["params"], json!({"group":"day","weeks":53}));
                    }
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":request["id"],"ok":true,"result":result})
                    )
                    .unwrap();
                }
            });
            assert_eq!(
                crate::client::Client {
                    socket,
                    allow_spawn: false
                }
                .account_insights(Cut::Day)
                .is_ok(),
                valid
            );
            worker.join().unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn retired_account_read_never_dispatches_a_report() {
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
            sync::atomic::{AtomicUsize, Ordering},
        };
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (done, done_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "protocol");
            writeln!(
                reader.get_mut(),
                "{}",
                json!({"id":request["id"],"ok":true,"result":{"protocolVersion":"53"}})
            )
            .unwrap();
            listener.set_nonblocking(true).unwrap();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            loop {
                match listener.accept() {
                    Ok(_) => panic!("retired report was dispatched"),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(error) => panic!("owned listener failed: {error}"),
                }
                if done_rx.try_recv().is_ok() {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "guarded call did not finish"
                );
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        });
        let calls = AtomicUsize::new(0);
        let client = crate::client::Client {
            socket,
            allow_spawn: false,
        };
        assert!(
            client
                .account_insights_if_current(Cut::Model, || calls.fetch_add(1, Ordering::SeqCst)
                    == 0)
                .is_err()
        );
        done.send(()).unwrap();
        worker.join().unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
}
