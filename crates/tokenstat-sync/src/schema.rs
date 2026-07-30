//! Fetch and interpret `GET /api/v1/schema` version envelopes.

use std::thread;
use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::{SYNC_SCHEMA_VERSION, choose_schema_v};

use crate::profile::ProfileError;

#[derive(Debug, Clone, Deserialize)]
pub struct SchemaEnvelope {
    #[serde(default)]
    pub v: Option<u32>,
    pub min_v: u32,
    pub max_v: u32,
    #[serde(default)]
    pub sources: Vec<String>,
    #[serde(default)]
    pub confidence: Vec<String>,
}

impl SchemaEnvelope {
    /// Highest CLI-supported payload `v` still inside the server range.
    pub fn choose_payload_v(&self) -> Result<u32, ProfileError> {
        choose_schema_v(self.min_v, self.max_v).map_err(|e| {
            ProfileError::Message(format!(
                "unsupported_schema: CLI speaks v={SYNC_SCHEMA_VERSION}, \
                 server accepts [{}, {}]. {e}",
                self.min_v, self.max_v
            ))
        })
    }
}

/// Fetch the live schema envelope. Required before sync (and on login).
///
/// Transport blips retry the same way as the sync POST: up to four attempts
/// with a short backoff. HTTP error statuses and incoherent envelopes fail
/// immediately, those are not transient.
pub fn fetch_schema(
    client: &reqwest::blocking::Client,
    host: &str,
) -> Result<SchemaEnvelope, ProfileError> {
    let url = format!("{host}/api/v1/schema");
    let mut attempt = 0u32;
    let resp = loop {
        attempt += 1;
        match client.get(&url).send() {
            Ok(r) => break r,
            Err(_) if attempt < 4 => {
                thread::sleep(Duration::from_secs(u64::from(attempt)));
                continue;
            }
            Err(e) => {
                return Err(ProfileError::Message(format!("schema fetch failed: {e}")));
            }
        }
    };
    if !resp.status().is_success() {
        return Err(ProfileError::Message(format!(
            "schema fetch failed ({})",
            resp.status()
        )));
    }
    let env: SchemaEnvelope = resp.json()?;
    if env.min_v > env.max_v {
        return Err(ProfileError::Message(format!(
            "server schema envelope is incoherent: min_v={} max_v={}",
            env.min_v, env.max_v
        )));
    }
    Ok(env)
}

/// Best-effort schema fetch for dry-run when the host may be offline.
pub fn try_fetch_schema(client: &reqwest::blocking::Client, host: &str) -> Option<SchemaEnvelope> {
    fetch_schema(client, host).ok()
}
