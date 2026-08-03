//! Method dispatch. Pure safe Rust, so it is testable without a pointer.
//!
//! Every method takes one JSON object and returns one JSON envelope:
//!
//! ```json
//! {"ok": true, "result": ...}
//! {"ok": false, "error": {"code": "...", "message": "..."}}
//! ```
//!
//! A front end therefore has exactly one decoding path and one error path, no
//! matter which method it called. The envelope is also what the host daemon
//! will return, so this decoding path is written once and reused.

use std::sync::{Mutex, OnceLock, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};
use tokenstat_core::{Engine, GroupBy, PriceTable, Query};

use crate::PROTOCOL_VERSION;
use crate::dto::{
    AccountDto, BlockDto, BucketDto, DeviceLoginDto, DevicePollDto, GroupByDto, InfoDto,
    MachineDto, QueryDto, ScanReportDto, SyncResultDto, TotalsDto,
};

/// Process-wide handle.
///
/// Opening the archive means opening SQLite and resolving the timezone, which
/// is far too expensive to repeat per call from a UI that reports on scroll.
/// The price book is cached alongside it for the same reason: the interactive
/// CLI was re-reading it every frame before that was fixed, and a GUI would
/// make the same mistake more often.
struct Bridge {
    engine: Engine,
    prices: PriceTable,
    /// Device authorization awaiting confirmation.
    ///
    /// Kept here rather than handed to the front end because it carries the
    /// secret half of the grant. The app shows a short user code and polls,
    /// and never holds the device code at all.
    pending_login: Option<tokenstat_sync::DeviceLogin>,
}

static BRIDGE: OnceLock<Mutex<Option<Bridge>>> = OnceLock::new();

fn cell() -> &'static Mutex<Option<Bridge>> {
    BRIDGE.get_or_init(|| Mutex::new(None))
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct OpenParams {
    /// Override the archive location. Omit for the platform default.
    db_path: Option<String>,
    /// IANA name. Omit for the system zone.
    timezone: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReportParams {
    group: GroupByDto,
    #[serde(default)]
    query: QueryDto,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct QueryParams {
    query: QueryDto,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct SyncParams {
    /// Build and validate the payload without sending it.
    dry_run: bool,
    /// Ask the server to drop rows outside the window.
    prune: bool,
    /// Window expression, for example `30d`. Server default when absent.
    window: Option<String>,
}

fn ok(result: Value) -> String {
    json!({"ok": true, "result": result}).to_string()
}

fn err(code: &str, message: impl std::fmt::Display) -> String {
    json!({
        "ok": false,
        "error": {"code": code, "message": message.to_string()}
    })
    .to_string()
}

fn parse<T: for<'de> Deserialize<'de> + Default>(params: &str) -> Result<T, String> {
    let trimmed = params.trim();
    if trimmed.is_empty() || trimmed == "null" {
        return Ok(T::default());
    }
    serde_json::from_str(trimmed).map_err(|e| e.to_string())
}

/// Ensure the archive is open, using defaults if `open` was never called.
///
/// Lazy rather than required, so a front end that only wants one number does
/// not have to sequence a handshake first.
fn with_bridge<T>(f: impl FnOnce(&mut Bridge) -> Result<T, String>) -> Result<T, String> {
    let mut guard = cell().lock().unwrap_or_else(PoisonError::into_inner);
    if guard.is_none() {
        *guard = Some(open_bridge(&OpenParams::default())?);
    }
    let bridge = guard.as_mut().ok_or("archive is not open")?;
    f(bridge)
}

fn open_bridge(p: &OpenParams) -> Result<Bridge, String> {
    let path = p.db_path.as_ref().map(std::path::PathBuf::from);
    let engine = Engine::open(path.as_deref(), p.timezone.as_deref()).map_err(|e| e.to_string())?;
    Ok(Bridge {
        engine,
        prices: PriceTable::load_with_catalog(),
        pending_login: None,
    })
}

/// Handle one call. Never panics on bad input, and never returns a non-JSON
/// string, so the caller can decode unconditionally.
pub fn call(method: &str, params: &str) -> String {
    match dispatch(method, params) {
        Ok(v) => ok(v),
        Err(e) => err("call_failed", e),
    }
}

fn dispatch(method: &str, params: &str) -> Result<Value, String> {
    match method {
        // Re-open against a different archive or timezone. Also the hook a
        // future remote transport uses to point at another machine.
        "open" => {
            let p: OpenParams = parse(params)?;
            let bridge = open_bridge(&p)?;
            let mut guard = cell().lock().unwrap_or_else(PoisonError::into_inner);
            *guard = Some(bridge);
            Ok(json!({"opened": true}))
        }

        "info" => with_bridge(|b| {
            let info = InfoDto {
                protocol_version: PROTOCOL_VERSION.to_string(),
                core_version: tokenstat_core::VERSION.to_string(),
                db_path: b.engine.db_path().display().to_string(),
                timezone: b
                    .engine
                    .timezone()
                    .iana_name()
                    .unwrap_or("unknown")
                    .to_string(),
                price_book_effective_from: b.prices.effective_from.clone(),
                has_prices: !b.prices.is_empty(),
            };
            serde_json::to_value(info).map_err(|e| e.to_string())
        }),

        "totals" => {
            let p: QueryParams = parse(params)?;
            with_bridge(|b| {
                let t = b
                    .engine
                    .totals(&Query::from(p.query))
                    .map_err(|e| e.to_string())?;
                serde_json::to_value(TotalsDto::from(t)).map_err(|e| e.to_string())
            })
        }

        "report" => {
            let p: ReportParams = serde_json::from_str(params.trim()).map_err(|e| e.to_string())?;
            let group = GroupBy::from(p.group);
            with_bridge(|b| {
                let rows = b
                    .engine
                    .priced_report(group, &Query::from(p.query), &b.prices)
                    .map_err(|e| e.to_string())?;
                let dtos: Vec<BucketDto> = rows.into_iter().map(BucketDto::from).collect();
                serde_json::to_value(dtos).map_err(|e| e.to_string())
            })
        }

        "blocks" => {
            let p: QueryParams = parse(params)?;
            with_bridge(|b| {
                let rows = b
                    .engine
                    .blocks(&Query::from(p.query))
                    .map_err(|e| e.to_string())?;
                let dtos: Vec<BlockDto> = rows.into_iter().map(BlockDto::from).collect();
                serde_json::to_value(dtos).map_err(|e| e.to_string())
            })
        }

        // Long running. The caller must not run this on a UI thread.
        "scan" => with_bridge(|b| {
            let r = b.engine.scan().map_err(|e| e.to_string())?;
            serde_json::to_value(ScanReportDto::from(r)).map_err(|e| e.to_string())
        }),

        // Signed out is a state, not a failure. The bridge reports
        // `signedIn: false` so the app can offer sign-in, and reserves the
        // error path for a host that is unreachable or a token that was
        // revoked, which need different words.
        "account.status" => {
            let host =
                tokenstat_sync::profile::resolve_api_host(None).map_err(|e| e.to_string())?;
            match tokenstat_sync::sync_status(None) {
                Ok(s) => serde_json::to_value(AccountDto {
                    signed_in: true,
                    host: s.host,
                    handle: s.handle,
                    tier: s.tier,
                    last_sync_at: s.last_sync_at,
                    machines: s.machines.iter().map(MachineDto::from_value).collect(),
                    schema_current: s.schema_current,
                })
                .map_err(|e| e.to_string()),
                Err(e) if e.is_unauthenticated() => serde_json::to_value(AccountDto {
                    signed_in: false,
                    host,
                    handle: None,
                    tier: None,
                    last_sync_at: None,
                    machines: Vec::new(),
                    schema_current: None,
                })
                .map_err(|e| e.to_string()),
                Err(e) => Err(e.to_string()),
            }
        }

        // Begin a device authorization. Returns the code to show and the URL to
        // open. Opening the browser is the front end's job: this crate has no
        // business deciding how a window behaves.
        "account.deviceStart" => {
            let device = tokenstat_sync::device_start(None).map_err(|e| e.to_string())?;
            let dto = DeviceLoginDto::from(&device);
            with_bridge(|b| {
                b.pending_login = Some(device);
                Ok(())
            })?;
            serde_json::to_value(dto).map_err(|e| e.to_string())
        }

        // Poll once. Never sleeps, so the caller controls the cadence and can
        // cancel. On confirmation the token lands in the keychain, the same
        // entry the CLI reads.
        "account.devicePoll" => {
            let pending = with_bridge(|b| {
                b.pending_login
                    .clone()
                    .ok_or_else(|| "no sign-in is in progress".to_string())
            })?;
            match tokenstat_sync::device_poll(&pending).map_err(|e| e.to_string())? {
                tokenstat_sync::DeviceStatus::Pending { interval } => {
                    serde_json::to_value(DevicePollDto {
                        state: "pending",
                        interval: Some(interval),
                        handle: None,
                        host: None,
                        machine: None,
                    })
                    .map_err(|e| e.to_string())
                }
                tokenstat_sync::DeviceStatus::Confirmed(result) => {
                    with_bridge(|b| {
                        b.pending_login = None;
                        Ok(())
                    })?;
                    serde_json::to_value(DevicePollDto {
                        state: "confirmed",
                        interval: None,
                        handle: Some(result.handle),
                        host: Some(result.host),
                        machine: Some(result.machine),
                    })
                    .map_err(|e| e.to_string())
                }
            }
        }

        "account.cancelLogin" => {
            with_bridge(|b| {
                b.pending_login = None;
                Ok(())
            })?;
            Ok(json!({"cancelled": true}))
        }

        "account.logout" => {
            let host = tokenstat_sync::logout(None).map_err(|e| e.to_string())?;
            with_bridge(|b| {
                b.pending_login = None;
                Ok(())
            })?;
            Ok(json!({"host": host}))
        }

        // Long running and it talks to the network. Same rule as `scan`: not
        // from a thread that draws.
        "sync.run" => {
            let p: SyncParams = parse(params)?;
            with_bridge(|b| {
                let tz = b.engine.timezone().iana_name().map(str::to_string);
                let r = tokenstat_sync::sync(
                    b.engine.store(),
                    tokenstat_sync::SyncOptions {
                        host_flag: None,
                        prune: p.prune,
                        window: p.window.as_deref(),
                        dry_run: p.dry_run,
                        tz_name: tz.as_deref(),
                    },
                )
                .map_err(|e| e.to_string())?;
                serde_json::to_value(SyncResultDto {
                    host: r.host,
                    rows: r.rows,
                    dry_run: r.dry_run,
                    schema_v: r.schema_v,
                    from: r.window.from,
                    to: r.window.to,
                })
                .map_err(|e| e.to_string())
            })
        }

        other => Err(format!("unknown method: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// The bridge is one archive per process by design, so tests that open it
    /// cannot run concurrently with each other. Cargo runs them on threads, so
    /// they take this first.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// A clock alone is not unique enough: two threads entering within the same
    /// tick would build the same path and fight over one SQLite file.
    static SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!(
            "tokenstat-ffi-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("tokenstat.db").display().to_string()
    }

    fn open_temp() {
        let out = call(
            "open",
            &json!({"dbPath": temp_db(), "timezone": "UTC"}).to_string(),
        );
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["ok"], true, "open failed: {out}");
    }

    #[test]
    fn every_response_is_a_decodable_envelope() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        // Including the failure paths: a front end must never have to guess
        // whether it got JSON back.
        for (method, params) in [
            ("info", "{}"),
            ("nonsense", "{}"),
            ("totals", "not json at all"),
            ("report", "{}"),
        ] {
            let out = call(method, params);
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method} lacks ok: {out}");
            if v["ok"] == false {
                assert!(v["error"]["message"].is_string(), "{method}: {out}");
            }
        }
    }

    #[test]
    fn info_reports_the_protocol_version() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        let v: Value = serde_json::from_str(&call("info", "{}")).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["result"]["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(v["result"]["timezone"], "UTC");
    }

    #[test]
    fn an_empty_archive_reports_zero_rather_than_failing() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        let v: Value = serde_json::from_str(&call("totals", "{}")).unwrap();
        assert_eq!(v["ok"], true, "{v}");
        assert_eq!(v["result"]["events"], 0);
        // Unknown, not zero: an empty archive has no first date to report.
        assert!(v["result"]["firstDate"].is_null());
    }

    #[test]
    fn missing_params_are_treated_as_defaults() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        for params in ["", "null", "{}"] {
            let v: Value = serde_json::from_str(&call("totals", params)).unwrap();
            assert_eq!(v["ok"], true, "params {params:?} rejected: {v}");
        }
    }

    #[test]
    fn report_requires_a_group_and_says_so() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        let v: Value = serde_json::from_str(&call("report", "{}")).unwrap();
        assert_eq!(v["ok"], false);
        assert!(v["error"]["message"].as_str().unwrap().contains("group"));
    }

    #[test]
    fn account_methods_answer_without_a_network() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        // No server is reachable in a test run, so these must fail as an
        // envelope rather than hang or panic. The point is the contract, not
        // the verdict: a caller always gets decodable JSON back.
        for method in [
            "account.status",
            "account.deviceStart",
            "account.devicePoll",
        ] {
            let out = call(method, "{}");
            let v: Value = serde_json::from_str(&out)
                .unwrap_or_else(|e| panic!("{method} returned non-JSON: {out} ({e})"));
            assert!(v["ok"].is_boolean(), "{method}: {out}");
        }
    }

    #[test]
    fn polling_without_a_started_login_says_so() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        let v: Value = serde_json::from_str(&call("account.devicePoll", "{}")).unwrap();
        assert_eq!(v["ok"], false);
        assert!(
            v["error"]["message"]
                .as_str()
                .unwrap()
                .contains("no sign-in is in progress"),
            "{v}"
        );
    }

    #[test]
    fn cancelling_a_login_is_safe_when_none_is_pending() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        let v: Value = serde_json::from_str(&call("account.cancelLogin", "{}")).unwrap();
        assert_eq!(v["ok"], true, "{v}");
    }

    #[test]
    fn report_accepts_every_grouping() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        open_temp();
        for group in ["day", "week", "model", "project", "source", "session"] {
            let out = call("report", &json!({"group": group}).to_string());
            let v: Value = serde_json::from_str(&out).unwrap();
            assert_eq!(v["ok"], true, "group {group} failed: {out}");
            assert!(v["result"].is_array());
        }
    }
}
