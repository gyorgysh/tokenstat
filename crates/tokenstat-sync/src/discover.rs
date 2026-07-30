//! Local vendor credential discovery.
//!
//! Privacy boundary: tokens stay on this machine and are never part of a
//! tokenstat.ai sync payload. Reading what the vendor app already stored
//! locally is how `tokenstat scan` can cover Cursor without a paste dance.

use crate::Vendor;

/// Best-effort read of a session the vendor app already left on disk / in the
/// OS keychain. Returns `None` when the platform has no known location or the
/// item is missing. Never errors on "not installed".
pub fn local_token(vendor: Vendor) -> Option<String> {
    match vendor {
        Vendor::Cursor => cursor_access_token(),
        Vendor::Antigravity => antigravity_token(),
    }
}

fn cursor_access_token() -> Option<String> {
    // Cursor (Electron) stores JWTs in the login keychain on macOS.
    #[cfg(target_os = "macos")]
    {
        keychain_password("cursor-access-token", "cursor-user")
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
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

#[cfg(target_os = "macos")]
fn keychain_password(service: &str, account: &str) -> Option<String> {
    use std::process::Command;
    let output = Command::new("security")
        .args(["find-generic-password", "-s", service, "-a", account, "-w"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8(output.stdout).ok()?;
    let t = s.trim().to_string();
    (!t.is_empty()).then_some(t)
}
