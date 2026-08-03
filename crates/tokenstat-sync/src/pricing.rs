//! Refresh the tokenstat.ai list-rate snapshot into the local data directory.
//! Core only reads the resulting file, it never fetches.

use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use tokenstat_core::PriceTable;

use crate::snapshot::{self, Fetched, moved_over_half, validate_effective_from};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct OutModel {
    #[serde(rename = "match")]
    pattern: String,
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write_5m: f64,
    cache_write_1h: f64,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct OutSnapshot {
    effective_from: String,
    note: String,
    models: Vec<OutModel>,
}

#[derive(Debug)]
pub struct PricingRefresh {
    pub path: std::path::PathBuf,
    pub models: usize,
    pub effective_from: String,
    /// Patterns whose input or output rate moved more than 50% vs the prior
    /// local snapshot. Empty on a first fetch.
    pub large_moves: Vec<String>,
}

/// Download the hosted list-rate snapshot and write `pricing/current.json`.
///
/// When an existing snapshot is present, rates that jump more than 50% are
/// rejected unless `force` is true, so a bad feed entry cannot silently rewrite
/// every dollar column.
pub fn refresh(force: bool) -> anyhow::Result<PricingRefresh> {
    refresh_from_url(&pricing_url()?, force)
}

fn pricing_url() -> anyhow::Result<String> {
    snapshot::api_url("/api/v1/pricing/current")
}

fn refresh_from_url(url: &str, force: bool) -> anyhow::Result<PricingRefresh> {
    let path = PriceTable::default_path().map_err(|e| anyhow::anyhow!("{e}"))?;
    refresh_from_url_at(url, &path, force)
}

fn refresh_from_url_at(url: &str, path: &Path, force: bool) -> anyhow::Result<PricingRefresh> {
    let (body, etag) = match snapshot::fetch_conditional(url, path, 60)? {
        Fetched::NotModified => {
            if !path.exists() {
                anyhow::bail!("pricing API returned 304 but no local snapshot exists");
            }
            let snapshot = load_snapshot(path)?;
            return Ok(PricingRefresh {
                path: path.into(),
                models: snapshot.models.len(),
                effective_from: snapshot.effective_from,
                large_moves: Vec::new(),
            });
        }
        Fetched::Body { text, etag } => (text, etag),
    };
    let snapshot = parse_snapshot(&body)?;
    let large_moves = detect_large_moves(path, &snapshot);
    if !large_moves.is_empty() && !force {
        anyhow::bail!(
            "pricing snapshot moved >50% for {} model(s), e.g. {}. Re-run with --force to accept.",
            large_moves.len(),
            large_moves
                .iter()
                .take(5)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    let json = serde_json::to_string_pretty(&snapshot)?;
    snapshot::store(path, &json, etag)?;
    Ok(PricingRefresh {
        path: path.into(),
        models: snapshot.models.len(),
        effective_from: snapshot.effective_from,
        large_moves,
    })
}

fn load_snapshot(path: &Path) -> anyhow::Result<OutSnapshot> {
    let body = fs::read_to_string(path)?;
    parse_snapshot(&body)
}

fn parse_snapshot(body: &str) -> anyhow::Result<OutSnapshot> {
    let snapshot: OutSnapshot =
        serde_json::from_str(body).map_err(|e| anyhow::anyhow!("invalid pricing snapshot: {e}"))?;
    validate_effective_from(&snapshot.effective_from, "pricing")?;
    if snapshot.note.trim().is_empty() {
        anyhow::bail!("invalid pricing snapshot: note must not be empty");
    }
    if snapshot.models.is_empty() {
        anyhow::bail!("invalid pricing snapshot: models must not be empty");
    }
    let mut previous = "";
    for model in &snapshot.models {
        if model.pattern.trim().is_empty() {
            anyhow::bail!("invalid pricing snapshot: model match must not be empty");
        }
        if model.pattern.as_str() <= previous {
            anyhow::bail!("invalid pricing snapshot: models must be sorted and unique by match");
        }
        let rates = [
            model.input,
            model.output,
            model.cache_read,
            model.cache_write_5m,
            model.cache_write_1h,
        ];
        if rates.iter().any(|rate| !rate.is_finite() || *rate < 0.0) {
            anyhow::bail!("invalid pricing snapshot: model rates must be finite and non-negative");
        }
        previous = &model.pattern;
    }
    Ok(snapshot)
}

fn detect_large_moves(path: &Path, next: &OutSnapshot) -> Vec<String> {
    let Some(prev) = PriceTable::load_from(path) else {
        return Vec::new();
    };
    if prev.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for model in &next.models {
        let Some(old) = prev.get_exact(&model.pattern) else {
            continue;
        };
        if moved_over_half(old.input, model.input)
            || moved_over_half(old.output, model.output)
            || moved_over_half(old.cache_read, model.cache_read)
            || moved_over_half(old.cache_write_5m, model.cache_write_5m)
            || moved_over_half(old.cache_write_1h, model.cache_write_1h)
        {
            out.push(model.pattern.clone());
        }
    }
    out.sort();
    out
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    use super::*;
    use crate::snapshot::{
        EtagMetadata, etag_path, read_etag, sha256 as snapshot_sha256, write_private_atomically,
    };

    static NEXT_PATH: AtomicUsize = AtomicUsize::new(0);

    const SNAPSHOT: &str = r#"{
      "effective_from": "2026-08-01",
      "note": "List-rate snapshot generated by tokenstat.ai.",
      "models": [{
        "match": "example/model",
        "input": 3.0,
        "output": 15.0,
        "cache_read": 0.3,
        "cache_write_5m": 3.75,
        "cache_write_1h": 0.0
      }]
    }"#;

    fn temporary_snapshot_path() -> std::path::PathBuf {
        let id = NEXT_PATH.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!("tokenstat-pricing-{}-{id}", std::process::id()))
            .join("pricing")
            .join("current.json")
    }

    fn write_etag(path: &Path, etag: &str) {
        let snapshot = fs::read_to_string(path).unwrap();
        let metadata = EtagMetadata {
            etag: etag.into(),
            snapshot_sha256: snapshot_sha256(&snapshot),
        };
        write_private_atomically(&etag_path(path), &serde_json::to_string(&metadata).unwrap())
            .unwrap();
    }

    fn server(
        status: &str,
        headers: &[(&str, &str)],
        body: &str,
    ) -> (String, thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let status = status.to_string();
        let headers: Vec<(String, String)> = headers
            .iter()
            .map(|(name, value)| ((*name).into(), (*value).into()))
            .collect();
        let body = body.to_string();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                .unwrap();
            let mut request = Vec::new();
            loop {
                let mut chunk = [0; 512];
                let n = stream.read(&mut chunk).unwrap();
                request.extend_from_slice(&chunk[..n]);
                if request.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            let mut response = format!(
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n",
                body.len()
            );
            for (name, value) in headers {
                response.push_str(&format!("{name}: {value}\r\n"));
            }
            response.push_str("\r\n");
            response.push_str(&body);
            stream.write_all(response.as_bytes()).unwrap();
            String::from_utf8(request).unwrap()
        });
        (format!("http://{addr}/api/v1/pricing/current"), handle)
    }

    #[test]
    fn writes_a_valid_snapshot_and_etag_from_the_api() {
        let path = temporary_snapshot_path();
        let (url, request) = server("200 OK", &[("ETag", "\"v1\"")], SNAPSHOT);

        let refreshed = refresh_from_url_at(&url, &path, false).unwrap();

        assert_eq!(refreshed.models, 1);
        assert_eq!(
            read_etag(&path, &etag_path(&path)).as_deref(),
            Some("\"v1\"")
        );
        assert!(PriceTable::load_from(&path).is_some());
        assert!(
            request
                .join()
                .unwrap()
                .starts_with("GET /api/v1/pricing/current ")
        );
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn not_modified_keeps_the_existing_snapshot() {
        let path = temporary_snapshot_path();
        write_private_atomically(&path, SNAPSHOT).unwrap();
        write_etag(&path, "\"v1\"");
        let before = fs::read_to_string(&path).unwrap();
        let (url, request) = server("304 Not Modified", &[], "");

        let refreshed = refresh_from_url_at(&url, &path, false).unwrap();

        assert_eq!(refreshed.models, 1);
        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        assert!(request.join().unwrap().contains("if-none-match: \"v1\""));
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn mismatched_etag_metadata_is_not_sent() {
        let path = temporary_snapshot_path();
        write_private_atomically(&path, SNAPSHOT).unwrap();
        write_etag(&path, "\"v1\"");
        write_private_atomically(&path, SNAPSHOT.replace("3.0", "4.0").as_str()).unwrap();
        let (url, request) = server("200 OK", &[], SNAPSHOT);

        refresh_from_url_at(&url, &path, true).unwrap();

        assert!(!request.join().unwrap().contains("if-none-match:"));
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn response_without_etag_removes_prior_metadata() {
        let path = temporary_snapshot_path();
        write_private_atomically(&path, SNAPSHOT).unwrap();
        write_etag(&path, "\"v1\"");
        let (url, request) = server("200 OK", &[], SNAPSHOT);

        refresh_from_url_at(&url, &path, true).unwrap();

        assert!(!etag_path(&path).exists());
        request.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn invalid_response_does_not_replace_the_existing_snapshot() {
        let path = temporary_snapshot_path();
        write_private_atomically(&path, SNAPSHOT).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let (url, request) = server("200 OK", &[], "{\"models\":[]}");

        assert!(refresh_from_url_at(&url, &path, false).is_err());

        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        request.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn service_error_does_not_replace_the_existing_snapshot() {
        let path = temporary_snapshot_path();
        write_private_atomically(&path, SNAPSHOT).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let (url, request) = server("503 Service Unavailable", &[], "");

        assert!(refresh_from_url_at(&url, &path, false).is_err());

        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        request.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).unwrap();
    }

    #[test]
    fn flags_rates_that_move_over_half() {
        assert!(!moved_over_half(10.0, 14.0));
        assert!(moved_over_half(10.0, 16.0));
        assert!(moved_over_half(10.0, 4.0));
    }
}
