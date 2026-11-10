// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Wire presentation records. The daemon remains the owner of account and folder state.

use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub signed_in: bool,
    pub host: String,
    pub handle: Option<String>,
    pub account_id: Option<String>,
    pub account_session: Option<String>,
    pub display_name: Option<String>,
    pub tier: Option<String>,
    pub avatar: Option<String>,
    pub machines: Vec<crate::devices::Machine>,
}

impl Account {
    pub fn title(&self) -> Option<&str> {
        self.display_name
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .or(self.handle.as_deref())
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repository {
    pub id: String,
    pub name: String,
    pub path: String,
    pub exists: bool,
    pub git_status_pending: Option<bool>,
    #[serde(rename = "machineID")]
    pub machine_id: Option<String>,
    pub machine_label: Option<String>,
}

/// Each response keeps its own failure. A failed account read is never signed-out,
/// and a failed folder read is never an authoritative empty directory.
#[derive(Debug)]
pub struct DesktopData {
    pub account: Result<Account, String>,
    pub repositories: Result<Vec<Repository>, String>,
}

impl DesktopData {
    /// Keep the last reading after a failed refresh and return its error for
    /// a visible banner. An authoritative empty list replaces the old one.
    pub fn preserve_previous(&mut self, previous: Option<&Self>) -> Vec<String> {
        let mut errors = Vec::new();
        if let Err(error) = &self.account {
            errors.push(error.clone());
            if let Some(Ok(account)) = previous.map(|d| &d.account) {
                self.account = Ok(account.clone());
            }
        }
        if let Err(error) = &self.repositories {
            errors.push(error.clone());
            if let Some(Ok(repositories)) = previous.map(|d| &d.repositories) {
                self.repositories = Ok(repositories.clone());
            }
        }
        errors
    }

    /// Deliberately synthetic data for the isolated shell harness; no host/identity IO.
    pub fn fixture() -> Self {
        Self {
            account: Ok(Account {
                signed_in: false,
                host: "https://fixture.invalid".into(),
                handle: None,
                account_id: None,
                account_session: None,
                display_name: None,
                tier: None,
                avatar: None,
                machines: Vec::new(),
            }),
            repositories: Ok(vec![
                Repository {
                    id: "/fixture/alpha".into(),
                    name: "alpha".into(),
                    path: "/fixture/alpha".into(),
                    exists: true,
                    git_status_pending: Some(true),
                    machine_id: None,
                    machine_label: None,
                },
                Repository {
                    id: "/fixture/beta".into(),
                    name: "beta".into(),
                    path: "/fixture/beta".into(),
                    exists: false,
                    git_status_pending: None,
                    machine_id: None,
                    machine_label: None,
                },
            ]),
        }
    }
}

#[cfg(unix)]
impl crate::client::Client {
    /// Resolve only the local daemon's verified public identity, after the
    /// mandatory protocol check. Display names never substitute for a key.
    pub fn public_identity(&self) -> anyhow::Result<String> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Identity {
            key: String,
            fingerprint: String,
            label: String,
            words: Option<String>,
            label_is_chosen: Option<bool>,
        }
        self.prepare()?;
        let identity: Identity =
            serde_json::from_value(self.call("machine.identity", serde_json::json!({}))?)?;
        anyhow::ensure!(
            !identity.key.is_empty(),
            "The host returned an empty public identity"
        );
        let _ = (
            identity.fingerprint,
            identity.label,
            identity.words,
            identity.label_is_chosen,
        );
        Ok(identity.key)
    }
    /// Run on a worker. The mandatory handshake precedes every feature request.
    pub fn desktop_data(&self) -> anyhow::Result<DesktopData> {
        self.prepare()?;
        let read = |method, params| self.call(method, params).map_err(|e| format!("{e:#}"));
        let account = read("account.status", serde_json::json!({}))
            .and_then(|v| serde_json::from_value(v).map_err(|e| e.to_string()));
        let repositories = read("workspace.list", serde_json::json!({"includeGit": false}))
            .and_then(|v| serde_json::from_value(v).map_err(|e| e.to_string()));
        Ok(DesktopData {
            account,
            repositories,
        })
    }

    pub fn add_repository(&self, path: &std::path::Path) -> anyhow::Result<()> {
        self.prepare()?;
        self.call("workspace.add", serde_json::json!({"path": path}))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn public_identity_requires_protocol_and_the_source_wire_shape_without_guessing_a_name() {
        use serde_json::{Value, json};
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        for result in [
            json!({"key":"public-key","fingerprint":"fingerprint","label":"Display name"}),
            json!({"key":"","fingerprint":"fingerprint","label":"Display name"}),
            json!({"key":"missing-required-fields"}),
        ] {
            let root = tempfile::tempdir().unwrap();
            let socket = root.path().join("host.sock");
            let listener = UnixListener::bind(&socket).unwrap();
            let valid = result["key"] == "public-key";
            let thread = std::thread::spawn(move || {
                drop(listener.accept().unwrap());
                for (method, value) in [
                    ("protocol", json!({"protocolVersion":"53"})),
                    ("machine.identity", result),
                ] {
                    let (stream, _) = listener.accept().unwrap();
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    reader.read_line(&mut line).unwrap();
                    let request: Value = serde_json::from_str(&line).unwrap();
                    assert_eq!(request["method"], method);
                    writeln!(
                        reader.get_mut(),
                        "{}",
                        json!({"id":request["id"],"ok":true,"result":value})
                    )
                    .unwrap();
                }
            });
            let result = crate::client::Client {
                socket,
                allow_spawn: false,
            }
            .public_identity();
            if valid {
                assert_eq!(result.unwrap(), "public-key");
            } else {
                assert!(result.is_err());
            }
            thread.join().unwrap();
        }
    }

    #[test]
    fn unknown_directory_fields_do_not_turn_unread_git_into_clean_git() {
        let repo: Repository = serde_json::from_str(r#"{"id":"/fixture","path":"/fixture","name":"fixture","exists":false,"git":null,"gitStatusPending":true}"#).unwrap();
        assert!(!repo.exists);
        assert_eq!(repo.git_status_pending, Some(true));
        assert!(serde_json::from_str::<Account>(r#"{"error":"offline"}"#).is_err());
        assert!(serde_json::from_str::<Vec<Repository>>("null").is_err());
    }

    #[test]
    fn failed_fields_retain_their_last_reading_but_empty_is_authoritative() {
        let previous = DesktopData::fixture();
        let mut next = DesktopData {
            account: Err("account offline".into()),
            repositories: Ok(Vec::new()),
        };
        assert_eq!(
            next.preserve_previous(Some(&previous)),
            vec!["account offline"]
        );
        assert!(next.account.is_ok());
        assert_eq!(next.repositories.unwrap().len(), 0);
        let mut next = DesktopData {
            account: Err("offline".into()),
            repositories: Err("offline".into()),
        };
        assert_eq!(next.preserve_previous(None).len(), 2);
        assert!(next.account.is_err() && next.repositories.is_err());
    }

    #[cfg(unix)]
    #[test]
    fn protocol_precedes_independent_directory_and_account_reads() {
        use serde_json::{Value, json};
        use std::{
            io::{BufRead, BufReader, Write},
            os::unix::net::UnixListener,
        };
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("host.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let thread = std::thread::spawn(move || {
            drop(listener.accept().unwrap());
            for (method, response) in [
                (
                    "protocol",
                    json!({"ok":true,"result":{"protocolVersion":"53"}}),
                ),
                (
                    "account.status",
                    json!({"ok":false,"error":"fixture offline"}),
                ),
                ("workspace.list", json!({"ok":true,"result":[]})),
            ] {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                assert_eq!(request["method"], method);
                if method == "workspace.list" {
                    assert_eq!(request["params"]["includeGit"], false);
                }
                let mut response = response;
                response["id"] = request["id"].clone();
                writeln!(reader.get_mut(), "{response}").unwrap();
            }
        });
        let data = crate::client::Client {
            socket,
            allow_spawn: false,
        }
        .desktop_data()
        .unwrap();
        assert!(data.account.is_err());
        assert!(data.repositories.unwrap().is_empty());
        thread.join().unwrap();
    }
}
