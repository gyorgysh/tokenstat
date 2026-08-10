//! What Claude Code's own account says is left of the plan.
//!
//! Here rather than in `tokenstat-core` because it makes a request. Codex
//! writes its limits into its session log so core can read them off the disk;
//! Anthropic does not, so the numbers have to be asked for.
//!
//! **The token is the one Claude Code already stored on this machine.** It is
//! read, used against Anthropic's own API, and dropped. It is never written
//! into the archive, never included in a sync payload, and never sent anywhere
//! except to the vendor it belongs to. That is the same rule the Cursor and
//! Antigravity credential discovery follows and it is not negotiable.
//!
//! One exception, and the only one in this project: when the stored access
//! token has expired, it is renewed against Anthropic and the renewed login is
//! written back to the store it came from. See `refresh`. The credential still
//! goes nowhere but the vendor it belongs to.

use std::time::Duration;

use serde::Deserialize;
use tokenstat_core::limits::{LimitSeverity, ProviderLimits, UsageWindow};

/// Anthropic's OAuth API wants this on every call, and returns 401 without it.
const OAUTH_BETA: &str = "oauth-2025-04-20";
const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";

/// Where a refresh token is traded for a new access token.
const TOKEN_URL: &str = "https://platform.claude.com/v1/oauth/token";

/// Claude Code's own public OAuth client. Not a secret: it names the
/// application, and the refresh token is what proves who the person is.
const CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

#[derive(Debug, Deserialize)]
struct StoredCredentials {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<OauthToken>,
}

#[derive(Debug, Deserialize)]
struct OauthToken {
    #[serde(rename = "accessToken")]
    access_token: String,
    /// Unix milliseconds.
    #[serde(rename = "expiresAt", default)]
    expires_at: Option<i64>,
    /// What renews the access token once it has run out.
    #[serde(rename = "refreshToken", default)]
    refresh_token: Option<String>,
}

/// What the token endpoint answers with. `refresh_token` comes back when the
/// vendor rotates it, and must replace the one that was spent.
#[derive(Debug, Deserialize)]
struct RefreshedToken {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    /// Seconds from now.
    #[serde(default)]
    expires_in: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct UsageResponse {
    #[serde(default)]
    five_hour: Option<UsageWindowDto>,
    #[serde(default)]
    seven_day: Option<UsageWindowDto>,
}

#[derive(Debug, Deserialize)]
struct UsageWindowDto {
    /// Percent used, 0 to 100.
    #[serde(default)]
    utilization: Option<f64>,
    /// ISO 8601, and Anthropic writes microseconds with a `+00:00` offset
    /// rather than a `Z`, so this must not be parsed as RFC 3339 millis only.
    #[serde(default)]
    resets_at: Option<String>,
}

/// Read the limits for the Claude Code account signed in on this machine.
///
/// Never returns an error: a missing login, an expired token or an unreachable
/// API are all "we cannot say", and this ends up on a dashboard next to numbers
/// that are known. Saying so in words is the honest answer, and reporting zero
/// would be a lie about someone's remaining quota.
pub fn fetch() -> ProviderLimits {
    let stored = match stored_credentials() {
        Some(s) => s,
        None => {
            return ProviderLimits::unavailable(
                "claude_code",
                "Not signed in to Claude Code on this machine, so its limits cannot be read.",
            );
        }
    };
    let token = match stored.token() {
        Some(t) => t,
        None => {
            return ProviderLimits::unavailable(
                "claude_code",
                "The stored Claude Code credentials hold no login.",
            );
        }
    };

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    {
        Ok(c) => c,
        Err(e) => return ProviderLimits::unavailable("claude_code", e.to_string()),
    };

    let access_token = if token
        .expires_at
        .is_some_and(|ms| ms <= now_ms().saturating_add(60_000))
    {
        match refresh(&client, &stored, &token) {
            Ok(fresh) => fresh,
            Err(note) => return ProviderLimits::unavailable("claude_code", note),
        }
    } else {
        token.access_token.clone()
    };

    let response = client
        .get(USAGE_URL)
        .bearer_auth(&access_token)
        .header("anthropic-beta", OAUTH_BETA)
        .header("content-type", "application/json")
        .send();

    let response = match response {
        Ok(r) => r,
        Err(e) => {
            return ProviderLimits::unavailable(
                "claude_code",
                format!("Could not reach Anthropic: {e}"),
            );
        }
    };

    if !response.status().is_success() {
        let status = response.status();
        let hint = if status == reqwest::StatusCode::UNAUTHORIZED {
            "The stored Claude Code login was refused. Run any `claude` command to refresh it."
                .to_string()
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            "Anthropic is rate limiting the usage endpoint. Try again shortly.".to_string()
        } else {
            format!("Anthropic returned {status} for the usage endpoint.")
        };
        return ProviderLimits::unavailable("claude_code", hint);
    }

    let usage: UsageResponse = match response.json() {
        Ok(u) => u,
        Err(e) => {
            return ProviderLimits::unavailable(
                "claude_code",
                format!("Could not read Anthropic's answer: {e}"),
            );
        }
    };

    let windows: Vec<UsageWindow> = [("5-hour", usage.five_hour), ("weekly", usage.seven_day)]
        .into_iter()
        .filter_map(|(label, dto)| {
            let dto = dto?;
            let percent = dto.utilization?;
            Some(UsageWindow {
                label: label.to_string(),
                percent,
                resets_at_ms: dto.resets_at.as_deref().and_then(parse_iso_ms),
                severity: LimitSeverity::from_percent(percent),
            })
        })
        .collect();

    if windows.is_empty() {
        return ProviderLimits::unavailable(
            "claude_code",
            "Anthropic reported no usage windows for this account.",
        );
    }

    ProviderLimits {
        source: "claude_code".to_string(),
        plan: None,
        windows,
        observed_at_ms: now_ms(),
        note: None,
        stale: false,
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Anthropic writes `2026-07-27T15:19:59.625679+00:00`: microseconds, and an
/// offset rather than a `Z`.
fn parse_iso_ms(raw: &str) -> Option<i64> {
    raw.parse::<jiff::Timestamp>()
        .ok()
        .map(|t| t.as_millisecond())
}

/// Where the credentials came from, so a refreshed one goes back to the same
/// place. Writing the Keychain copy into the file, or the other way round,
/// would leave Claude Code reading whichever one this did not touch.
enum Store {
    #[cfg(target_os = "macos")]
    Keychain,
    File(std::path::PathBuf),
}

/// The blob Claude Code stored, kept whole.
///
/// The whole text rather than the fields this module cares about, because a
/// refreshed login is written back by editing three values in it. Anything
/// else in there is Claude Code's, and dropping a field this version has not
/// heard of would quietly take it away from the tool that owns it.
struct Stored {
    raw: String,
    store: Store,
}

impl Stored {
    fn token(&self) -> Option<OauthToken> {
        serde_json::from_str::<StoredCredentials>(&self.raw)
            .ok()?
            .claude_ai_oauth
    }
}

/// The credentials Claude Code stored, from wherever it put them.
///
/// The Keychain first, because that is where it puts them on a Mac, then the
/// file it falls back to.
fn stored_credentials() -> Option<Stored> {
    #[cfg(target_os = "macos")]
    if let Some(raw) = keychain_blob() {
        return Some(Stored {
            raw,
            store: Store::Keychain,
        });
    }
    let path = directories::UserDirs::new()?
        .home_dir()
        .join(".claude/.credentials.json");
    let raw = std::fs::read_to_string(&path).ok()?;
    Some(Stored {
        raw,
        store: Store::File(path),
    })
}

/// Trade the refresh token for a new access token, and hand the result back to
/// Claude Code.
///
/// The one place in this project that writes another tool's credential. It
/// earns that because the alternative is worse for the person using both: an
/// access token lives hours, Claude Code only rewrites this when it happens to
/// refresh, and a machine driving it any other way leaves the stored login
/// expired for days while the panel repeats advice that is not working. The
/// refresh token that comes back replaces the one that was spent, so the tool
/// this belongs to keeps working rather than being quietly signed out.
///
/// Nothing is written unless the vendor answered with a complete, usable
/// token, and it goes back to the store it was read from.
fn refresh(
    client: &reqwest::blocking::Client,
    stored: &Stored,
    token: &OauthToken,
) -> Result<String, String> {
    let refresh_token = token
        .refresh_token
        .as_deref()
        .filter(|t| !t.is_empty())
        .ok_or(
            "The stored Claude Code login has expired and carries nothing to renew it with. \
             Sign in again with `claude` in a terminal.",
        )?;

    let response = client
        .post(TOKEN_URL)
        .json(&serde_json::json!({
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": CLIENT_ID,
        }))
        .send()
        .map_err(|e| format!("Could not reach Anthropic to renew the login: {e}"))?;

    if !response.status().is_success() {
        return Err(format!(
            "The stored Claude Code login could not be renewed ({}). \
             Sign in again with `claude` in a terminal.",
            response.status()
        ));
    }

    let fresh: RefreshedToken = response
        .json()
        .map_err(|e| format!("Could not read Anthropic's answer while renewing: {e}"))?;
    if fresh.access_token.is_empty() {
        return Err("Anthropic renewed the login without returning a token.".into());
    }

    // Best effort on purpose. The reading is good either way, and failing it
    // because the store could not be updated would turn a cosmetic problem
    // into a missing number.
    let _ = write_back(stored, &fresh);
    Ok(fresh.access_token)
}

/// The stored blob with the renewed login in it, and everything else left
/// exactly as it was.
fn renewed_blob(raw: &str, fresh: &RefreshedToken) -> Result<String, String> {
    let mut blob: serde_json::Value = serde_json::from_str(raw).map_err(|e| e.to_string())?;
    let oauth = blob
        .get_mut("claudeAiOauth")
        .and_then(|v| v.as_object_mut())
        .ok_or("the stored credentials changed shape")?;

    oauth.insert("accessToken".into(), fresh.access_token.clone().into());
    // Only when the vendor sent one. An absent field means the refresh token
    // did not rotate, and replacing it with nothing would throw away the only
    // thing that can renew this login again.
    if let Some(refresh) = fresh.refresh_token.as_ref().filter(|t| !t.is_empty()) {
        oauth.insert("refreshToken".into(), refresh.clone().into());
    }
    if let Some(seconds) = fresh.expires_in {
        let expires_at = now_ms().saturating_add(seconds.saturating_mul(1000));
        oauth.insert("expiresAt".into(), expires_at.into());
    }
    serde_json::to_string(&blob).map_err(|e| e.to_string())
}

/// Put the renewed login back where Claude Code will look for it.
fn write_back(stored: &Stored, fresh: &RefreshedToken) -> Result<(), String> {
    let updated = renewed_blob(&stored.raw, fresh)?;
    match &stored.store {
        #[cfg(target_os = "macos")]
        Store::Keychain => write_keychain(&updated),
        Store::File(path) => {
            crate::snapshot::write_private_atomically(path, &updated).map_err(|e| e.to_string())?;
            Ok(())
        }
    }
}

/// Replace the Keychain item, without the secret ever reaching a command line.
///
/// `security` takes the value on stdin when `-w` is given nothing, asking for
/// it twice the way it would ask a person. An argument would put a live token
/// in the process table for anything reading `ps` to pick up.
#[cfg(target_os = "macos")]
fn write_keychain(blob: &str) -> Result<(), String> {
    use std::io::Write;

    let account = std::env::var("USER").map_err(|e| e.to_string())?;
    let mut child = std::process::Command::new("security")
        .args(["add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a"])
        .arg(&account)
        .arg("-w")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    if let Some(stdin) = child.stdin.as_mut() {
        // No trailing newline: Claude Code may not trim the Keychain value.
        stdin
            .write_all(blob.as_bytes())
            .map_err(|e| e.to_string())?;
        stdin.flush().map_err(|e| e.to_string())?;
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| "the Keychain refused the renewed login".to_string())
}

/// The Keychain copy, on the platform that has one.
///
/// No stub for the others: the only caller is behind the same condition, and a
/// version of this that always answers "nothing" is a function the compiler is
/// right to complain about.
#[cfg(target_os = "macos")]
fn keychain_blob() -> Option<String> {
    let account = std::env::var("USER").ok()?;
    let out = std::process::Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a"])
        .arg(&account)
        .arg("-w")
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_credential_blob_parses_the_way_claude_code_writes_it() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"r","expiresAt":1785180175976,"subscriptionType":"max"}}"#;
        let creds: StoredCredentials = serde_json::from_str(raw).unwrap();
        let token = creds.claude_ai_oauth.unwrap();
        assert_eq!(token.access_token, "sk-test");
        assert_eq!(token.expires_at, Some(1785180175976));
    }

    #[test]
    fn a_renewed_login_keeps_everything_else_claude_code_stored() {
        // The blob belongs to another tool. Rewriting it from the fields this
        // module knows about would silently take away the ones it does not.
        let raw = r#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r",
            "expiresAt":1,"subscriptionType":"pro","rateLimitTier":"default","scopes":["a"]}}"#;
        let fresh = RefreshedToken {
            access_token: "new".into(),
            refresh_token: Some("new-r".into()),
            expires_in: Some(3600),
        };
        let updated: serde_json::Value =
            serde_json::from_str(&renewed_blob(raw, &fresh).unwrap()).unwrap();
        let oauth = &updated["claudeAiOauth"];
        assert_eq!(oauth["accessToken"], "new");
        assert_eq!(oauth["refreshToken"], "new-r");
        assert_eq!(oauth["subscriptionType"], "pro");
        assert_eq!(oauth["rateLimitTier"], "default");
        assert_eq!(oauth["scopes"][0], "a");
        assert!(oauth["expiresAt"].as_i64().unwrap() > now_ms());
    }

    #[test]
    fn a_refresh_token_that_did_not_rotate_is_left_alone() {
        // An absent field means the old one still works. Writing nothing over
        // it would leave the login with no way to renew itself again.
        let raw = r#"{"claudeAiOauth":{"accessToken":"old","refreshToken":"keep-me"}}"#;
        let fresh = RefreshedToken {
            access_token: "new".into(),
            refresh_token: None,
            expires_in: None,
        };
        let updated: serde_json::Value =
            serde_json::from_str(&renewed_blob(raw, &fresh).unwrap()).unwrap();
        assert_eq!(updated["claudeAiOauth"]["refreshToken"], "keep-me");
    }

    #[test]
    fn a_blob_without_an_oauth_section_is_not_a_login() {
        let creds: StoredCredentials = serde_json::from_str(r#"{"somethingElse":{}}"#).unwrap();
        assert!(creds.claude_ai_oauth.is_none());
    }

    #[test]
    fn the_usage_shape_parses_with_anthropics_own_timestamps() {
        // Microseconds and a `+00:00` offset, which is what the API actually
        // sends. Parsing this as plain RFC 3339 millis drops the reset time and
        // every window renders as "resets: unknown".
        let raw = r#"{
            "five_hour": {"utilization": 84.0, "resets_at": "2026-07-27T15:19:59.625679+00:00",
                          "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
            "seven_day": {"utilization": 17.0, "resets_at": "2026-08-03T05:59:59.625701+00:00"}
        }"#;
        let usage: UsageResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(usage.five_hour.as_ref().unwrap().utilization, Some(84.0));

        let ms = parse_iso_ms(usage.five_hour.unwrap().resets_at.as_deref().unwrap()).unwrap();
        assert_eq!(ms, 1785165599625);
        assert_eq!(
            LimitSeverity::from_percent(84.0),
            LimitSeverity::Warning,
            "84% of a five hour window is worth a warning"
        );
    }

    #[test]
    fn a_missing_login_is_words_and_not_a_zero() {
        let out = ProviderLimits::unavailable("claude_code", "not signed in");
        assert!(out.windows.is_empty());
        assert!(out.note.is_some());
    }
}
