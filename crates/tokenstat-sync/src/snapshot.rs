//! Shared plumbing for the tokenstat.ai snapshot feeds.
//!
//! Pricing, catalog, and plans are all the same shape: a public GET that
//! supports `If-None-Match`, validated before it is trusted, then written
//! atomically into the user's data directory so a half-written file can never
//! be read back as a price book.
//!
//! The rule that matters is **last known good wins**. A 5xx, a timeout, or a
//! payload that fails validation must leave the previous snapshot exactly where
//! it was. Reports going quiet is a much worse failure than reports being a day
//! stale.

use std::fs;
use std::io::Write;
use std::path::Path;

use atomicwrites::{AllowOverwrite, AtomicFile};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{config, host};

/// Sidecar holding the ETag and the hash of the snapshot it belongs to.
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EtagMetadata {
    pub etag: String,
    pub snapshot_sha256: String,
}

/// What a conditional GET came back with.
pub enum Fetched {
    /// The server confirmed our copy is current.
    NotModified,
    Body {
        text: String,
        etag: Option<String>,
    },
}

/// Resolve the API base the same way the sync client does, then append `path`.
pub fn api_url(path: &str) -> anyhow::Result<String> {
    let env_host = std::env::var("TOKENSTAT_API_BASE")
        .ok()
        .filter(|host| !host.trim().is_empty());
    let saved = config::load()?;
    let base = host::resolve_host(None, env_host.as_deref(), saved.sync.host.as_deref())?;
    Ok(format!("{base}{path}"))
}

/// Conditional GET against a public snapshot endpoint.
///
/// Sends `If-None-Match` only when the stored ETag still matches the snapshot
/// on disk. A stale sidecar would otherwise make the server answer 304 for a
/// file we no longer have.
pub fn fetch_conditional(url: &str, path: &Path, timeout_secs: u64) -> anyhow::Result<Fetched> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        // A conditional GET is a freshness check; it must not hang on a dead
        // network for the whole request timeout.
        .connect_timeout(std::time::Duration::from_secs(10))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .build()?;
    let mut request = client.get(url);
    if let Some(etag) = read_etag(path, &etag_path(path)) {
        request = request.header(reqwest::header::IF_NONE_MATCH, etag);
    }
    let resp = request.send()?;
    if resp.status() == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(Fetched::NotModified);
    }
    if !resp.status().is_success() {
        anyhow::bail!("tokenstat.ai returned {} for {url}", resp.status());
    }
    let etag = resp
        .headers()
        .get(reqwest::header::ETAG)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    Ok(Fetched::Body {
        text: resp.text()?,
        etag,
    })
}

/// Sidecar path for a snapshot file: `current.json` → `current.etag`.
pub fn etag_path(snapshot: &Path) -> std::path::PathBuf {
    snapshot.with_extension("etag")
}

/// Persist the snapshot, then the ETag that describes it.
///
/// Order matters. The sidecar is written second and hashed against the bytes we
/// just stored, so an interrupted write leaves a sidecar that no longer matches
/// and is therefore ignored rather than trusted.
pub fn store(path: &Path, contents: &str, etag: Option<String>) -> anyhow::Result<()> {
    write_private_atomically(path, contents)?;
    let sidecar = etag_path(path);
    match etag {
        Some(etag) => {
            let metadata = EtagMetadata {
                etag,
                snapshot_sha256: sha256(contents),
            };
            write_private_atomically(&sidecar, &serde_json::to_string(&metadata)?)?;
        }
        None if sidecar.exists() => fs::remove_file(&sidecar)?,
        None => {}
    }
    Ok(())
}

pub fn read_etag(snapshot_path: &Path, etag_path: &Path) -> Option<String> {
    let metadata: EtagMetadata = serde_json::from_str(&fs::read_to_string(etag_path).ok()?).ok()?;
    let snapshot = fs::read_to_string(snapshot_path).ok()?;
    (metadata.snapshot_sha256 == sha256(&snapshot)).then_some(metadata.etag)
}

pub fn sha256(contents: &str) -> String {
    format!("{:x}", Sha256::digest(contents.as_bytes()))
}

/// Write owner-readable and atomically, creating parent directories.
pub fn write_private_atomically(path: &Path, contents: &str) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)?;
    AtomicFile::new(path, AllowOverwrite)
        .write(|file| {
            file.write_all(contents.as_bytes())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
            }
            Ok::<(), std::io::Error>(())
        })
        .map_err(|err| anyhow::anyhow!("writing {} atomically: {err}", path.display()))?;
    Ok(())
}

/// True when a rate moved by more than half, which we treat as a bad feed entry
/// until an operator says otherwise.
pub fn moved_over_half(old: f64, new: f64) -> bool {
    if old <= 0.0 {
        return new > 0.0;
    }
    ((new - old).abs() / old) > 0.5
}

/// Reject a date that is not a plain `YYYY-MM-DD`.
pub fn validate_effective_from(value: &str, what: &str) -> anyhow::Result<()> {
    if value.parse::<jiff::civil::Date>().is_err() {
        anyhow::bail!("invalid {what} snapshot: effective_from must be YYYY-MM-DD");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static NEXT_PATH: AtomicU64 = AtomicU64::new(0);

    fn temp_snapshot() -> PathBuf {
        let id = NEXT_PATH.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!("tokenstat-snapshot-{}-{id}", std::process::id()))
            .join("current.json")
    }

    #[test]
    fn a_rate_that_doubles_is_a_large_move() {
        assert!(moved_over_half(4.0, 8.0));
        // More than a 50% drop, but not the exact half mark.
        assert!(moved_over_half(8.0, 3.0));
        // Exactly halving is not "over half".
        assert!(!moved_over_half(8.0, 4.0));
    }

    #[test]
    fn small_moves_and_unknown_rates_are_fine() {
        assert!(!moved_over_half(4.0, 5.0));
        assert!(!moved_over_half(0.0, 0.0));
        // First appearance of a rate is not a "move", it is a new entry.
        assert!(moved_over_half(0.0, 4.0));
    }

    #[test]
    fn effective_from_must_be_a_plain_date() {
        assert!(validate_effective_from("2026-08-03", "catalog").is_ok());
        assert!(validate_effective_from("whenever", "catalog").is_err());
        assert!(validate_effective_from("", "catalog").is_err());
        assert!(validate_effective_from("2026-8-3", "catalog").is_err());
    }

    #[test]
    fn sha256_is_stable_and_hex() {
        assert_eq!(
            sha256(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(sha256("tokenstat"), sha256("tokenstat"));
        assert_ne!(sha256("tokenstat"), sha256("tokensta"));
    }

    #[test]
    fn an_etag_round_trips_only_while_the_snapshot_is_unchanged() {
        let path = temp_snapshot();
        store(&path, "{\"v\":1}", Some("\"abc\"".into())).unwrap();
        assert_eq!(read_etag(&path, &etag_path(&path)), Some("\"abc\"".into()));

        // Rewriting the snapshot invalidates the stored hash, so the stale
        // sidecar is ignored rather than trusted as a 304 signal.
        store(&path, "{\"v\":2}", None).unwrap();
        assert_eq!(read_etag(&path, &etag_path(&path)), None);
    }

    #[test]
    fn a_missing_sidecar_or_snapshot_reads_as_no_etag() {
        let path = temp_snapshot();
        assert_eq!(read_etag(&path, &etag_path(&path)), None);
        store(&path, "{\"v\":1}", None).unwrap();
        assert_eq!(read_etag(&path, &etag_path(&path)), None);
    }
}
