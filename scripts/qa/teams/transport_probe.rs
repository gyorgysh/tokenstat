// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Disposable subprocess used by the website's cross-repository transport test.
//! Its stdin is private to the runner; credentials never enter argv or output.

use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
};

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
    println!("{}", json!({"ready":true,"key":key,"machine":machine}));
    io::stdout().flush()?;
    for line in io::stdin().lock().lines() {
        let line = line?;
        let input: Value = serde_json::from_str(&line)?;
        if input["method"] == "fixture.login" {
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
