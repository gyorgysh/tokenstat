// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The explicit remote-vendor fetch action from InsightsModel. The shared host
//! owns credentials, network requests, vendor TTLs and archive writes.

use serde::Deserialize;

pub const COOLDOWN_SECONDS: u64 = 30 * 60;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub vendor: String,
    #[serde(deserialize_with = "crate::chat::wire::number::i64_required")]
    pub events: i64,
    pub from_cache: bool,
    pub skipped_no_token: bool,
    pub message: Option<String>,
}

#[derive(Default)]
pub struct State {
    pub fetching: bool,
    pub cooling_down: bool,
    pub error: Option<String>,
    pub action: Option<String>,
    ticket: u64,
    refreshing: bool,
}

impl State {
    pub fn begin(&mut self) -> Option<u64> {
        if self.fetching || self.cooling_down {
            return None;
        }
        self.ticket = self.ticket.wrapping_add(1);
        self.fetching = true;
        self.refreshing = false;
        self.action = None;
        Some(self.ticket)
    }

    /// Success starts the action and cooldown before the snapshot refresh.
    pub fn finish_fetch(&mut self, ticket: u64, result: Result<Vec<Report>, String>) -> bool {
        if !self.fetching || self.refreshing || ticket != self.ticket {
            return false;
        }
        match result {
            Ok(reports) => {
                self.refreshing = true;
                self.cooling_down = true;
                let details = reports
                    .iter()
                    .filter_map(|report| report.message.as_deref())
                    .collect::<Vec<_>>()
                    .join(" · ");
                self.action = Some(if details.is_empty() {
                    crate::localization::text(
                        "apple.insightsmodel.remote_fetch_complete.2bfec637",
                        &[],
                    )
                } else {
                    details
                });
                true
            }
            Err(error) => {
                self.fetching = false;
                self.error = Some(error);
                false
            }
        }
    }

    pub fn awaiting_refresh(&self, ticket: u64) -> bool {
        self.fetching && self.refreshing && self.ticket == ticket
    }
    pub fn finish_refresh(&mut self, ticket: u64) -> bool {
        if !self.awaiting_refresh(ticket) {
            return false;
        }
        self.fetching = false;
        self.refreshing = false;
        true
    }
    pub fn expire(&mut self, ticket: u64) -> bool {
        if self.ticket != ticket || !self.cooling_down {
            return false;
        }
        self.cooling_down = false;
        true
    }
}

#[cfg(unix)]
impl crate::client::Client {
    pub fn fetch_remotes(&self) -> anyhow::Result<Vec<Report>> {
        self.prepare()?;
        Ok(serde_json::from_value(self.call_with_timeout(
            "fetch",
            serde_json::json!({}),
            std::time::Duration::from_secs(600),
        )?)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn fetch_action_messages_and_held_refresh_follow_original_phases() {
        let mut state = State::default();
        let ticket = state.begin().unwrap();
        assert!(state.begin().is_none());
        let reports = serde_json::from_value(json!([
            {"vendor":"cursor","events":2,"fromCache":false,"skippedNoToken":false,"message":"one"},
            {"vendor":"other","events":0,"fromCache":true,"skippedNoToken":true,"message":null},
            {"vendor":"third","events":0,"fromCache":false,"skippedNoToken":false,"message":"two"}
        ]))
        .unwrap();
        assert!(state.finish_fetch(ticket, Ok(reports)));
        assert_eq!(state.action.as_deref(), Some("one · two"));
        assert!(state.fetching && state.cooling_down && state.begin().is_none());
        assert!(state.expire(ticket));
        assert!(state.fetching && state.begin().is_none());
        assert!(state.finish_refresh(ticket));
        let next = state.begin().unwrap();
        assert!(!state.expire(ticket));
        assert!(!state.finish_fetch(next, Err("offline".into())));
        assert_eq!(state.error.as_deref(), Some("offline"));
        assert!(!state.fetching && !state.cooling_down);
        let next = state.begin().unwrap();
        assert!(state.finish_fetch(next, Ok(vec![])));
        assert_eq!(
            state.action.as_deref(),
            Some(
                crate::localization::text(
                    "apple.insightsmodel.remote_fetch_complete.2bfec637",
                    &[]
                )
                .as_str()
            )
        );
    }

    #[cfg(unix)]
    #[test]
    fn transport_uses_local_fetch_envelope_and_rejects_incomplete_reports() {
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
                        "fetch",
                        if valid {
                            json!([{"vendor":"fixture","events":1,"fromCache":false,"skippedNoToken":false,"message":"fixture"}])
                        } else {
                            json!([{"vendor":"fixture"}])
                        },
                    ),
                ] {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["method"], method);
                    assert_eq!(request["params"], json!({}));
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":request["id"],"ok":true,"result":result})
                    )
                    .unwrap();
                }
            });
            let client = crate::client::Client {
                socket,
                allow_spawn: false,
            };
            assert_eq!(client.fetch_remotes().is_ok(), valid);
            worker.join().unwrap();
        }
    }
}
