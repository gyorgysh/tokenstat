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
        } else {
            println!("{}", tokenstat_host::server::respond(&line, &session));
        }
        io::stdout().flush()?;
    }
    Ok(())
}
