//! Local vendor credential discovery.
//!
//! Privacy boundary: tokens stay on this machine and are never part of a
//! tokenstat.ai sync payload. Reading what the vendor app already stored
//! locally is how `tokenstat scan` can cover Cursor without a paste dance.

use crate::Vendor;
use std::path::{Path, PathBuf};

/// Best-effort read of a session the vendor app already left on disk / in the
/// OS keychain. Returns `None` when the platform has no known location or the
/// item is missing. Never errors on "not installed".
pub fn local_token(vendor: Vendor) -> Option<String> {
    match vendor {
        Vendor::Cursor => cursor_access_token(),
        Vendor::Antigravity => antigravity_token(),
    }
}

/// What this machine holds for Cursor, from one read of each place it keeps a
/// sign-in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CursorSignIn {
    /// The newest token that has not expired.
    Live(String),
    /// Every sign-in found has expired. The latest expiry, in epoch
    /// milliseconds, so a caller can say when rather than "signed out".
    Lapsed { expired_at_ms: i64 },
    /// Nothing found.
    Missing,
}

/// Read the Cursor app's sign-in and the CLI's selected credential store.
///
/// The app writes its live session into its own `state.vscdb` and renews it
/// there. The keychain item is what `cursor-agent login` left behind, and it
/// is not renewed by the app. It can sit expired for weeks while the app stays
/// signed in, and reading only it made every quota read a 401 and left the
/// plan panel on a stale reading. The CLI uses a file on other platforms and
/// when explicitly configured to on macOS. Use the newest token that
/// has not expired. An expired one is never handed out as live, because it
/// would shadow a session the person pasted with `tokenstat auth cursor`.
pub fn cursor_sign_in() -> CursorSignIn {
    resolve_cursor(cursor_candidates(), now_secs())
}

fn resolve_cursor(candidates: Vec<String>, now: i64) -> CursorSignIn {
    let lapsed = candidates
        .iter()
        .filter_map(|token| jwt_expiry(token))
        .max()
        .map(|seconds| seconds.saturating_mul(1000));
    match (freshest_unexpired(candidates, now), lapsed) {
        (Some(token), _) => CursorSignIn::Live(token),
        (None, Some(expired_at_ms)) => CursorSignIn::Lapsed { expired_at_ms },
        (None, None) => CursorSignIn::Missing,
    }
}

fn cursor_access_token() -> Option<String> {
    match cursor_sign_in() {
        CursorSignIn::Live(token) => Some(token),
        _ => None,
    }
}

fn cursor_candidates() -> Vec<String> {
    let mut candidates = Vec::new();
    candidates.extend(cursor_app_state_token());
    let env = |key: &str| std::env::var_os(key).map(PathBuf::from);
    if let Some(base) = directories::BaseDirs::new() {
        candidates.extend(cursor_cli_file_token(base.home_dir(), &env));
    }
    #[cfg(target_os = "macos")]
    if !matches!(
        env("AGENT_CLI_CREDENTIAL_STORE").as_deref(),
        Some(kind) if kind == Path::new("file") || kind == Path::new("memory")
    ) {
        candidates.extend(keychain_password("cursor-access-token", "cursor-user"));
    }
    candidates
}

/// The CLI's file credential store, matching its platform-specific location.
pub fn cursor_auth_file(home: &Path, env: &dyn Fn(&str) -> Option<PathBuf>) -> PathBuf {
    if cfg!(target_os = "macos") {
        home.join(".cursor/auth.json")
    } else if cfg!(windows) {
        env("APPDATA")
            .filter(|dir| !dir.as_os_str().is_empty())
            .unwrap_or_else(|| home.join("AppData").join("Roaming"))
            .join("Cursor/auth.json")
    } else {
        env("XDG_CONFIG_HOME")
            .filter(|dir| !dir.as_os_str().is_empty())
            .unwrap_or_else(|| home.join(".config"))
            .join("cursor/auth.json")
    }
}

fn cursor_cli_file_token(home: &Path, env: &dyn Fn(&str) -> Option<PathBuf>) -> Option<String> {
    let kind = env("AGENT_CLI_CREDENTIAL_STORE");
    if kind.as_deref() == Some(Path::new("memory"))
        || (cfg!(target_os = "macos") && kind.as_deref() != Some(Path::new("file")))
    {
        return None;
    }
    let raw = std::fs::read_to_string(cursor_auth_file(home, env)).ok()?;
    let value: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let token = value.get("accessToken")?.as_str()?.trim();
    (!token.is_empty()).then(|| token.to_string())
}

/// The newest unexpired token. A token without a readable `exp` is kept as a
/// last resort: it is not a JWT this code understands, and the server is the
/// one to judge it.
fn freshest_unexpired(candidates: Vec<String>, now: i64) -> Option<String> {
    let mut opaque = None;
    let mut best: Option<(i64, String)> = None;
    for token in candidates {
        match jwt_expiry(&token) {
            // A minute of skew, so a request does not leave with a token that
            // expires in flight.
            Some(exp) if exp > now + 60 => {
                if best.as_ref().is_none_or(|(seen, _)| exp > *seen) {
                    best = Some((exp, token));
                }
            }
            Some(_) => {}
            None => {
                opaque.get_or_insert(token);
            }
        }
    }
    best.map(|(_, token)| token).or(opaque)
}

/// The access token the Cursor app keeps in its global state database.
///
/// Opened read-only. The file belongs to Cursor and is often over a gigabyte,
/// but the lookup is one primary-key read, and the app holding it open in WAL
/// mode does not block a reader.
fn cursor_app_state_token() -> Option<String> {
    let path = cursor_state_db()?;
    if !path.is_file() {
        return None;
    }
    let connection = rusqlite::Connection::open_with_flags(
        &path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let _ = connection.busy_timeout(std::time::Duration::from_millis(500));
    let value: String = connection
        .query_row(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            [],
            |row| row.get(0),
        )
        .ok()?;
    let token = value.trim().trim_matches('"').to_string();
    (!token.is_empty()).then_some(token)
}

fn cursor_state_db() -> Option<std::path::PathBuf> {
    let base = directories::BaseDirs::new()?;
    // `config_dir` is Application Support on macOS, `~/.config` on Linux and
    // the roaming AppData folder on Windows, which is where Cursor (like every
    // VS Code fork) puts its `User` directory.
    Some(
        base.config_dir()
            .join("Cursor")
            .join("User")
            .join("globalStorage")
            .join("state.vscdb"),
    )
}

/// The `exp` claim of a JWT, in epoch seconds. No signature check: this only
/// decides which local token to try, and the server still verifies it.
pub fn jwt_expiry(token: &str) -> Option<i64> {
    jwt_claims(token)?.get("exp")?.as_i64()
}

/// The `sub` claim of a JWT: which account it signs in, without the secret.
pub fn jwt_subject(token: &str) -> Option<String> {
    jwt_claims(token)?.get("sub")?.as_str().map(str::to_string)
}

fn jwt_claims(token: &str) -> Option<serde_json::Value> {
    let payload = token.trim().split('.').nth(1)?;
    let bytes = base64url_decode(payload)?;
    serde_json::from_slice(&bytes).ok()
}

fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let mut buffer: u32 = 0;
    let mut bits = 0;
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(out)
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn antigravity_token() -> Option<String> {
    // Prefer a still-valid OAuth access token the Gemini / Antigravity tools
    // already wrote, then the macOS keychain item.
    if let Some(t) = gemini_oauth_access_token() {
        return Some(t);
    }
    #[cfg(target_os = "macos")]
    {
        keychain_password("gemini", "antigravity")
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Read `~/.gemini/oauth_creds.json` when the access token is still fresh.
fn gemini_oauth_access_token() -> Option<String> {
    let path = directories::BaseDirs::new()?
        .home_dir()
        .join(".gemini")
        .join("oauth_creds.json");
    let text = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let token = v.get("access_token")?.as_str()?.trim();
    if token.is_empty() {
        return None;
    }
    // expiry_date is epoch milliseconds when present.
    if let Some(exp_ms) = v.get("expiry_date").and_then(|x| x.as_i64()) {
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_millis() as i64;
        // 60s skew so we refresh before the server rejects us.
        if now_ms + 60_000 >= exp_ms {
            return None;
        }
    }
    Some(token.to_string())
}

/// One keychain item, as `security` answers for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeychainItem {
    Found(String),
    /// `security` says the item is not there (exit 44). That is an answer.
    Missing,
    /// The keychain could not be asked, or refused. Not evidence either way.
    Unreadable,
}

/// Read one generic password from the login keychain.
///
/// The absolute path, because a daemon started by launchd has a short `PATH`
/// and a hook environment may have none.
#[cfg(target_os = "macos")]
pub fn keychain_item(service: &str, account: &str) -> KeychainItem {
    use std::process::{Command, Stdio};
    let Ok(output) = Command::new("/usr/bin/security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    else {
        return KeychainItem::Unreadable;
    };
    match output.status.code() {
        Some(0) => match String::from_utf8(output.stdout) {
            Ok(text) if !text.trim().is_empty() => KeychainItem::Found(text.trim().to_string()),
            Ok(_) => KeychainItem::Missing,
            Err(_) => KeychainItem::Unreadable,
        },
        Some(44) => KeychainItem::Missing,
        _ => KeychainItem::Unreadable,
    }
}

#[cfg(target_os = "macos")]
fn keychain_password(service: &str, account: &str) -> Option<String> {
    match keychain_item(service, account) {
        KeychainItem::Found(secret) => Some(secret),
        KeychainItem::Missing | KeychainItem::Unreadable => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jwt(exp: i64) -> String {
        let claims = serde_json::json!({"exp": exp}).to_string();
        let mut payload = String::new();
        const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        for chunk in claims.as_bytes().chunks(3) {
            let n = chunk
                .iter()
                .enumerate()
                .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
            for i in 0..=chunk.len() {
                payload.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            }
        }
        format!("header.{payload}.signature")
    }

    #[test]
    fn reads_the_expiry_of_a_jwt() {
        assert_eq!(jwt_expiry(&jwt(1_790_136_811)), Some(1_790_136_811));
        assert_eq!(jwt_expiry("not-a-jwt"), None);
    }

    #[test]
    fn cursor_file_login_is_discovered_and_expiry_checked() {
        let home = tempfile::tempdir().unwrap();
        let env = |key: &str| (key == "AGENT_CLI_CREDENTIAL_STORE").then(|| PathBuf::from("file"));
        let path = cursor_auth_file(home.path(), &env);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let now = 1_000_000;
        let live = jwt(now + 7_200);
        std::fs::write(
            &path,
            serde_json::json!({"accessToken": live, "refreshToken": "not-an-access-token"})
                .to_string(),
        )
        .unwrap();
        let token = cursor_cli_file_token(home.path(), &env).unwrap();
        assert_eq!(resolve_cursor(vec![token], now), CursorSignIn::Live(live));

        let expired = jwt(now - 10);
        std::fs::write(
            &path,
            serde_json::json!({"accessToken": expired}).to_string(),
        )
        .unwrap();
        let token = cursor_cli_file_token(home.path(), &env).unwrap();
        assert_eq!(
            resolve_cursor(vec![token], now),
            CursorSignIn::Lapsed {
                expired_at_ms: (now - 10) * 1000
            }
        );

        let memory =
            |key: &str| (key == "AGENT_CLI_CREDENTIAL_STORE").then(|| PathBuf::from("memory"));
        assert!(cursor_cli_file_token(home.path(), &memory).is_none());
    }

    #[test]
    fn one_read_says_live_lapsed_or_missing() {
        let now = 1_000_000;
        let stale = jwt(now - 10);
        let older = jwt(now - 500);
        let live = jwt(now + 7_200);
        assert_eq!(
            resolve_cursor(vec![stale.clone(), live.clone()], now),
            CursorSignIn::Live(live)
        );
        assert_eq!(
            resolve_cursor(vec![older, stale], now),
            CursorSignIn::Lapsed {
                expired_at_ms: (now - 10) * 1000
            }
        );
        assert_eq!(resolve_cursor(Vec::new(), now), CursorSignIn::Missing);
    }

    #[test]
    fn the_newest_live_token_wins_and_an_expired_one_is_never_used() {
        let now = 1_000_000;
        let stale = jwt(now - 10);
        let soon = jwt(now + 30);
        let later = jwt(now + 7_200);
        let latest = jwt(now + 86_400);
        assert_eq!(
            freshest_unexpired(vec![stale.clone(), latest.clone(), later], now),
            Some(latest)
        );
        assert_eq!(freshest_unexpired(vec![stale.clone(), soon], now), None);
        assert_eq!(
            freshest_unexpired(vec![stale, "opaque-session".into()], now),
            Some("opaque-session".into())
        );
    }
}
