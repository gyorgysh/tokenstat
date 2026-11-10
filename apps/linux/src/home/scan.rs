// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! First-scan state and the existing host's scan RPC. The future Insights
//! screen must use the same per-window owner as the Home card.

use serde::Deserialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum StepState {
    Done,
    Now,
    Next,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    Scan,
    SignIn,
}

#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub number: usize,
    pub state: StepState,
    pub title_key: &'static str,
    pub body_key: &'static str,
    pub action: Option<Action>,
}

/// The original card's three steps and its current account/scan branches.
pub fn steps(signed_in: bool, scanning: bool, cooling_down: bool) -> [Step; 3] {
    [
        Step {
            number: 1,
            state: StepState::Done,
            title_key: "apple.gettingstartedcard.installed.f8b32f4e",
            body_key: "apple.gettingstartedcard.you_are_looking_at_it_nothing_else_to_put.4b0687ad",
            action: None,
        },
        Step {
            number: 2,
            state: StepState::Now,
            title_key: if scanning {
                "apple.gettingstartedcard.scanning.474ad819"
            } else {
                "apple.gettingstartedcard.run_the_first_scan.a22d6e64"
            },
            body_key: if scanning {
                "apple.gettingstartedcard.reading_what_is_already_on_disk_the_grid_b.93b10b34"
            } else if cooling_down {
                "apple.gettingstartedcard.that_scan_found_nothing_new_give_it_a_mome.2233cea9"
            } else {
                "apple.gettingstartedcard.it_reads_what_is_already_on_disk_so_the_fi.52893eb3"
            },
            action: (!scanning && !cooling_down).then_some(Action::Scan),
        },
        Step {
            number: 3,
            state: if signed_in {
                StepState::Done
            } else {
                StepState::Next
            },
            title_key: if signed_in {
                "apple.gettingstartedcard.connected_to_your_account.ba93f5ad"
            } else {
                "apple.gettingstartedcard.add_your_iphone_or_ipad_if_you_want_it.610773d5"
            },
            body_key: if signed_in {
                "apple.gettingstartedcard.your_devices_share_one_account_so_they_sho.db11b361"
            } else {
                "apple.gettingstartedcard.optional_and_this_mac_counts_either_way_an.bae6cb80"
            },
            action: (!signed_in).then_some(Action::SignIn),
        },
    ]
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub files_found: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub files_read: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub rows_seen: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub events_new: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub events_recovered: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub days_recovered: u64,
    #[serde(deserialize_with = "crate::chat::wire::number::u64_required")]
    pub elapsed_ms: u64,
    pub warnings: Vec<String>,
}

#[derive(Default)]
pub struct State {
    pub scanning: bool,
    pub cooling_down: bool,
    pub error: Option<String>,
    pub action: Option<String>,
    ticket: u64,
    refreshing: bool,
}

impl State {
    pub fn begin(&mut self) -> Option<u64> {
        if self.scanning || self.cooling_down {
            return None;
        }
        self.ticket = self.ticket.wrapping_add(1);
        self.scanning = true;
        self.refreshing = false;
        self.action = None;
        Some(self.ticket)
    }
    /// A successful scan starts the cooldown and Insights refresh, while the
    /// source still reports scanning until that refresh finishes.
    pub fn finish_scan(&mut self, ticket: u64, result: Result<Report, String>) -> bool {
        if !self.scanning || self.refreshing || ticket != self.ticket {
            return false;
        }
        match result {
            Ok(report) => {
                self.refreshing = true;
                self.cooling_down = true;
                self.action = Some(crate::localization::text(
                    "apple.insightsmodel.scan_complete_added_0_new_events_from_1_fi.0eff738d",
                    &[
                        &report.events_new.to_string(),
                        &report.files_read.to_string(),
                    ],
                ));
                true
            }
            Err(error) => {
                self.scanning = false;
                self.error = Some(error);
                false
            }
        }
    }
    /// The source posts archiveDidChange after refresh returns, even when the
    /// refresh handled a read error. The caller emits it only on true.
    pub fn awaiting_refresh(&self, ticket: u64) -> bool {
        self.scanning && self.refreshing && ticket == self.ticket
    }
    pub fn finish_refresh(&mut self, ticket: u64) -> bool {
        if !self.awaiting_refresh(ticket) {
            return false;
        }
        self.refreshing = false;
        self.scanning = false;
        true
    }
    pub fn expire(&mut self, ticket: u64) -> bool {
        if self.ticket != ticket || !self.cooling_down {
            return false;
        }
        self.cooling_down = false;
        true
    }
    pub fn expire_action(&mut self, ticket: u64) -> bool {
        if self.ticket != ticket || self.action.is_none() {
            return false;
        }
        self.action = None;
        true
    }
}

#[cfg(unix)]
impl crate::client::Client {
    /// Swift Bridge.scan uses the long 600-second patience for archive walks.
    pub fn scan(&self) -> anyhow::Result<Report> {
        self.prepare()?;
        Ok(serde_json::from_value(self.call_with_timeout(
            "scan",
            serde_json::json!({}),
            std::time::Duration::from_secs(600),
        )?)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report() -> Report {
        serde_json::from_value(serde_json::json!({"filesFound":2,"filesRead":1,"rowsSeen":3,"eventsNew":2,"eventsRecovered":0,"daysRecovered":0,"elapsedMs":10,"warnings":[]})).unwrap()
    }

    #[test]
    fn scans_share_one_window_owner_and_only_success_starts_cooldown() {
        let mut state = State::default();
        let first = state.begin().unwrap();
        assert!(state.begin().is_none());
        assert!(!state.finish_scan(first + 1, Ok(report())));
        assert!(state.scanning && !state.cooling_down);
        assert!(!state.finish_scan(first, Err("offline".into())));
        assert_eq!(state.error.as_deref(), Some("offline"));
        let second = state.begin().unwrap();
        assert!(state.finish_scan(second, Ok(report())));
        assert!(state.cooling_down && state.scanning && state.begin().is_none());
        assert!(!state.finish_refresh(first));
        assert!(state.expire_action(second));
        assert!(state.finish_refresh(second));
        assert!(!state.scanning && state.begin().is_none());
        assert!(!state.expire(first));
        assert!(state.expire(second));
        assert!(state.begin().is_some());
    }

    #[test]
    fn cooldown_and_action_expire_independently_while_refresh_is_held() {
        let mut state = State::default();
        let ticket = state.begin().unwrap();
        assert!(state.finish_scan(ticket, Ok(report())));
        assert!(state.expire_action(ticket));
        assert!(state.scanning && state.cooling_down && state.action.is_none());
        assert!(state.expire(ticket));
        assert!(state.scanning && !state.cooling_down && state.begin().is_none());
        assert!(state.finish_refresh(ticket));
        assert!(state.begin().is_some());
    }

    #[cfg(unix)]
    #[test]
    fn scan_uses_the_host_protocol_and_requires_the_complete_report() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        for valid in [true, false] {
            let dir = tempfile::tempdir().unwrap();
            let socket = dir.path().join("host.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let worker = std::thread::spawn(move || {
                drop(listener.accept().unwrap());
                for (method, result) in [
                    ("protocol", serde_json::json!({"protocolVersion":"53"})),
                    (
                        "scan",
                        if valid {
                            serde_json::json!({"filesFound":2,"filesRead":1,"rowsSeen":3,"eventsNew":2,"eventsRecovered":0,"daysRecovered":0,"elapsedMs":10,"warnings":[]})
                        } else {
                            serde_json::json!({"eventsNew":2})
                        },
                    ),
                ] {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["method"], method);
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        serde_json::json!({"id":request["id"],"ok":true,"result":result})
                    )
                    .unwrap();
                }
            });
            let result = crate::client::Client {
                socket,
                allow_spawn: false,
            }
            .scan();
            assert_eq!(result.is_ok(), valid);
            worker.join().unwrap();
        }
    }
}
