// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Disposable subprocess used by the website's cross-repository transport test.
//! Its stdin is private to the runner; credentials never enter argv or output.

use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
};
use tokenstat_sync::teams::{HostRunAuthority, TeamClient, TeamError};

// Test-only, private stdin, marker-guarded loopback process. Production Team
// RPC never accepts arbitrary initiator tickets or exposes host control.
fn run_fixture(
    method: &str,
    params: &Value,
    runs: &mut HashMap<String, HostRunAuthority>,
) -> Result<Value, TeamError> {
    let text = |key: &str| params[key].as_str().ok_or(TeamError::InvalidRequest);
    let id = text("id")?;
    if method == "fixture.run.admit" {
        if runs.contains_key(id) || runs.len() >= 16 {
            return Err(TeamError::InvalidRequest);
        }
        let client = TeamClient::capture()?;
        let keys = client.verification_keys()?;
        let ticket: tokenstat_identity::teams::TeamTicket =
            serde_json::from_value(params["ticket"].clone())
                .map_err(|_| TeamError::InvalidRequest)?;
        let device = tokenstat_identity::public_key_from_hex(text("deviceKey")?)
            .map_err(|_| TeamError::InvalidRequest)?;
        let host = tokenstat_identity::MachineIdentity::load_or_create()
            .map_err(|_| TeamError::InvalidRequest)?
            .public_key();
        let actor = keys
            .verify(
                &ticket,
                &tokenstat_identity::teams::TeamTicketBinding {
                    device_key: &device,
                    host_key: &host,
                    publisher_id: text("publisher")?,
                    actor_id: Some(text("actor")?),
                },
                jiff::Timestamp::now()
                    .as_second()
                    .try_into()
                    .map_err(|_| TeamError::InvalidRequest)?,
            )
            .map_err(|_| TeamError::InvalidRequest)?;
        let authority = client.admit_host_run_authority(id, &actor)?;
        runs.insert(id.to_owned(), authority);
    } else {
        let authority = runs.get_mut(id).ok_or(TeamError::InvalidRequest)?;
        match method {
            "fixture.run.renew" => authority.renew()?,
            "fixture.run.ensure" => authority.ensure_live()?,
            "fixture.run.retire" => {
                authority.retire()?;
                return Ok(json!({"retired":true}));
            }
            _ => return Err(TeamError::InvalidRequest),
        }
    }
    let claims = runs
        .get(id)
        .ok_or(TeamError::InvalidResponse)?
        .lease()
        .claims();
    Ok(
        json!({"id":claims.run,"revision":claims.revision,"actor":claims.sub,"device":claims.device,"grant":claims.grant}),
    )
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let data = PathBuf::from(std::env::var("TOKENSTAT_DATA_DIR")?);
    let identity = PathBuf::from(std::env::var("TOKENSTAT_IDENTITY_DIR")?);
    if !data.join(".teams-transport-fixture").is_file()
        || !identity.join(".teams-transport-fixture").is_file()
    {
        return Err("This probe requires disposable fixture directories.".into());
    }
    let origin = std::env::var("TOKENSTAT_API_BASE")?;
    let relay = std::env::var("TOKENSTAT_TEAM_TEST_RELAY")?;
    for (raw, scheme) in [(&origin, "http"), (&relay, "ws")] {
        let url = reqwest::Url::parse(raw)?;
        if url.scheme() != scheme
            || url.host_str() != Some("127.0.0.1")
            || url.port().is_none()
            || url.path() != "/"
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("The transport fixture accepts only explicit loopback endpoints.".into());
        }
    }
    std::fs::write(
        identity.join("remote.json"),
        serde_json::to_vec(&json!({"tunnel":false,"tunnel_endpoint":relay}))?,
    )?;
    let key = tokenstat_identity::MachineIdentity::load_or_create()?.public_key_hex();
    let machine = tokenstat_sync::config::ensure_machine_id()?;
    let session = Arc::new(Mutex::new(tokenstat_host::Session::open_default()?));
    tokenstat_host::remote::register_session(session.clone());
    tokenstat_host::install_team_sync();
    println!("{}", json!({"ready":true,"key":key,"machine":machine}));
    io::stdout().flush()?;
    let mut runs = HashMap::new();
    for line in io::stdin().lock().lines() {
        let line = line?;
        let input: Value = serde_json::from_str(&line)?;
        if input["method"]
            .as_str()
            .is_some_and(|method| method.starts_with("fixture.run."))
        {
            let result = run_fixture(
                input["method"].as_str().unwrap_or_default(),
                &input["params"],
                &mut runs,
            );
            let reply = match result {
                Ok(value) => json!({"id":input["id"],"ok":true,"result":value}),
                Err(error) => {
                    let code = match error {
                        TeamError::Rejected { code, .. } => code,
                        TeamError::AccountChanged => "account_changed".into(),
                        TeamError::Network => "network".into(),
                        _ => "fixture_run_refused".into(),
                    };
                    json!({"id":input["id"],"ok":false,"error":{"code":code}})
                }
            };
            println!("{reply}");
        } else if input["method"] == "fixture.guardian.authentication" {
            let client = tokenstat_sync::vault::VaultClient::capture()?;
            println!(
                "{}",
                json!({"id":input["id"],"ok":true,"result":{"hostAuthentication":client.authentication_id()}})
            );
        } else if input["method"] == "fixture.login" {
            let bearer = input["params"]["bearer"]
                .as_str()
                .ok_or("Missing fixture credential")?;
            tokenstat_sync::keychain::store_token(&origin, bearer)?;
            tokenstat_sync::config::set_sync_host(&origin)?;
            println!("{}", json!({"id":input["id"],"ok":true,"result":{}}));
        } else if input["method"] == "fixture.seedHistory" {
            let id = input["params"]["conversation"]
                .as_str()
                .filter(|id| {
                    !id.is_empty()
                        && id.len() <= 128
                        && id
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                })
                .ok_or("Invalid fixture chat reference")?;
            let directory = data.join("chat").join(id);
            std::fs::create_dir_all(&directory)?;
            let events = input["params"]["events"]
                .as_array()
                .ok_or("Missing fixture events")?;
            let history = events
                .iter()
                .map(|row| row.to_string() + "\n")
                .collect::<String>();
            if history.len() > 4 * 1024 * 1024 {
                return Err("Fixture history is too large".into());
            }
            std::fs::write(directory.join("events.ndjson"), history)?;
            // Optional chat files, stored where chat attachments live.
            if let Some(files) = input["params"]["files"].as_object() {
                for (file, body) in files {
                    let name = body["name"].as_str().ok_or("Missing fixture file name")?;
                    let text = body["text"].as_str().ok_or("Missing fixture file text")?;
                    if [file.as_str(), name].iter().any(|part| {
                        part.is_empty()
                            || !part.bytes().all(|b| {
                                b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.')
                            })
                            || part.starts_with('.')
                    }) {
                        return Err("Invalid fixture file".into());
                    }
                    let folder = directory.join("files").join(file);
                    std::fs::create_dir_all(&folder)?;
                    std::fs::write(folder.join(name), text)?;
                }
            }
            let path = data.join("chat/conversations.json");
            let mut index: Value = serde_json::from_slice(&std::fs::read(&path)?)?;
            let chat = index["conversations"]
                .as_array_mut()
                .ok_or("Missing fixture chat index")?
                .iter_mut()
                .find(|row| row["id"] == id)
                .ok_or("Missing fixture chat")?;
            chat["resumeToken"] = json!("PRIVATE_FIXTURE_CONTINUATION");
            chat["resumeTokens"] = json!({"codex":"PRIVATE_FIXTURE_CONTINUATION"});
            chat["systemPrompt"] = json!("PRIVATE_FIXTURE_SYSTEM_SETUP");
            std::fs::write(path, serde_json::to_vec(&index)?)?;
            println!("{}", json!({"id":input["id"],"ok":true,"result":{}}));
        } else {
            println!("{}", tokenstat_host::server::respond(&line, &session));
        }
        io::stdout().flush()?;
    }
    Ok(())
}
