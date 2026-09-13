//! Self-update from GitHub Releases.
//!
//! Downloads the matching platform archive and verifies SHA-256 against the
//! release `SHA256SUMS`. A checksum only proves we got the bytes the release
//! published, so before anything is replaced the downloaded binary has to run:
//! `--version` must match the release tag, `--help` must exit 0, and on macOS it
//! must be signed at least as well as the binary it is replacing. The old binary
//! is moved aside rather than overwritten and put back if the new one cannot run
//! from its final path, so a failed update leaves a working `tokenstat` instead
//! of a hole.
//!
//! Auto-apply is on by default (24h check stamp so scans stay quiet most of the
//! time). `scheduled_update` is the daily-timer entry point and ignores that stamp,
//! since the schedule is the cadence. Opt out with `update --auto off`.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

const REPO: &str = "gyorgysh/tokenstat";
const CHECK_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const USER_AGENT: &str = concat!("tokenstat/", env!("CARGO_PKG_VERSION"));
const RELEASE_MANIFEST_URL: &str = "https://tokenstat.ai/api/v1/releases/latest.json";
const RELEASE_MANIFEST_MAX_BYTES: u64 = 256 * 1024;

#[derive(Debug, Error)]
pub enum UpdateError {
    /// A server-requested pause, shared by all release checks on this machine.
    #[error("GitHub is limiting update checks. Checks are paused until the waiting period ends.")]
    RateLimited { retry_at: u64 },
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Message(String),
}

#[derive(Debug, Clone)]
pub struct UpdateCheck {
    pub current: String,
    pub latest: String,
    pub newer: bool,
    pub html_url: String,
    pub asset_name: Option<String>,
    pub asset_url: Option<String>,
    pub sums_url: Option<String>,
    /// API asset urls, used instead of the browser ones when a token is present.
    pub asset_api_url: Option<String>,
    pub sums_api_url: Option<String>,
    /// The disk image's file name, which is also its key in `SHA256SUMS`.
    pub app_dmg_name: Option<String>,
    /// The macOS app's disk image, when the release carries one.
    ///
    /// Separate from `asset_url`, which is the command line tool for the
    /// architecture this process runs on. The app is one universal download and
    /// a different kind of thing: the CLI updates itself in place, and an
    /// application replaces itself by being dragged into Applications.
    pub app_dmg_url: Option<String>,
    /// Windows desktop app zip name, key in `SHA256SUMS`.
    ///
    /// Distinct from the CLI zip (`tokenstat-<ver>-x86_64-pc-windows-msvc.zip`).
    /// Matched as `tokenstat-<ver>-windows-x64.zip` or `windows-arm64`.
    pub app_win_name: Option<String>,
    /// Windows desktop app zip, when the release carries one.
    pub app_win_url: Option<String>,
    /// API url for the Windows app zip, used with a token on a private repo.
    pub app_win_api_url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ApplyReport {
    pub from: String,
    pub to: String,
    pub path: PathBuf,
    /// The on-disk daemon changed. A running host keeps its old executable
    /// until explicitly restarted; this does not claim a host is running.
    pub host_binary_updated: bool,
}

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    html_url: String,
    #[serde(default)]
    prerelease: bool,
    #[serde(default)]
    draft: bool,
    assets: Vec<GhAsset>,
}

#[derive(Debug, Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
    /// API url for the asset. `browser_download_url` is not usable on a private
    /// repository even with a token, so this is what the authenticated path uses.
    #[serde(default)]
    url: String,
}

/// Target triple used in release asset names.
pub fn current_target() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "aarch64-apple-darwin"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "x86_64-apple-darwin"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "x86_64-unknown-linux-gnu"
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        "aarch64-unknown-linux-gnu"
    }
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        "x86_64-pc-windows-msvc"
    }
    #[cfg(all(target_os = "windows", target_arch = "aarch64"))]
    {
        "aarch64-pc-windows-msvc"
    }
    #[cfg(not(any(
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "macos", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "aarch64"),
        all(target_os = "windows", target_arch = "x86_64"),
        all(target_os = "windows", target_arch = "aarch64"),
    )))]
    {
        "unknown"
    }
}

fn client() -> Result<reqwest::blocking::Client, UpdateError> {
    Ok(reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .connect_timeout(Duration::from_secs(10))
        .user_agent(USER_AGENT)
        // Listing requests can attach a GitHub credential. Never forward it.
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}

/// Follows redirects. Asset bytes live on a storage host, and the
/// browser download url is a 302. Never attach a token to this client.
fn download_client() -> Result<reqwest::blocking::Client, UpdateError> {
    Ok(reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .connect_timeout(Duration::from_secs(10))
        .user_agent(USER_AGENT)
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()?)
}

/// Compare two version strings (`0.1.0`, `v0.1.0`, `0.1.0-rc.1`).
///
/// Returns `Ordering::Greater` when `a` is newer than `b`.
pub fn version_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let pa = parse_version(a);
    let pb = parse_version(b);
    pa.cmp(&pb)
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct VersionParts {
    major: u64,
    minor: u64,
    patch: u64,
    /// Empty means release. Non-empty prerelease sorts before the release.
    pre: Option<String>,
}

fn parse_version(raw: &str) -> VersionParts {
    let s = raw.trim().trim_start_matches('v');
    let (num, pre) = match s.split_once('-') {
        Some((n, p)) => (n, Some(p.to_string())),
        None => (s, None),
    };
    let mut parts = num.split('.');
    let major = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let minor = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let patch = parts.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    VersionParts {
        major,
        minor,
        patch,
        // Ord: None > Some, so release > prerelease of same numbers.
        // PartialOrd on Option: None < Some by default actually...
        // We want release (no pre) > prerelease. So invert: use a flag.
        pre: pre.map(|p| format!("0-{p}")).or(Some("1".into())),
    }
}

/// Look up the latest GitHub Release for this platform.
///
/// Compares against this process's own crate version only. The desktop app
/// should call [`check_latest_against`] with both the app bundle version and
/// hostd, so a developer machine that rebuilt hostd alone still sees an
/// update when the app itself is behind.
pub fn check_latest() -> Result<UpdateCheck, UpdateError> {
    check_latest_against(&[env!("CARGO_PKG_VERSION")])
}

/// True when `raw` is something `version_cmp` can treat as a real version.
fn usable_version(raw: &str) -> Option<&str> {
    let s = raw.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("unknown") {
        return None;
    }
    Some(s)
}

/// Oldest version among `installed`, for the `current` field and the newer
/// check. Empty input falls back to this process's crate version.
pub fn oldest_installed<'a>(installed: &[&'a str]) -> &'a str {
    let mut best: Option<&str> = None;
    for raw in installed {
        let Some(v) = usable_version(raw) else {
            continue;
        };
        best = Some(match best {
            None => v,
            Some(b) if version_cmp(v, b) == std::cmp::Ordering::Less => v,
            Some(b) => b,
        });
    }
    best.unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// Look up the latest release and decide whether any of `installed` is older.
///
/// `newer` is true when the release is strictly greater than the oldest usable
/// entry in `installed`. That is the OR of "app older" and "hostd older": a
/// machine that rebuilt hostd from tip still gets offered the update when the
/// app bundle lags the release, and the reverse is true too.
pub fn check_latest_against(installed: &[&str]) -> Result<UpdateCheck, UpdateError> {
    // The public edge snapshot needs no account or GitHub credential. A GitHub
    // cooldown must not prevent reading it, only the direct fallback below.
    if let Some(release) = cached_site_release() {
        return release_check(oldest_installed(installed).to_owned(), release);
    }
    // Serialize release lookups so another caller cannot slip past a newly
    // received cooldown. Persist it so restarting the app does not bypass it.
    static CHECK_LOCK: std::sync::Mutex<u64> = std::sync::Mutex::new(0);
    let mut cooldown = CHECK_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let now = unix_now();
    let cooldown_path = stamp_path()
        .ok()
        .map(|path| path.with_file_name("update-retry-after.stamp"));
    *cooldown = (*cooldown).max(
        cooldown_path
            .as_deref()
            .and_then(|path| read_cooldown(path, now))
            .unwrap_or(0),
    );
    if *cooldown > now {
        return Err(UpdateError::RateLimited {
            retry_at: *cooldown,
        });
    }
    let current = oldest_installed(installed).to_string();
    let client = client()?;
    // Resolve only after the cooldown gate. Reuse the app's cached GitHub
    // connection, including HTTPS git credentials, without starting sign-in.
    // Keep the explicit updater environment override for existing CLI users.
    let token = github_token().or_else(|| {
        crate::forge::credential("github.com").map(|credential| credential.bearer().to_owned())
    });
    let resp = release_request(&client, token.as_deref()).send()?;
    if let Some(retry_at) = release_retry_at(resp.status().as_u16(), resp.headers(), unix_now()) {
        *cooldown = retry_at;
        if let Some(path) = &cooldown_path {
            save_cooldown(path, retry_at);
        }
        return Err(UpdateError::RateLimited { retry_at });
    }
    if resp.status().as_u16() == 404 {
        // Public repo with no release yet is the common case. A private repo
        // without GITHUB_TOKEN looks the same; mention that only as a footnote.
        if token.is_none() {
            return Err(UpdateError::Message(
                "No GitHub Release found yet for this project. \
                 If you expected one and the repository is private, set GITHUB_TOKEN."
                    .into(),
            ));
        }
        return Ok(UpdateCheck {
            current,
            latest: String::new(),
            newer: false,
            html_url: format!("https://github.com/{REPO}/releases"),
            asset_name: None,
            asset_url: None,
            sums_url: None,
            asset_api_url: None,
            sums_api_url: None,
            app_dmg_name: None,
            app_dmg_url: None,
            app_win_name: None,
            app_win_url: None,
            app_win_api_url: None,
        });
    }
    if !resp.status().is_success() {
        let status = resp.status();
        // Secondary limits can omit Retry-After. Do not confuse an unrelated
        // permission failure with a limit just because both use HTTP 403.
        if status.as_u16() == 403
            && resp
                .json::<serde_json::Value>()
                .ok()
                .as_ref()
                .is_some_and(is_rate_limit_message)
        {
            let retry_at = unix_now().saturating_add(60);
            *cooldown = retry_at;
            if let Some(path) = &cooldown_path {
                save_cooldown(path, retry_at);
            }
            return Err(UpdateError::RateLimited { retry_at });
        }
        return Err(UpdateError::Message(format!(
            "GitHub releases returned {}",
            status
        )));
    }
    release_check(current, resp.json()?)
}

fn release_check(current: String, release: GhRelease) -> Result<UpdateCheck, UpdateError> {
    if release.prerelease || release.draft {
        return Err(UpdateError::Message(
            "No stable GitHub Release found.".into(),
        ));
    }
    let latest = release.tag_name.trim_start_matches('v').to_string();
    let newer = version_cmp(&latest, &current) == std::cmp::Ordering::Greater;
    let target = current_target();
    let prefix = format!("tokenstat-{latest}-{target}");
    let asset = release
        .assets
        .iter()
        .find(|a| a.name.starts_with(&prefix) && !a.name.ends_with(".sha256"));
    let sums = release
        .assets
        .iter()
        .find(|a| a.name == "SHA256SUMS" || a.name.ends_with("SHA256SUMS"));
    // Matched by extension rather than an exact name, so the image can be
    // renamed without an installed build losing the ability to find a new one.
    let image = release.assets.iter().find(|a| a.name.ends_with(".dmg"));
    let win = release
        .assets
        .iter()
        .find(|a| is_windows_app_zip(&a.name, windows_app_arch()));
    Ok(UpdateCheck {
        current,
        latest,
        newer,
        html_url: release.html_url,
        asset_name: asset.map(|a| a.name.clone()),
        asset_url: asset.map(|a| a.browser_download_url.clone()),
        sums_url: sums.map(|a| a.browser_download_url.clone()),
        asset_api_url: asset
            .map(|a| a.url.clone())
            .filter(|u: &String| !u.is_empty()),
        sums_api_url: sums
            .map(|a| a.url.clone())
            .filter(|u: &String| !u.is_empty()),
        // Matched by extension rather than by an exact file name, so the
        // naming of the image can change without an old build losing the
        // ability to point at a new one.
        app_dmg_name: image.map(|a| a.name.clone()),
        app_dmg_url: image.map(|a| a.browser_download_url.clone()),
        app_win_name: win.map(|a| a.name.clone()),
        app_win_url: win.map(|a| a.browser_download_url.clone()),
        app_win_api_url: win
            .map(|a| a.url.clone())
            .filter(|u: &String| !u.is_empty()),
    })
}

#[derive(Deserialize)]
struct ReleaseManifest {
    schema: u32,
    checked_at: u64,
    release: GhRelease,
}

fn cached_site_release() -> Option<GhRelease> {
    // No redirects, cookies, credentials or identifying query parameters.
    // Keep fallback latency bounded when the website is unavailable.
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(5))
        .connect_timeout(Duration::from_secs(3))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(USER_AGENT)
        .build()
        .ok()?;
    let response = client.get(RELEASE_MANIFEST_URL).send().ok()?;
    if !response.status().is_success() {
        return None;
    }
    let mut bytes = Vec::new();
    response
        .take(RELEASE_MANIFEST_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > RELEASE_MANIFEST_MAX_BYTES {
        return None;
    }
    validated_manifest(&bytes, unix_now())
}

fn validated_manifest(bytes: &[u8], now: u64) -> Option<GhRelease> {
    let manifest: ReleaseManifest = serde_json::from_slice(bytes).ok()?;
    if manifest.schema != 1
        || manifest.checked_at == 0
        || manifest.checked_at > now.saturating_add(300)
        || now.saturating_sub(manifest.checked_at) > 24 * 60 * 60
    {
        return None;
    }
    let release = manifest.release;
    let version = release
        .tag_name
        .strip_prefix('v')
        .unwrap_or(&release.tag_name);
    let parts: Vec<_> = version.split('.').collect();
    if release.prerelease
        || release.draft
        || parts.len() != 3
        || parts.iter().any(|part| {
            part.is_empty()
                || !part.bytes().all(|c| c.is_ascii_digit())
                || part.parse::<u64>().is_err()
        })
        || release.html_url
            != format!(
                "https://github.com/{REPO}/releases/tag/{}",
                release.tag_name
            )
        || release.assets.is_empty()
        || release.assets.len() > 128
    {
        return None;
    }
    let mut names = std::collections::HashSet::new();
    for asset in &release.assets {
        let api_prefix = format!("https://api.github.com/repos/{REPO}/releases/assets/");
        let api_id = asset.url.strip_prefix(&api_prefix)?;
        if asset.name.is_empty()
            || !asset
                .name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
            || !names.insert(&asset.name)
            || asset.browser_download_url
                != format!(
                    "https://github.com/{REPO}/releases/download/{}/{}",
                    release.tag_name, asset.name
                )
            || api_id.is_empty()
            || !api_id.bytes().all(|c| c.is_ascii_digit())
        {
            return None;
        }
    }
    // An incomplete publish must not advertise an update with no integrity file.
    if !release
        .assets
        .iter()
        .any(|asset| asset.name == "SHA256SUMS")
    {
        return None;
    }
    Some(release)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_rate_limit_message(body: &serde_json::Value) -> bool {
    body.get("message")
        .and_then(|v| v.as_str())
        .is_some_and(|message| message.to_ascii_lowercase().contains("rate limit"))
}

/// Authentication is limited to this fixed API endpoint. Download redirects
/// use their separate, unauthenticated client and never receive this token.
fn release_request(
    client: &reqwest::blocking::Client,
    token: Option<&str>,
) -> reqwest::blocking::RequestBuilder {
    let request = client.get(format!(
        "https://api.github.com/repos/{REPO}/releases/latest"
    ));
    match token {
        Some(token) => request.bearer_auth(token),
        None => request,
    }
}

fn read_cooldown(path: &Path, now: u64) -> Option<u64> {
    fs::read_to_string(path)
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .filter(|until| *until > now)
}

fn save_cooldown(path: &Path, retry_at: u64) {
    // A reader in another process must never see a truncated deadline.
    // The in-memory deadline still protects this process if disk is unwritable.
    let _ = atomicwrites::AtomicFile::new(path, atomicwrites::AllowOverwrite)
        .write(|file| file.write_all(retry_at.to_string().as_bytes()));
}

fn release_retry_at(status: u16, headers: &reqwest::header::HeaderMap, now: u64) -> Option<u64> {
    let number = |key: &str| headers.get(key)?.to_str().ok()?.parse::<u64>().ok();
    let retry = number("retry-after");
    let exhausted = number("x-ratelimit-remaining") == Some(0);
    if status != 429 && !(status == 403 && (exhausted || retry.is_some())) {
        return None;
    }
    let reset = if exhausted {
        number("x-ratelimit-reset")
    } else {
        None
    };
    // GitHub supplies seconds in Retry-After. Without a usable deadline,
    // leave at least a minute before another attempt, including secondary limits.
    Some(
        reset
            .unwrap_or(0)
            .max(now.saturating_add(retry.unwrap_or(60).max(1))),
    )
}

/// Arch token used in Windows app zip names (`windows-x64`, `windows-arm64`).
pub fn windows_app_arch() -> &'static str {
    #[cfg(target_arch = "aarch64")]
    {
        "arm64"
    }
    #[cfg(not(target_arch = "aarch64"))]
    {
        "x64"
    }
}

/// True for the desktop app zip, false for the CLI's target-triple zip.
pub fn is_windows_app_zip(name: &str, arch: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if !lower.ends_with(".zip") || lower.ends_with(".sha256") {
        return false;
    }
    let needle = format!("-windows-{arch}");
    lower.contains(&needle)
}

/// Download the release's disk image and prove it is the published one.
///
/// Returns the path it was written to. Deliberately stops there: this crate
/// downloads and verifies, and the app mounts, checks the signature and
/// installs. Splitting it that way keeps the one step that needs Apple's own
/// tools in the process that has them, and keeps this function testable as what
/// it is, a fetch with a checksum on it.
///
/// The checksum proves the bytes are the ones the release published. It does
/// not prove the release is ours, which is what the app's `codesign` and
/// `spctl` checks are for. Neither check replaces the other.
pub fn download_app_image() -> Result<PathBuf, UpdateError> {
    // The caller already compared the installed bundle and host versions.
    // This process may be current while the app is older, so check.newer
    // (which only describes this process) must not veto the bundle download.
    let check = check_latest()?;
    let url = check.app_dmg_url.as_deref().ok_or_else(|| {
        UpdateError::Message(format!(
            "release v{} has no macOS app download",
            check.latest
        ))
    })?;
    let name = check.app_dmg_name.as_deref().unwrap_or("tokenstat.dmg");
    let sums_url = check
        .sums_url
        .as_deref()
        .ok_or_else(|| UpdateError::Message("release is missing SHA256SUMS".into()))?;

    let client = client()?;
    let sums_bytes = read_capped(
        download_response(&client, sums_url, check.sums_api_url.as_deref())?,
        "SHA256SUMS",
        SUMS_MAX_BYTES,
    )?;
    let expected = expected_sha256(&String::from_utf8_lossy(&sums_bytes), name)
        .ok_or_else(|| UpdateError::Message(format!("SHA256SUMS has no entry for {name}")))?;

    let path = tempfile_dir()?.join(name);
    let actual = stream_to_file_capped(
        download_response(&client, url, None)?,
        &path,
        name,
        ASSET_MAX_BYTES,
    )?;
    if actual != expected {
        let _ = fs::remove_file(&path);
        return Err(UpdateError::Message(format!(
            "checksum mismatch for {name}: expected {expected}, got {actual}"
        )));
    }
    Ok(path)
}

/// Download the Windows desktop app zip and prove it is the published one.
///
/// Same split as [`download_app_image`]: this crate fetches and checksums, the
/// app checks Authenticode (when the running build is signed) and replaces
/// files. Preview builds are unsigned, so the app skips Authenticode there
/// the way a local Mac build skips Developer ID.
pub fn download_windows_app_archive() -> Result<PathBuf, UpdateError> {
    // As on macOS, a current host can be downloading for an older app.
    let check = check_latest()?;
    let url = check.app_win_url.as_deref().ok_or_else(|| {
        UpdateError::Message(format!(
            "release v{} has no Windows app download",
            check.latest
        ))
    })?;
    let name = check
        .app_win_name
        .as_deref()
        .unwrap_or("tokenstat-windows.zip");
    let sums_url = check
        .sums_url
        .as_deref()
        .ok_or_else(|| UpdateError::Message("release is missing SHA256SUMS".into()))?;

    let client = client()?;
    let sums_bytes = read_capped(
        download_response(&client, sums_url, check.sums_api_url.as_deref())?,
        "SHA256SUMS",
        SUMS_MAX_BYTES,
    )?;
    let expected = expected_sha256(&String::from_utf8_lossy(&sums_bytes), name)
        .ok_or_else(|| UpdateError::Message(format!("SHA256SUMS has no entry for {name}")))?;

    let path = tempfile_dir()?.join(name);
    let actual = stream_to_file_capped(
        download_response(&client, url, check.app_win_api_url.as_deref())?,
        &path,
        name,
        ASSET_MAX_BYTES,
    )?;
    if actual != expected {
        let _ = fs::remove_file(&path);
        return Err(UpdateError::Message(format!(
            "checksum mismatch for {name}: expected {expected}, got {actual}"
        )));
    }
    Ok(path)
}

/// A GitHub token from the environment, if one is set and non-empty.
fn github_token() -> Option<String> {
    std::env::var("GITHUB_TOKEN")
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// Release asset bytes are bounded: archives here are tens of megabytes, and
/// the sums file is a few kilobytes. Anything larger is a misbehaving server
/// or a compromised manifest, not a release, so refuse it rather than filling
/// memory or disk.
const ASSET_MAX_BYTES: u64 = 256 * 1024 * 1024;
const SUMS_MAX_BYTES: u64 = 1024 * 1024;

/// Open the response carrying a release asset.
///
/// Without a token this is a plain GET of the browser download url, which is what
/// a published release needs. With one, it goes through the API asset endpoint,
/// because `browser_download_url` returns 404 on a private repository however the
/// request is authenticated.
///
/// Redirects are followed by hand rather than by the client, so the token is
/// never sent to the storage host the API redirects to. That host needs no
/// credentials of its own: the signed url is the credential.
fn download_response(
    client: &reqwest::blocking::Client,
    browser_url: &str,
    api_url: Option<&str>,
) -> Result<reqwest::blocking::Response, UpdateError> {
    let Some(token) = github_token() else {
        return Ok(download_client()?
            .get(browser_url)
            .send()?
            .error_for_status()?);
    };
    let url = api_url.unwrap_or(browser_url);
    let resp = client
        .get(url)
        .header("authorization", format!("Bearer {token}"))
        .header("accept", "application/octet-stream")
        .send()?;

    if resp.status().is_redirection() {
        let location = resp
            .headers()
            .get("location")
            .and_then(|v| v.to_str().ok())
            .ok_or_else(|| UpdateError::Message("asset redirect without a location".into()))?
            .to_string();
        // Deliberately unauthenticated: this is a pre-signed url on a storage
        // host, and attaching the token would hand it to a third party.
        return Ok(download_client()?
            .get(&location)
            .send()?
            .error_for_status()?);
    }
    Ok(resp.error_for_status()?)
}

fn over_limit(what: &str, max: u64) -> UpdateError {
    UpdateError::Message(format!(
        "{what} is larger than the {max}-byte limit; refusing to download it"
    ))
}

/// Read a small release file (SHA256SUMS) with a size cap.
///
/// The `Content-Length` header is checked first so an absurd response is
/// refused without reading it; the body is then read through a capped reader
/// in case the header lies or is absent.
fn read_capped(
    resp: reqwest::blocking::Response,
    what: &str,
    max: u64,
) -> Result<Vec<u8>, UpdateError> {
    if resp.content_length().is_some_and(|len| len > max) {
        return Err(over_limit(what, max));
    }
    let mut body = Vec::new();
    resp.take(max + 1).read_to_end(&mut body)?;
    if body.len() as u64 > max {
        return Err(over_limit(what, max));
    }
    Ok(body)
}

/// Stream a release asset straight to `dest` with a size cap, returning its
/// hex SHA-256.
///
/// The bytes are hashed while they are written, so a large archive never sits
/// in memory whole, and the checksum the caller compares is over exactly what
/// hit the disk. A partial file is removed when the download is refused.
fn stream_to_file_capped(
    resp: reqwest::blocking::Response,
    dest: &Path,
    what: &str,
    max: u64,
) -> Result<String, UpdateError> {
    if resp.content_length().is_some_and(|len| len > max) {
        return Err(over_limit(what, max));
    }
    let mut file = fs::File::create(dest)?;
    let mut hasher = Sha256::new();
    let mut total: u64 = 0;
    let mut src = resp.take(max + 1);
    let mut buf = [0u8; 8192];
    loop {
        let n = src.read(&mut buf)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > max {
            drop(file);
            let _ = fs::remove_file(dest);
            return Err(over_limit(what, max));
        }
        hasher.update(&buf[..n]);
        file.write_all(&buf[..n])?;
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// Download, verify, and replace the current executable.
/// The pair this installs is the CLI and the daemon beside it, so the path it
/// is given has to be the CLI's.
///
/// Checked rather than trusted. A caller that gets this wrong does not fail,
/// it installs one binary over the other and finds out at the next restart,
/// which is the worst possible moment and names no cause.
fn require_cli_path(dest: &Path) -> Result<(), UpdateError> {
    let expected = if cfg!(windows) {
        "tokenstat.exe"
    } else {
        "tokenstat"
    };
    let name = dest
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    // Case-insensitively on Windows, where two spellings are one path.
    let matches = if cfg!(windows) {
        name.eq_ignore_ascii_case(expected)
    } else {
        name == expected
    };
    if !matches {
        return Err(UpdateError::Message(format!(
            "refusing to update {}: an update replaces {expected} and the daemon beside it, \
             so this is not a path it may be pointed at",
            dest.display()
        )));
    }
    Ok(())
}

pub fn apply_update() -> Result<ApplyReport, UpdateError> {
    let dest = std::env::current_exe()
        .map_err(|e| UpdateError::Message(format!("cannot locate current binary: {e}")))?;
    apply_update_to(&dest)
}

/// The same update, with the command line tool's path given rather than read
/// from `current_exe`.
///
/// `current_exe` is the right answer only for the CLI replacing itself. What
/// this installs is a pair: the CLI at `dest`, and the daemon beside it. Point
/// it at the daemon and it writes the CLI's bytes to the daemon's path, and
/// nothing downstream notices, because `verify_candidate` checks a version
/// number and that `--help` says "tokenstat", which both binaries do. The next
/// service restart then runs the CLI as the daemon. So the path is a
/// parameter, and the one shape it is allowed to have is checked below.
pub fn apply_update_to(dest: &Path) -> Result<ApplyReport, UpdateError> {
    require_cli_path(dest)?;
    let check = check_latest()?;
    if !check.newer {
        return Err(UpdateError::Message(format!(
            "already up to date ({})",
            check.current
        )));
    }
    let asset_url = check.asset_url.as_deref().ok_or_else(|| {
        UpdateError::Message(format!(
            "no release asset for target {} (latest v{})",
            current_target(),
            check.latest
        ))
    })?;
    let asset_name = check.asset_name.as_deref().unwrap_or("archive");
    let sums_url = check
        .sums_url
        .as_deref()
        .ok_or_else(|| UpdateError::Message("release is missing SHA256SUMS".into()))?;

    let client = client()?;
    let sums_bytes = read_capped(
        download_response(&client, sums_url, check.sums_api_url.as_deref())?,
        "SHA256SUMS",
        SUMS_MAX_BYTES,
    )?;
    let sums_text = String::from_utf8_lossy(&sums_bytes).to_string();
    let expected = expected_sha256(&sums_text, asset_name)
        .ok_or_else(|| UpdateError::Message(format!("SHA256SUMS has no entry for {asset_name}")))?;

    let tmp = tempfile_dir()?;
    let archive_path = tmp.join(asset_name);
    let actual = stream_to_file_capped(
        download_response(&client, asset_url, check.asset_api_url.as_deref())?,
        &archive_path,
        asset_name,
        ASSET_MAX_BYTES,
    )?;
    if actual != expected {
        let _ = fs::remove_file(&archive_path);
        return Err(UpdateError::Message(format!(
            "checksum mismatch for {asset_name}: expected {expected}, got {actual}"
        )));
    }
    let extracted = extract_binary(&archive_path, &tmp)?;
    if !is_safe_replace_path(dest) {
        return Err(UpdateError::Message(format!(
            "refusing to replace {} (install via cargo/homebrew, or copy to ~/.local/bin first)",
            dest.display()
        )));
    }
    // A previous cycle may have been unable to delete the binary it replaced
    // (Windows keeps a running image locked against deletion). Clear it now,
    // while nothing is holding it, rather than leaving it forever.
    sweep_replaced_binary(dest);

    make_runnable(&extracted)?;
    #[cfg(target_os = "macos")]
    {
        // Before running it, not after: a quarantined binary is killed by
        // Gatekeeper, which would look exactly like a bad build. Clear the flag
        // only. Do not ad-hoc re-sign: release builds are Developer ID +
        // notarized, and `codesign --sign -` would strip that.
        let _ = Command::new("xattr").args(["-cr"]).arg(&extracted).status();
    }

    // The checksum proves we downloaded what the release published. It says
    // nothing about whether that binary runs on this machine: a bad build, a
    // wrong-architecture asset, or a missing system library all pass a hash and
    // then fail on first use, by which point the working binary is gone. So run
    // the candidate and make it prove itself before it replaces anything.
    verify_candidate(&extracted, &check.latest, dest)?;

    let host_binary_updated = cfg!(unix) && extracted.with_file_name("tokenstat-hostd").is_file();
    #[cfg(unix)]
    replace_unix_release(&extracted, dest, &check.latest)?;
    #[cfg(not(unix))]
    replace_executable(&extracted, dest)?;
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("xattr").args(["-cr"]).arg(dest).status();
    }

    let _ = fs::remove_dir_all(&tmp);
    Ok(ApplyReport {
        from: check.current,
        to: check.latest,
        path: dest.to_path_buf(),
        host_binary_updated,
    })
}

/// Keep the two Unix executables on the same release. Both candidates are
/// checked before replacement, and the daemon is restored if the CLI fails.
#[cfg(unix)]
fn replace_unix_release(candidate: &Path, dest: &Path, version: &str) -> Result<(), UpdateError> {
    let daemon = candidate.with_file_name("tokenstat-hostd");
    let installed_daemon = dest.with_file_name("tokenstat-hostd");
    if !daemon.is_file() {
        // Older releases contained only the CLI. They remain installable only
        // where doing so cannot strand an existing daemon on another version.
        if installed_daemon.exists() {
            return Err(UpdateError::Message("release is missing tokenstat-hostd. The installed CLI and host were kept unchanged".into()));
        }
        return replace_executable(candidate, dest);
    }
    make_runnable(&daemon)?;
    #[cfg(target_os = "macos")]
    let _ = Command::new("xattr").arg("-cr").arg(&daemon).status();
    // Pin the daemon to the installed daemon's team when there is one, not to
    // the CLI's: `verify_candidate` ends in `verify_signature(candidate,
    // current)`, and the daemon replaces the daemon.
    let baseline = if installed_daemon.exists() {
        &installed_daemon
    } else {
        dest
    };
    verify_candidate(&daemon, version, baseline)?;
    let backup = installed_daemon.with_extension("pair-backup");
    let had_daemon = installed_daemon.exists();
    if had_daemon {
        fs::copy(&installed_daemon, &backup)?;
    }
    if let Err(error) = replace_executable(&daemon, &installed_daemon) {
        if !had_daemon {
            let _ = fs::remove_file(&installed_daemon);
        }
        let _ = fs::remove_file(&backup);
        return Err(error);
    }
    if let Err(error) = replace_executable(candidate, dest) {
        let restored = if had_daemon {
            fs::rename(&backup, &installed_daemon)
        } else {
            fs::remove_file(&installed_daemon)
        };
        if let Err(restore_error) = restored {
            return Err(UpdateError::Message(format!(
                "{error}. Could not restore the previous host: {restore_error}. Reinstall the release before restarting the host."
            )));
        }
        return Err(error);
    }
    let _ = fs::remove_file(&backup);
    Ok(())
}

/// How long a probe of the candidate binary may take before we call it broken.
///
/// `--version` and `--help` do no I/O beyond writing to a pipe, so a second
/// would do. Twenty covers a cold page-in from a slow disk and an antivirus
/// scanning a freshly written executable, which is the realistic worst case.
const PROBE_TIMEOUT: Duration = Duration::from_secs(20);

/// Run `bin` with `args` and return (exit ok, combined output).
///
/// Output goes to a file rather than a pipe: a pipe can deadlock if the child
/// writes more than the buffer holds while we are waiting on the exit status,
/// and `--help` is big enough to make that a real risk on some platforms. Also
/// stdin is closed, so a binary that decided to prompt cannot hang us.
fn run_probe(bin: &Path, args: &[&str], timeout: Duration) -> Result<(bool, String), UpdateError> {
    /// Removes the probe's private directory however the probe returns:
    /// success, error, timeout. A leaked directory per probe is unbounded
    /// across a long-lived daemon.
    struct ProbeDir(PathBuf);
    impl Drop for ProbeDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let dir = ProbeDir(tempfile_dir()?);
    // Unique per call: two probes overlapping in one process (the preflight pair,
    // or a caller doing this concurrently) must not read each other's output or
    // delete a file still being written.
    static PROBE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = PROBE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let out_path = dir.0.join(format!(
        "probe-{}-{seq}.txt",
        args.first().unwrap_or(&"x").trim_start_matches('-')
    ));
    let mut child = spawn_probe(bin, args, &out_path)?;

    let deadline = SystemTime::now() + timeout;
    let status = loop {
        match child.try_wait()? {
            Some(status) => break status,
            None => {
                if SystemTime::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(UpdateError::Message(format!(
                        "{} {} did not finish within {}s",
                        bin.display(),
                        args.join(" "),
                        timeout.as_secs()
                    )));
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
    };
    let text = fs::read_to_string(&out_path).unwrap_or_default();
    Ok((status.success(), text))
}

/// Spawn with a short ETXTBSY retry.
///
/// After `replace_executable` copies then renames a candidate into place, Linux
/// can briefly refuse to exec the new inode ("Text file busy") while the writer
/// side of the copy is still settling. A few retries are enough; other errors
/// fail immediately.
fn spawn_probe(
    bin: &Path,
    args: &[&str],
    out_path: &Path,
) -> Result<std::process::Child, UpdateError> {
    let mut delay = Duration::from_millis(10);
    for attempt in 0..8 {
        // Recreate stdio each attempt: a failed spawn may have consumed the
        // previous File handles.
        let out = fs::File::create(out_path)?;
        let err = out.try_clone()?;
        match Command::new(bin)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::from(out))
            .stderr(std::process::Stdio::from(err))
            .spawn()
        {
            Ok(child) => return Ok(child),
            Err(e) if is_etxtbsy(&e) && attempt + 1 < 8 => {
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_millis(80));
            }
            Err(e) => return Err(e.into()),
        }
    }
    Err(UpdateError::Message(format!(
        "could not spawn {}: text file busy",
        bin.display()
    )))
}

fn is_etxtbsy(err: &std::io::Error) -> bool {
    err.kind() == std::io::ErrorKind::ExecutableFileBusy || err.raw_os_error() == Some(26)
}

/// Make a freshly extracted file executable so it can be probed.
fn make_runnable(path: &Path) -> Result<(), UpdateError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(path, perms)?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

/// Prove the downloaded binary works before it replaces a working one.
///
/// The signature is checked first: it is the only question that can be
/// answered without executing the downloaded code, and a signed install must
/// not run a candidate it would refuse. Then the order continues by how
/// cheaply the checks fail: does it run at all, and is it the version the
/// release claims.
fn verify_candidate(
    candidate: &Path,
    expect_version: &str,
    current: &Path,
) -> Result<(), UpdateError> {
    verify_signature(candidate, current)?;

    let (ok, out) = run_probe(candidate, &["--version"], PROBE_TIMEOUT)?;
    if !ok {
        return Err(UpdateError::Message(format!(
            "downloaded binary failed to run (--version exited non-zero): {}",
            out.trim()
        )));
    }
    let reported = out
        .split_whitespace()
        .find(|w| w.chars().next().is_some_and(|c| c.is_ascii_digit()))
        .unwrap_or("");
    if reported.is_empty() {
        return Err(UpdateError::Message(format!(
            "downloaded binary printed no version: {}",
            out.trim()
        )));
    }
    if version_cmp(reported, expect_version) != std::cmp::Ordering::Equal {
        return Err(UpdateError::Message(format!(
            "downloaded binary reports {reported} but the release is {expect_version}; \
             refusing to install a mismatched build"
        )));
    }

    // --help exercises argument parsing, which is where a broken build usually
    // shows itself, and it is the one command guaranteed to need no state.
    let (ok, out) = run_probe(candidate, &["--help"], PROBE_TIMEOUT)?;
    if !ok {
        return Err(UpdateError::Message(format!(
            "downloaded binary failed to run (--help exited non-zero): {}",
            out.trim()
        )));
    }
    if !out.contains("tokenstat") {
        return Err(UpdateError::Message(
            "downloaded binary produced unrecognizable help output".into(),
        ));
    }

    Ok(())
}

/// Whether a binary carries a real signing identity, as opposed to none or an
/// ad-hoc self-signature.
///
/// The distinction matters: `codesign --verify --strict` **succeeds** on an
/// ad-hoc signature, which every locally built binary here has (see the ad-hoc
/// resign step in the README). Treating that as "signed" would arm the check
/// below on development machines, where it guards nothing and would block updates
/// whenever a release is not itself signed. A real identity shows up as an
/// `Authority=` line; ad-hoc reports `Signature=adhoc` and no authority.
///
/// Public so the CLI can prefer a Developer ID install under `~/.local/bin`
/// over a cargo/ad-hoc binary when writing scheduler entries.
#[cfg(target_os = "macos")]
pub fn has_macos_signing_authority(path: &Path) -> bool {
    has_signing_authority(path)
}

#[cfg(target_os = "macos")]
fn has_signing_authority(path: &Path) -> bool {
    let out = Command::new("codesign")
        .args(["--display", "--verbose=2"])
        .arg(path)
        .output();
    let Ok(out) = out else { return false };
    if !out.status.success() {
        return false;
    }
    // codesign writes the display to stderr.
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    text.lines().any(|l| l.starts_with("Authority="))
}

#[cfg(not(target_os = "macos"))]
pub fn has_macos_signing_authority(_path: &Path) -> bool {
    false
}

/// macOS only: never install a binary less trusted than the one it replaces.
///
/// Only enforced when the CURRENT binary carries a real signing identity, which
/// for a normal install means the Developer ID signed and notarized release. A
/// locally built or ad-hoc signed binary has no identity to preserve, so
/// demanding one there would fail every update with a code-signing message the
/// user cannot act on.
#[cfg(target_os = "macos")]
fn verify_signature(candidate: &Path, current: &Path) -> Result<(), UpdateError> {
    if !has_signing_authority(current) {
        return Ok(());
    }
    let verified = Command::new("codesign")
        .args(["--verify", "--strict", "--deep"])
        .arg(candidate)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !verified {
        return Err(UpdateError::Message(
            "the downloaded binary failed codesign verification, and the installed one is signed;              refusing to replace a signed binary with an unverified one"
                .into(),
        ));
    }
    // Match the Mac app: any real Authority is not enough. The replacement has
    // to come from the same publisher as the binary it replaces, or a validly
    // signed build from anybody at all would pass.
    //
    // The team is read from the installed binary rather than written down here.
    // Self-pinning is the stronger check and the tidier one: the rule is "never
    // replace this with something signed by somebody else", it survives a change
    // of publisher without an edit, and no identifier belonging to a real
    // organisation sits in source that anybody can read.
    let Some(team) = developer_id_team(current) else {
        // The current binary is signed but not by a Developer ID, so there is
        // no team to hold the replacement to. `has_signing_authority` already
        // let ad-hoc through above, so this is an unusual build; refuse rather
        // than guess.
        return Err(UpdateError::Message(
            "the installed binary is signed by an identity this updater cannot match;              install the new version by hand"
                .into(),
        ));
    };
    if !has_developer_id_team(candidate, &team) {
        return Err(UpdateError::Message(
            "the downloaded binary is not signed by the tokenstat Developer ID team;              refusing to replace a signed binary with one from another publisher"
                .into(),
        ));
    }
    Ok(())
}

/// True when codesign reports Developer ID Application and the given team.
/// The Developer ID team a binary is signed by, when it is signed by one.
#[cfg(target_os = "macos")]
fn developer_id_team(path: &Path) -> Option<String> {
    let out = Command::new("codesign")
        .args(["-dv", "--verbose=4"])
        .arg(path)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    if !text
        .lines()
        .any(|l| l.starts_with("Authority=Developer ID Application:"))
    {
        return None;
    }
    text.lines()
        .find_map(|l| l.trim().strip_prefix("TeamIdentifier="))
        .map(str::to_string)
        .filter(|t| !t.is_empty() && t != "not set")
}

#[cfg(target_os = "macos")]
fn has_developer_id_team(path: &Path, team: &str) -> bool {
    let out = Command::new("codesign")
        .args(["-dv", "--verbose=4"])
        .arg(path)
        .output();
    let Ok(out) = out else {
        return false;
    };
    if !out.status.success() {
        return false;
    }
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let has_team = text
        .lines()
        .any(|l| l.trim() == format!("TeamIdentifier={team}"));
    let has_dev_id = text
        .lines()
        .any(|l| l.starts_with("Authority=Developer ID Application:"));
    has_team && has_dev_id
}

/// Non-macOS: intentionally a no-op, not a missed check.
///
/// There is no platform identity to pin a replacement to here, so integrity
/// rests on the two gates that already run on every platform: the release's
/// `SHA256SUMS` entry (a missing file or a mismatch is a hard error in
/// `apply_update_to`, before anything is executed) and the
/// `verify_candidate` probes below, which make the downloaded binary run
/// `--version` and `--help` before it replaces anything. Keeping this stub —
/// and calling it unconditionally — holds that ordering in one place rather
/// than scattering `#[cfg]` through the install path.
#[cfg(not(target_os = "macos"))]
fn verify_signature(_candidate: &Path, _current: &Path) -> Result<(), UpdateError> {
    Ok(())
}

/// Delete a `.old` left behind by a previous replace, if it is gone quiet.
///
/// Windows locks a running image against deletion, so the cycle that created it
/// could not always clean up. Failure here is expected and ignored: the file is
/// harmless, and the next run tries again.
fn sweep_replaced_binary(dest: &Path) {
    let _ = fs::remove_file(dest.with_extension("old"));
    let _ = fs::remove_file(dest.with_extension("new"));
}

/// Soft check with TTL. When `auto_apply` is true and a newer release exists,
/// downloads and replaces. Otherwise returns the check for the caller to print.
pub fn maybe_auto_update(auto_apply: bool) -> Result<Option<UpdateOutcome>, UpdateError> {
    if !check_stamp_due()? {
        return Ok(None);
    }
    let check = check_latest()?;
    if !check.newer {
        touch_check_stamp()?;
        return Ok(Some(UpdateOutcome::UpToDate(check)));
    }
    if auto_apply && is_safe_replace_path(&std::env::current_exe().unwrap_or_default()) {
        // The stamp records a successful check, so it is written only after
        // the apply verifies: stamping first would silence the next run after
        // a failed update left the old binary in place.
        let report = apply_update()?;
        touch_check_stamp()?;
        return Ok(Some(UpdateOutcome::Applied(report)));
    }
    touch_check_stamp()?;
    Ok(Some(UpdateOutcome::Available(check)))
}

#[derive(Debug)]
pub enum UpdateOutcome {
    UpToDate(UpdateCheck),
    Available(UpdateCheck),
    Applied(ApplyReport),
}

/// How wide the scheduled update check spreads itself.
///
/// Wider than the sync window (180s) because this one downloads a release asset
/// and hits a shared API, and because nothing is waiting on it: a daily job may
/// as well land anywhere in a quarter of an hour.
pub const UPDATE_JITTER_WINDOW_SECS: u64 = 900;

/// A random delay, not a per-machine offset.
///
/// Unlike sync there is no interval to stay aligned with, so there is nothing to
/// gain from a stable offset, and a random one avoids deriving a machine id for
/// people who never linked an account.
fn update_jitter() -> u64 {
    if let Ok(raw) = std::env::var("TOKENSTAT_UPDATE_JITTER") {
        if let Ok(secs) = raw.trim().parse::<u64>() {
            return secs.min(3600);
        }
    }
    let mut b = [0u8; 2];
    if getrandom::fill(&mut b).is_err() {
        return 0;
    }
    u64::from(u16::from_be_bytes(b)) % UPDATE_JITTER_WINDOW_SECS
}

/// What a scheduled update run did.
#[derive(Debug)]
pub enum ScheduledUpdate {
    /// `update.auto` is off. Nothing was downloaded and nothing was replaced.
    Disabled,
    /// macOS is asleep or in DarkWake. The next timer tick can try again.
    Asleep,
    /// A newer release exists but this install is not ours to replace
    /// (cargo, homebrew, a system path). The package manager owns it.
    NotOurs {
        latest: String,
        path: PathBuf,
    },
    UpToDate(String),
    Applied(ApplyReport),
}

/// `update` as a background job: jittered, quiet, and safe to fail.
///
/// Ignores the 24h check stamp, because the schedule already decides the cadence
/// and a scan's soft check earlier in the day would otherwise cancel this run.
/// It still touches the stamp, so scans stay quiet afterwards.
pub fn scheduled_update() -> Result<ScheduledUpdate, UpdateError> {
    let dest = std::env::current_exe().unwrap_or_default();
    scheduled_update_to(&dest)
}

/// The scheduled update, for a caller whose own executable is not the CLI.
///
/// The daemon runs this on its own timer and must replace the CLI beside it,
/// not itself. See [`apply_update_to`].
pub fn scheduled_update_to(dest: &Path) -> Result<ScheduledUpdate, UpdateError> {
    if !auto_apply_enabled() {
        return Ok(ScheduledUpdate::Disabled);
    }
    if !crate::scheduled_network_allowed() {
        return Ok(ScheduledUpdate::Asleep);
    }
    std::thread::sleep(Duration::from_secs(update_jitter()));

    if !crate::scheduled_network_allowed() {
        return Ok(ScheduledUpdate::Asleep);
    }

    let check = check_latest()?;
    if !check.newer {
        touch_check_stamp()?;
        return Ok(ScheduledUpdate::UpToDate(check.current));
    }
    if !is_safe_replace_path(dest) {
        return Ok(ScheduledUpdate::NotOurs {
            latest: check.latest,
            path: dest.to_path_buf(),
        });
    }
    // As above: only a verified apply counts as a check, so a failure keeps
    // the stamp stale and the next timer tick retries instead of sleeping out
    // the 24h window on a broken install.
    let report = apply_update_to(dest)?;
    touch_check_stamp()?;
    Ok(ScheduledUpdate::Applied(report))
}

/// Whether auto-apply is enabled (config / env). Default: on.
///
/// Opt out with `tokenstat update --auto off`, `"update":{"auto":false}` in
/// config, or `TOKENSTAT_AUTO_UPDATE=0`.
pub fn auto_apply_enabled() -> bool {
    if let Ok(v) = std::env::var("TOKENSTAT_AUTO_UPDATE") {
        let v = v.trim().to_ascii_lowercase();
        if matches!(v.as_str(), "0" | "false" | "no" | "off") {
            return false;
        }
        if matches!(v.as_str(), "1" | "true" | "yes" | "on") {
            return true;
        }
    }
    crate::config::load()
        .ok()
        .and_then(|c| c.update.auto)
        .unwrap_or(true)
}

fn expected_sha256(sums: &str, asset_name: &str) -> Option<String> {
    for line in sums.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // "hash  filename" or "hash *filename". A malformed line is skipped:
        // one bad line must not hide the entry further down.
        let mut parts = line.split_whitespace();
        let (Some(hash), Some(raw_name)) = (parts.next(), parts.next()) else {
            continue;
        };
        let name = raw_name.trim_start_matches('*');
        // Exact filename match only. A suffix match would let
        // `evil-tokenstat-...tar.gz` claim the checksum of the real asset, so
        // compare the whole field, or its basename for sums files that record
        // a relative path (`./name`, `subdir/name`).
        let base = name.rsplit('/').next().unwrap_or(name);
        if name == asset_name || base == asset_name {
            return Some(hash.to_ascii_lowercase());
        }
    }
    None
}

/// A fresh private directory for one update transaction.
///
/// The name is random rather than pid-derived, so another local user cannot
/// predict it and plant a binary for this process to execute, and the
/// directory is created 0700 so nothing else can enter even after the name is
/// seen. `create_dir` refuses a name that already exists, which a symlink
/// counts as.
fn tempfile_dir() -> Result<PathBuf, UpdateError> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| {
        UpdateError::Message(format!(
            "could not make a private update directory: {error}"
        ))
    })?;
    let mut name = String::from("tokenstat-update-");
    for byte in bytes {
        name.push_str(&format!("{byte:02x}"));
    }
    let base = std::env::temp_dir().join(name);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().mode(0o700).create(&base)?;
    }
    #[cfg(not(unix))]
    {
        fs::create_dir(&base)?;
    }
    Ok(base)
}

/// Caps for one extracted archive: enough for a CLI plus its daemon, small
/// enough that a malicious archive cannot fill the disk.
const EXTRACT_MAX_FILES: u64 = 1024;
const EXTRACT_MAX_BYTES: u64 = 512 * 1024 * 1024;

/// Unpack `archive` and return the extracted CLI binary.
///
/// Extraction is in-process, never a shell: the previous `tar -xzf` / PowerShell
/// `Expand-Archive` calls both ran an external tool over attacker-shaped paths
/// (the PowerShell one interpolated them into a `-Command` string), and neither
/// contained traversal. Every entry is checked before it is written: absolute
/// paths, `..`, links, and anything that is not a file or directory are
/// refused, and the write is capped in files and bytes. Entries land in a fresh
/// `extract/` sandbox under the private staging dir, so a hostile name cannot
/// collide with the archive sitting beside it.
fn extract_binary(archive: &Path, dest_dir: &Path) -> Result<PathBuf, UpdateError> {
    let name = archive.file_name().and_then(|s| s.to_str()).unwrap_or("");
    let sandbox = dest_dir.join("extract");
    fs::create_dir(&sandbox).map_err(|e| {
        UpdateError::Message(format!(
            "could not create extraction sandbox {}: {e}",
            sandbox.display()
        ))
    })?;
    if name.ends_with(".tar.gz") || name.ends_with(".tgz") {
        extract_tar_gz(archive, &sandbox)?;
    } else if name.ends_with(".zip") {
        extract_zip(archive, &sandbox)?;
    } else {
        return Err(UpdateError::Message(format!(
            "unsupported archive format: {name}"
        )));
    }
    find_binary(&sandbox)
}

/// Reject any archive path that could write outside the sandbox.
///
/// Absolute paths and `..` are refused outright; the caller additionally joins
/// what passes onto the sandbox, so the result stays inside by construction.
fn reject_unsafe_archive_path(path: &Path) -> Result<(), UpdateError> {
    if path.as_os_str().is_empty() {
        return Err(UpdateError::Message(
            "archive contains an entry with an empty path".into(),
        ));
    }
    for component in path.components() {
        match component {
            std::path::Component::Normal(_) | std::path::Component::CurDir => {}
            _ => {
                return Err(UpdateError::Message(format!(
                    "archive entry escapes its directory: {}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

/// Copy at most `remaining` bytes, accounting them against the archive total.
///
/// The reader is capped one byte past `remaining` so an over-cap entry is
/// detected rather than silently truncated: reading that extra byte means the
/// entry is bigger than allowed. Callers pass what is left of the archive
/// budget, which keeps the on-disk total under the limit by construction.
fn copy_capped<R: Read>(
    src: R,
    dest: &mut fs::File,
    remaining: u64,
    total: &mut u64,
    what: &str,
) -> Result<(), UpdateError> {
    let mut capped = src.take(remaining + 1);
    let mut buf = [0u8; 8192];
    let mut written: u64 = 0;
    loop {
        let n = capped.read(&mut buf)?;
        if n == 0 {
            break;
        }
        written = written.saturating_add(n as u64);
        if written > remaining {
            return Err(UpdateError::Message(format!(
                "{what} exceeds the {EXTRACT_MAX_BYTES}-byte extraction limit"
            )));
        }
        *total = total.saturating_add(n as u64);
        dest.write_all(&buf[..n])?;
    }
    Ok(())
}

fn extract_tar_gz(archive: &Path, dest: &Path) -> Result<(), UpdateError> {
    let file = fs::File::open(archive)?;
    let gz = flate2::read::GzDecoder::new(file);
    let mut tar = tar::Archive::new(gz);
    let mut files: u64 = 0;
    let mut total: u64 = 0;
    for entry in tar.entries()? {
        let mut entry = entry?;
        let kind = entry.header().entry_type();
        // Links are never followed or recreated: a symlink pointing outside
        // the sandbox would turn a later entry (or the candidate search) into
        // a write or exec outside it. Devices and fifos have no place here.
        if kind.is_symlink() || kind.is_hard_link() {
            return Err(UpdateError::Message(
                "archive contains a link; refusing to extract".into(),
            ));
        }
        if !kind.is_file() && !kind.is_dir() {
            return Err(UpdateError::Message(format!(
                "archive contains an unsupported entry of type {kind:?}; refusing to extract"
            )));
        }
        let path = entry.path()?.into_owned();
        reject_unsafe_archive_path(&path)?;
        let out = dest.join(&path);
        if kind.is_dir() {
            fs::create_dir_all(&out)?;
            continue;
        }
        files += 1;
        if files > EXTRACT_MAX_FILES {
            return Err(UpdateError::Message(format!(
                "archive contains more than {EXTRACT_MAX_FILES} files; refusing to extract"
            )));
        }
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)?;
        }
        // Default permissions, never the archive's mode: nothing extracted
        // here should arrive executable or setuid on its own say-so.
        let mut out_file = fs::File::create(&out)?;
        let remaining = EXTRACT_MAX_BYTES.saturating_sub(total);
        if let Err(e) = copy_capped(&mut entry, &mut out_file, remaining, &mut total, "archive") {
            let _ = fs::remove_file(&out);
            return Err(e);
        }
    }
    Ok(())
}

fn extract_zip(archive: &Path, dest: &Path) -> Result<(), UpdateError> {
    let file = fs::File::open(archive)?;
    let mut zip = zip::ZipArchive::new(file)
        .map_err(|e| UpdateError::Message(format!("could not read zip archive: {e}")))?;
    if zip.len() as u64 > EXTRACT_MAX_FILES {
        return Err(UpdateError::Message(format!(
            "archive contains more than {EXTRACT_MAX_FILES} files; refusing to extract"
        )));
    }
    let mut files: u64 = 0;
    let mut total: u64 = 0;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|e| UpdateError::Message(format!("could not read zip entry: {e}")))?;
        // `enclosed_name` returns None for absolute paths and `..`: the same
        // traversal refusal as the tar path, from the crate itself.
        let name = entry
            .enclosed_name()
            .ok_or_else(|| {
                UpdateError::Message("zip entry escapes its directory; refusing to extract".into())
            })?
            .to_path_buf();
        reject_unsafe_archive_path(&name)?;
        // A symlink stored as a regular file would pass the traversal check
        // and then be skipped by the candidate search; refuse it up front so a
        // hostile archive cannot plant one for a later step to follow.
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170_000 == 0o120_000)
        {
            return Err(UpdateError::Message(
                "archive contains a link; refusing to extract".into(),
            ));
        }
        let out = dest.join(&name);
        if entry.is_dir() {
            fs::create_dir_all(&out)?;
            continue;
        }
        files += 1;
        if files > EXTRACT_MAX_FILES {
            return Err(UpdateError::Message(format!(
                "archive contains more than {EXTRACT_MAX_FILES} files; refusing to extract"
            )));
        }
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut out_file = fs::File::create(&out)?;
        let remaining = EXTRACT_MAX_BYTES.saturating_sub(total);
        if let Err(e) = copy_capped(&mut entry, &mut out_file, remaining, &mut total, "archive") {
            let _ = fs::remove_file(&out);
            return Err(e);
        }
    }
    Ok(())
}

fn find_binary(dir: &Path) -> Result<PathBuf, UpdateError> {
    let want = if cfg!(windows) {
        "tokenstat.exe"
    } else {
        "tokenstat"
    };
    for entry in walkdir_shallow(dir)? {
        if entry.file_name().map(|n| n == want).unwrap_or(false) {
            return Ok(entry);
        }
    }
    Err(UpdateError::Message(format!(
        "archive did not contain {want}"
    )))
}

fn walkdir_shallow(dir: &Path) -> Result<Vec<PathBuf>, UpdateError> {
    let mut out = Vec::new();
    fn rec(dir: &Path, out: &mut Vec<PathBuf>, depth: u32) -> Result<(), UpdateError> {
        if depth > 4 {
            return Ok(());
        }
        for e in fs::read_dir(dir)? {
            let e = e?;
            let file_type = e.file_type()?;
            // A symlink in the archive could point at a binary outside the
            // private extraction directory, so it is never a candidate.
            if file_type.is_symlink() {
                continue;
            }
            let p = e.path();
            if file_type.is_dir() {
                rec(&p, out, depth + 1)?;
            } else {
                out.push(p);
            }
        }
        Ok(())
    }
    rec(dir, &mut out, 0)?;
    Ok(out)
}

fn is_safe_replace_path(path: &Path) -> bool {
    let s = path.to_string_lossy();
    if s.contains("/.cargo/") || s.contains("\\.cargo\\") {
        return false;
    }
    if s.starts_with("/usr/") || s.starts_with("/bin/") {
        return false;
    }
    // Homebrew prefixes (Apple Silicon, Intel, and Linuxbrew).
    if s.starts_with("/opt/homebrew/")
        || s.starts_with("/usr/local/Cellar/")
        || s.starts_with("/usr/local/bin/")
        || s.starts_with("/home/linuxbrew/")
        || s.contains("/Homebrew/")
        || s.contains("/linuxbrew/")
    {
        return false;
    }
    // Must be writable (or parent writable for replace).
    path.parent().map(p_writable).unwrap_or(false)
}

fn p_writable(dir: &Path) -> bool {
    let probe = dir.join(format!(".tokenstat-write-{}", std::process::id()));
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
    {
        Ok(_) => {
            let _ = fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// Swap the candidate into place, keeping a rollback until it has proven itself.
///
/// The old binary is moved aside rather than overwritten on every platform, not
/// just Windows. That gives one thing worth having: if the swapped-in binary
/// cannot run from its final location, the previous one goes straight back, so a
/// failed update leaves a working `tokenstat` instead of a hole.
///
/// Renaming over a running executable is allowed on Windows (the loader opens
/// the image with delete/rename sharing) and on Unix (the inode survives while
/// open), so no second process is needed to do the swap. What Windows will not
/// allow is *deleting* the running image, which is why the `.old` cleanup is
/// best-effort here and swept on the next run.
fn replace_executable(src: &Path, dest: &Path) -> Result<(), UpdateError> {
    make_runnable(src)?;
    let staged = dest.with_extension("new");
    let _ = fs::remove_file(&staged);
    fs::copy(src, &staged)?;
    make_runnable(&staged)?;

    let old = dest.with_extension("old");
    let _ = fs::remove_file(&old);
    let had_old = if dest.exists() {
        fs::rename(dest, &old)?;
        true
    } else {
        false
    };

    if let Err(err) = fs::rename(&staged, dest) {
        if had_old {
            let _ = fs::rename(&old, dest);
        }
        let _ = fs::remove_file(&staged);
        return Err(UpdateError::Message(format!(
            "could not move the new binary into {}: {err} (previous binary left in place)",
            dest.display()
        )));
    }

    // Verified from its final path, because that is where it will actually be
    // run from: a wrong permission bit, a signature broken by the move, or a
    // path-sensitive loader problem only shows up here.
    match run_probe(dest, &["--version"], PROBE_TIMEOUT) {
        Ok((true, _)) => {
            let _ = fs::remove_file(&old);
            Ok(())
        }
        other => {
            let detail = match other {
                Ok((_, out)) => out.trim().to_string(),
                Err(e) => e.to_string(),
            };
            if had_old {
                let _ = fs::remove_file(dest);
                let _ = fs::rename(&old, dest);
                return Err(UpdateError::Message(format!(
                    "the new binary did not run once installed, so the previous one was \
                     restored: {detail}"
                )));
            }
            Err(UpdateError::Message(format!(
                "the new binary did not run once installed: {detail}"
            )))
        }
    }
}

fn stamp_path() -> Result<PathBuf, UpdateError> {
    let dir = tokenstat_paths::data_dir()
        .ok_or_else(|| UpdateError::Message("no data directory".into()))?
        .join("cache");
    fs::create_dir_all(&dir)?;
    Ok(dir.join("update-check.stamp"))
}

fn check_stamp_due() -> Result<bool, UpdateError> {
    let path = stamp_path()?;
    match fs::metadata(&path).and_then(|m| m.modified()) {
        Ok(modified) => Ok(modified.elapsed().unwrap_or(CHECK_TTL) >= CHECK_TTL),
        Err(_) => Ok(true),
    }
}

fn touch_check_stamp() -> Result<(), UpdateError> {
    let path = stamp_path()?;
    let mut f = fs::File::create(&path)?;
    writeln!(
        f,
        "{}",
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    fn manifest_fixture() -> serde_json::Value {
        serde_json::json!({ "schema": 1, "checked_at": 1000, "release": {
            "tag_name": "v1.0.4", "html_url": format!("https://github.com/{}/releases/tag/v1.0.4", super::REPO),
            "assets": [{ "name": "SHA256SUMS",
                "browser_download_url": format!("https://github.com/{}/releases/download/v1.0.4/SHA256SUMS", super::REPO),
                "url": format!("https://api.github.com/repos/{}/releases/assets/1", super::REPO)
            }] } })
    }

    #[test]
    fn site_manifest_requires_fresh_stable_allowlisted_release() {
        let valid = manifest_fixture();
        let decode = |value: &serde_json::Value, now| {
            super::validated_manifest(&serde_json::to_vec(value).unwrap(), now)
        };
        assert!(decode(&valid, 1001).is_some());
        assert!(decode(&valid, 1000 + 86_401).is_none());
        assert!(decode(&valid, 699).is_none());
        for (pointer, bad) in [
            ("/schema", serde_json::json!(2)),
            ("/release/prerelease", serde_json::json!(true)),
            ("/release/draft", serde_json::json!(true)),
            ("/release/tag_name", serde_json::json!("v1.0.4-rc.1")),
            (
                "/release/assets/0/browser_download_url",
                serde_json::json!("https://example.org/SHA256SUMS"),
            ),
            (
                "/release/assets/0/url",
                serde_json::json!("https://api.github.com.evil.test/repos/assets/1"),
            ),
            ("/release/assets", serde_json::json!([])),
        ] {
            let mut value = valid.clone();
            // Add optional booleans before addressing them by JSON pointer.
            value["release"]["draft"] = serde_json::json!(false);
            value["release"]["prerelease"] = serde_json::json!(false);
            *value.pointer_mut(pointer).unwrap() = bad;
            assert!(decode(&value, 1001).is_none(), "{pointer}");
        }
    }

    #[test]
    fn release_auth_is_optional_and_targets_only_github_api() {
        let client = super::client().unwrap();
        let anonymous = super::release_request(&client, None).build().unwrap();
        assert!(!anonymous.headers().contains_key("authorization"));
        let authenticated = super::release_request(&client, Some("fixture-token"))
            .build()
            .unwrap();
        assert_eq!(authenticated.url().scheme(), "https");
        assert_eq!(authenticated.url().host_str(), Some("api.github.com"));
        assert_eq!(
            authenticated.headers()["authorization"],
            "Bearer fixture-token"
        );
        assert!(authenticated.headers()["authorization"].is_sensitive());
    }

    #[test]
    fn release_rate_limit_deadlines() {
        use super::release_retry_at;
        use reqwest::header::HeaderMap;
        let mut headers = HeaderMap::new();
        assert_eq!(release_retry_at(403, &headers, 100), None);
        assert_eq!(release_retry_at(429, &headers, 100), Some(160));
        assert!(super::is_rate_limit_message(
            &serde_json::json!({"message": "You have exceeded a secondary rate limit."})
        ));
        assert!(!super::is_rate_limit_message(
            &serde_json::json!({"message": "Resource not accessible"})
        ));
        headers.insert("x-ratelimit-remaining", "0".parse().unwrap());
        headers.insert("x-ratelimit-reset", "500".parse().unwrap());
        assert_eq!(release_retry_at(403, &headers, 100), Some(500));
        assert_eq!(release_retry_at(200, &headers, 100), None);
        headers.insert("retry-after", "600".parse().unwrap());
        assert_eq!(release_retry_at(403, &headers, 100), Some(700));
        headers.remove("x-ratelimit-remaining");
        assert_eq!(release_retry_at(403, &headers, 100), Some(700));
        headers.insert("retry-after", "invalid".parse().unwrap());
        assert_eq!(release_retry_at(429, &headers, 100), Some(160));
    }

    #[test]
    fn release_cooldown_survives_restart_and_expires() {
        let dir =
            std::env::temp_dir().join(format!("tokenstat-update-cooldown-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("retry.stamp");
        super::save_cooldown(&path, 500);
        assert_eq!(super::read_cooldown(&path, 100), Some(500));
        assert_eq!(super::read_cooldown(&path, 500), None);
        super::save_cooldown(&path, 600);
        assert_eq!(super::read_cooldown(&path, 500), Some(600));
        std::fs::write(&path, "invalid").unwrap();
        assert_eq!(super::read_cooldown(&path, 100), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }
    /// The daemon calls this, and its own `current_exe` is the wrong answer.
    ///
    /// Nothing further down would catch the mistake: `verify_candidate` reads a
    /// version number and looks for "tokenstat" in `--help`, and the CLI and
    /// the daemon both satisfy that. The failure would be a daemon path holding
    /// the CLI's bytes, discovered at the next restart.
    #[test]
    fn an_update_may_only_be_pointed_at_the_command_line_tool() {
        use super::require_cli_path;
        use std::path::Path;

        // The binary's own name is platform shaped, so the paths under test
        // have to be as well: a Unix path is the wrong answer on Windows and
        // the test would assert a refusal it never meant.
        let (ok, wrong);
        if cfg!(windows) {
            ok = vec![
                "C:\\Users\\a\\.local\\bin\\tokenstat.exe",
                "C:\\Users\\a\\.local\\bin\\TOKENSTAT.EXE",
            ];
            wrong = vec![
                "C:\\Users\\a\\.local\\bin\\tokenstat-hostd.exe",
                "C:\\Users\\a\\.local\\bin\\tokenstat-hostd",
                "C:\\Users\\a\\.local\\bin\\tokenstat",
                "C:\\Users\\a\\.local\\bin\\",
                "C:\\Users\\a\\.local\\bin\\tokenstatd.exe",
            ];
        } else {
            ok = vec!["/home/a/.local/bin/tokenstat"];
            wrong = vec![
                "/home/a/.local/bin/tokenstat-hostd",
                "/home/a/.local/bin/tokenstat-hostd.exe",
                "/home/a/.local/bin/",
                "/home/a/.local/bin/tokenstatd",
            ];
        }
        for path in ok {
            assert!(require_cli_path(Path::new(path)).is_ok(), "{path}");
        }
        for path in wrong {
            let error = require_cli_path(Path::new(path))
                .expect_err(&format!("{path} must be refused"))
                .to_string();
            assert!(error.contains("refusing to update"), "{path}: {error}");
        }
    }

    use super::*;

    #[test]
    fn newer_release_sorts_above_current() {
        assert_eq!(version_cmp("0.1.0", "0.0.1"), std::cmp::Ordering::Greater);
        assert_eq!(version_cmp("0.0.1", "0.1.0"), std::cmp::Ordering::Less);
        assert_eq!(version_cmp("v1.2.3", "1.2.3"), std::cmp::Ordering::Equal);
    }

    #[test]
    fn oldest_installed_picks_the_lagging_side() {
        // Dev machine: hostd rebuilt past the release, app still on an older
        // bundle. The check must treat the app version as current so the
        // release still looks newer.
        assert_eq!(oldest_installed(&["1.0.2", "1.0.0"]), "1.0.0");
        assert_eq!(oldest_installed(&["0.9.0", "1.2.0"]), "0.9.0");
        assert_eq!(oldest_installed(&["1.0.2", "unknown", ""]), "1.0.2");
        assert_eq!(oldest_installed(&["1.0.2", "1.0.2"]), "1.0.2");
    }

    #[test]
    fn release_outranks_prerelease() {
        assert_eq!(
            version_cmp("0.1.0", "0.1.0-rc.1"),
            std::cmp::Ordering::Greater
        );
    }

    #[test]
    fn parses_sha256sums_line() {
        let sums = "abc123  tokenstat-0.1.0-aarch64-apple-darwin.tar.gz\n";
        assert_eq!(
            expected_sha256(sums, "tokenstat-0.1.0-aarch64-apple-darwin.tar.gz").as_deref(),
            Some("abc123")
        );
    }

    #[test]
    fn sums_matching_is_exact_not_suffix() {
        let asset = "tokenstat-0.1.0-aarch64-apple-darwin.tar.gz";
        // A longer name ending in the asset's must not claim its checksum.
        let evil = format!("abc123  evil-{asset}\n");
        assert_eq!(expected_sha256(&evil, asset), None);
        // Relative paths recorded by sha256sum still resolve to the file.
        for line in [
            format!("abc123  ./{asset}\n"),
            format!("abc123 *{asset}\n"),
            format!("abc123  subdir/{asset}\n"),
        ] {
            assert_eq!(
                expected_sha256(&line, asset).as_deref(),
                Some("abc123"),
                "{line}"
            );
        }
        // A malformed line is skipped, not fatal to the lines after it.
        let mixed = format!("not-a-line\nabc123  {asset}\n");
        assert_eq!(expected_sha256(&mixed, asset).as_deref(), Some("abc123"));
    }

    #[test]
    fn archive_paths_cannot_escape_the_sandbox() {
        use std::path::Path;
        assert!(reject_unsafe_archive_path(Path::new("tokenstat")).is_ok());
        assert!(reject_unsafe_archive_path(Path::new("dir/tokenstat")).is_ok());
        for bad in ["../evil", "dir/../../evil", "/etc/passwd", "/tmp/x", ""] {
            assert!(
                reject_unsafe_archive_path(Path::new(bad)).is_err(),
                "{bad} must be refused"
            );
        }
    }

    #[test]
    #[cfg(unix)]
    fn over_cap_copies_are_refused() {
        let dir = scratch("copy-cap");
        let dest = dir.join("out.bin");
        let mut file = fs::File::create(&dest).unwrap();
        let mut total = 0u64;
        let data = [0u8; 100];
        let err = copy_capped(&data[..], &mut file, 10, &mut total, "probe")
            .expect_err("over-cap copy must fail");
        assert!(err.to_string().contains("extraction limit"), "{err}");
        drop(file);
        let mut file = fs::File::create(&dest).unwrap();
        let mut total = 0u64;
        copy_capped(&data[..], &mut file, 1000, &mut total, "probe").unwrap();
        assert_eq!(total, 100);
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    type TarTestEntry<'a> = (&'a str, Option<&'a [u8]>, Option<&'a str>);

    #[cfg(unix)]
    fn write_tar_gz(path: &Path, entries: &[TarTestEntry<'_>]) {
        // (name, file bytes or None for symlink, link target for symlinks)
        let file = fs::File::create(path).unwrap();
        let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        let mut builder = tar::Builder::new(encoder);
        for (name, data, link) in entries {
            let mut header = tar::Header::new_gnu();
            if let Some(target) = link {
                header.set_entry_type(tar::EntryType::Symlink);
                header.set_link_name(target).unwrap();
                header.set_size(0);
                header.set_cksum();
                builder.append_data(&mut header, name, &[][..]).unwrap();
            } else {
                let bytes = data.unwrap_or(&[]);
                header.set_size(bytes.len() as u64);
                header.set_mode(0o644);
                header.set_cksum();
                builder.append_data(&mut header, name, bytes).unwrap();
            }
        }
        builder.into_inner().unwrap().finish().unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn a_good_tar_gz_extracts_to_the_sandbox() {
        let dir = scratch("tar-good");
        let archive = dir.join("rel.tar.gz");
        write_tar_gz(&archive, &[("inner/tokenstat", Some(b"binary"), None)]);
        let found = extract_binary(&archive, &dir).unwrap();
        assert_eq!(found, dir.join("extract").join("inner").join("tokenstat"));
        assert!(found.is_file());
        // The archive beside the sandbox is untouched and nothing leaked out.
        assert!(archive.is_file());
        assert!(!dir.join("tokenstat").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    fn write_raw_tar_gz(path: &Path, name: &[u8], data: &[u8]) {
        // One hand-built tar entry: the `tar` builder refuses `..` and
        // absolute paths itself, so a hostile archive has to be raw bytes.
        use std::io::Write;
        let mut block = [0u8; 512];
        block[..name.len()].copy_from_slice(name);
        block[100..108].copy_from_slice(b"0000777\0");
        let size = format!("{:011o}\0", data.len());
        block[124..136].copy_from_slice(size.as_bytes());
        block[156] = b'0';
        block[257..262].copy_from_slice(b"ustar");
        block[263..265].copy_from_slice(b"00");
        block[148..156].copy_from_slice(b"        ");
        let sum: u32 = block.iter().map(|b| *b as u32).sum();
        let check = format!("{sum:06o}\0 ");
        block[148..156].copy_from_slice(check.as_bytes());
        let file = fs::File::create(path).unwrap();
        let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        encoder.write_all(&block).unwrap();
        encoder.write_all(data).unwrap();
        let pad = (512 - data.len() % 512) % 512;
        encoder.write_all(&vec![0u8; pad]).unwrap();
        encoder.write_all(&[0u8; 1024]).unwrap();
        encoder.finish().unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn a_hostile_tar_gz_is_refused() {
        for (tag, raw_name) in [
            ("tar-dotdot", b"../evil".as_slice()),
            ("tar-absolute", b"/tmp/tokenstat-evil".as_slice()),
        ] {
            let dir = scratch(tag);
            let archive = dir.join("rel.tar.gz");
            write_raw_tar_gz(&archive, raw_name, b"x");
            let err = extract_binary(&archive, &dir).expect_err(&format!("{tag} must fail"));
            assert!(err.to_string().contains("escapes"), "{tag}: {err}");
            assert!(
                !dir.join("evil").exists(),
                "{tag} wrote outside the sandbox"
            );
            let _ = fs::remove_dir_all(&dir);
        }
        // A symlink pointing outside the sandbox is refused, not followed.
        let dir = scratch("tar-link");
        let archive = dir.join("rel.tar.gz");
        write_tar_gz(&archive, &[("tokenstat", None, Some("/etc/passwd"))]);
        let err = extract_binary(&archive, &dir).expect_err("tar-link must fail");
        assert!(err.to_string().contains("link"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_hostile_zip_is_refused() {
        use std::io::Write;
        for (tag, name) in [
            ("zip-dotdot", "../evil"),
            ("zip-absolute", "/tmp/tokenstat-evil"),
        ] {
            let dir = scratch(tag);
            let archive = dir.join("rel.zip");
            let file = fs::File::create(&archive).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored);
            writer.start_file(name, options).unwrap();
            writer.write_all(b"x").unwrap();
            writer.finish().unwrap();
            let err = extract_binary(&archive, &dir).expect_err(&format!("{tag} must fail"));
            assert!(
                err.to_string().contains("escapes") || err.to_string().contains("directory"),
                "{tag}: {err}"
            );
            let _ = fs::remove_dir_all(&dir);
        }
        // A symlink entry is refused, not written. The writer masks
        // permissions to 0o777, so the link bit is patched into the central
        // directory the way a Unix zip tool would have written it.
        let dir = scratch("zip-link");
        let archive = dir.join("rel.zip");
        let file = fs::File::create(&archive).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        writer.start_file("tokenstat", options).unwrap();
        writer.write_all(b"/etc/passwd").unwrap();
        writer.finish().unwrap();
        let mut bytes = fs::read(&archive).unwrap();
        let at = bytes
            .windows(4)
            .position(|w| w == [0x50, 0x4b, 0x01, 0x02])
            .unwrap();
        bytes[at + 5] = 3; // made by Unix
        let attrs = (0o120777u32) << 16;
        bytes[at + 38..at + 42].copy_from_slice(&attrs.to_le_bytes());
        fs::write(&archive, &bytes).unwrap();
        let err = extract_binary(&archive, &dir).expect_err("zip-link must fail");
        assert!(err.to_string().contains("link"), "{err}");
        assert!(
            !dir.join("extract").join("tokenstat").exists(),
            "the link must not be written"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_good_zip_extracts_to_the_sandbox() {
        use std::io::Write;
        let dir = scratch("zip-good");
        let archive = dir.join("rel.zip");
        let file = fs::File::create(&archive).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        writer.start_file("tokenstat", options).unwrap();
        writer.write_all(b"binary").unwrap();
        writer.finish().unwrap();
        let found = extract_binary(&archive, &dir).unwrap();
        assert_eq!(found, dir.join("extract").join("tokenstat"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn windows_app_zip_is_not_the_cli_zip() {
        assert!(is_windows_app_zip("tokenstat-0.6.8-windows-x64.zip", "x64"));
        assert!(is_windows_app_zip(
            "tokenstat-0.6.8-dev.12.abc1234-windows-x64.zip",
            "x64"
        ));
        assert!(is_windows_app_zip(
            "tokenstat-0.6.8-windows-arm64.zip",
            "arm64"
        ));
        assert!(!is_windows_app_zip(
            "tokenstat-0.6.8-x86_64-pc-windows-msvc.zip",
            "x64"
        ));
        assert!(!is_windows_app_zip(
            "tokenstat-0.6.8-windows-x64.zip.sha256",
            "x64"
        ));
        assert!(!is_windows_app_zip(
            "tokenstat-0.6.8-windows-x64.zip",
            "arm64"
        ));
    }

    /// Write an executable shell script standing in for a candidate binary.
    #[cfg(unix)]
    fn fake_binary(dir: &Path, name: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
        path
    }

    #[cfg(unix)]
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tokenstat-upd-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    #[cfg(unix)]
    fn unix_pair_refuses_missing_or_mismatched_daemon_before_replacing() {
        let dir = scratch("pair-preflight");
        let download = dir.join("download");
        fs::create_dir(&download).unwrap();
        let dest = fake_binary(&dir, "tokenstat", "echo tokenstat 0.1.0");
        let old_host = fake_binary(&dir, "tokenstat-hostd", "echo tokenstat-hostd 0.1.0");
        let candidate = fake_binary(&download, "tokenstat", "echo tokenstat 0.2.0");
        assert!(replace_unix_release(&candidate, &dest, "0.2.0").is_err());
        fake_binary(&download, "tokenstat-hostd", "echo tokenstat-hostd 0.1.0");
        assert!(replace_unix_release(&candidate, &dest, "0.2.0").is_err());
        assert!(fs::read_to_string(&dest).unwrap().contains("0.1.0"));
        assert!(fs::read_to_string(&old_host).unwrap().contains("0.1.0"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn unix_pair_restores_daemon_when_cli_fails_at_final_path() {
        let dir = scratch("pair-rollback");
        let download = dir.join("download");
        fs::create_dir(&download).unwrap();
        let dest = fake_binary(&dir, "tokenstat", "echo tokenstat 0.1.0");
        let old_host = fake_binary(&dir, "tokenstat-hostd", "echo tokenstat-hostd 0.1.0");
        let candidate = fake_binary(&download, "tokenstat", "exit 1");
        fake_binary(&download, "tokenstat-hostd", "echo tokenstat-hostd 0.2.0");
        assert!(replace_unix_release(&candidate, &dest, "0.2.0").is_err());
        assert!(fs::read_to_string(&dest).unwrap().contains("0.1.0"));
        assert!(fs::read_to_string(&old_host).unwrap().contains("0.1.0"));
        fake_binary(&download, "tokenstat", "echo tokenstat 0.2.0");
        replace_unix_release(&candidate, &dest, "0.2.0").unwrap();
        assert!(fs::read_to_string(&dest).unwrap().contains("0.2.0"));
        assert!(fs::read_to_string(&old_host).unwrap().contains("0.2.0"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn a_probe_captures_output_and_exit_status() {
        let dir = scratch("probe");
        let bin = fake_binary(&dir, "ok", "echo tokenstat 9.9.9");
        let (ok, out) = run_probe(&bin, &["--version"], Duration::from_secs(10)).unwrap();
        assert!(ok);
        assert!(out.contains("9.9.9"), "{out}");

        let bad = fake_binary(&dir, "bad", "echo broken >&2; exit 3");
        let (ok, out) = run_probe(&bad, &["--version"], Duration::from_secs(10)).unwrap();
        assert!(!ok);
        assert!(out.contains("broken"), "{out}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_probe_that_hangs_is_killed_rather_than_waited_on() {
        // The whole point of the timeout: a binary that prompts or deadlocks must
        // not park a background job forever.
        let dir = scratch("hang");
        let bin = fake_binary(&dir, "hang", "sleep 30");
        let err = run_probe(&bin, &["--version"], Duration::from_millis(300)).unwrap_err();
        assert!(err.to_string().contains("did not finish"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_candidate_reporting_the_wrong_version_is_refused() {
        // The case this whole gate exists for: the hash matched, so the bytes are
        // the release's, but the build inside is not the version it claims.
        let dir = scratch("mismatch");
        let bin = fake_binary(&dir, "tokenstat", "echo tokenstat 0.0.1");
        let current = fake_binary(&dir, "current", "echo tokenstat 0.0.1");
        let err = verify_candidate(&bin, "0.2.0", &current).unwrap_err();
        assert!(err.to_string().contains("reports 0.0.1"), "{err}");
        assert!(err.to_string().contains("0.2.0"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_candidate_that_cannot_run_is_refused() {
        let dir = scratch("dead");
        let bin = fake_binary(&dir, "tokenstat", "exit 1");
        let current = fake_binary(&dir, "current", "echo tokenstat 0.0.1");
        let err = verify_candidate(&bin, "0.0.1", &current).unwrap_err();
        assert!(err.to_string().contains("failed to run"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_good_candidate_passes_both_probes() {
        let dir = scratch("good");
        let bin = fake_binary(
            &dir,
            "tokenstat",
            r#"case "$1" in --version) echo "tokenstat 0.3.0";; --help) echo "tokenstat usage";; esac"#,
        );
        let current = fake_binary(&dir, "current", "echo tokenstat 0.2.0");
        verify_candidate(&bin, "0.3.0", &current).unwrap();
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_candidate_with_unrecognizable_help_is_refused() {
        let dir = scratch("help");
        let bin = fake_binary(
            &dir,
            "tokenstat",
            r#"case "$1" in --version) echo "tokenstat 0.3.0";; --help) echo "not this tool";; esac"#,
        );
        let current = fake_binary(&dir, "current", "echo tokenstat 0.2.0");
        let err = verify_candidate(&bin, "0.3.0", &current).unwrap_err();
        assert!(err.to_string().contains("unrecognizable"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_broken_swap_restores_the_previous_binary() {
        // The candidate passes preflight but cannot run from its final path.
        // What matters is that `dest` still works afterwards.
        let dir = scratch("rollback");
        let dest = fake_binary(&dir, "tokenstat", "echo tokenstat 0.1.0");
        // A script whose interpreter line is nonsense: runs nowhere.
        let candidate = dir.join("candidate");
        fs::write(&candidate, "#!/nonexistent/interpreter\ntrue\n").unwrap();

        let err = replace_executable(&candidate, &dest).unwrap_err();
        assert!(err.to_string().contains("restored"), "{err}");

        let (ok, out) = run_probe(&dest, &["--version"], Duration::from_secs(10)).unwrap();
        assert!(ok, "the previous binary should still run: {out}");
        assert!(out.contains("0.1.0"), "{out}");
        assert!(!dir.join("tokenstat.old").exists(), "rollback left an .old");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn a_good_swap_installs_and_cleans_up() {
        let dir = scratch("swap");
        let dest = fake_binary(&dir, "tokenstat", "echo tokenstat 0.1.0");
        let candidate = fake_binary(&dir, "candidate", "echo tokenstat 0.2.0");

        replace_executable(&candidate, &dest).unwrap();
        let (ok, out) = run_probe(&dest, &["--version"], Duration::from_secs(10)).unwrap();
        assert!(ok);
        assert!(out.contains("0.2.0"), "{out}");
        assert!(!dir.join("tokenstat.old").exists());
        assert!(!dir.join("tokenstat.new").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn the_update_staging_dir_is_private_and_random() {
        use std::os::unix::fs::PermissionsExt;

        let first = tempfile_dir().unwrap();
        let second = tempfile_dir().unwrap();
        assert_ne!(first, second, "staging names must not be predictable");
        assert_eq!(
            fs::metadata(&first).unwrap().permissions().mode() & 0o777,
            0o700,
            "staging dir must be private"
        );
        let _ = fs::remove_dir_all(&first);
        let _ = fs::remove_dir_all(&second);
    }

    #[test]
    #[cfg(unix)]
    fn a_symlinked_candidate_is_never_returned() {
        let dir = scratch("symlink-candidate");
        let real = fake_binary(&dir, "real", "echo tokenstat 0.2.0");
        std::os::unix::fs::symlink(&real, dir.join("tokenstat")).unwrap();
        let err = find_binary(&dir).unwrap_err();
        assert!(err.to_string().contains("did not contain"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn the_sweep_clears_leftovers_from_a_previous_cycle() {
        let dir = scratch("sweep");
        let dest = dir.join("tokenstat");
        fs::write(&dest, "current").unwrap();
        fs::write(dir.join("tokenstat.old"), "previous").unwrap();
        fs::write(dir.join("tokenstat.new"), "half staged").unwrap();
        sweep_replaced_binary(&dest);
        assert!(!dir.join("tokenstat.old").exists());
        assert!(!dir.join("tokenstat.new").exists());
        assert!(dest.exists(), "the sweep must not touch the binary itself");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn an_ad_hoc_signature_does_not_count_as_an_identity() {
        // The trap this guards: `codesign --verify --strict` passes on an ad-hoc
        // signature, so verifying alone would arm the signature gate on every
        // development machine.
        let dir = scratch("codesign");
        let bin = fake_binary(&dir, "adhoc", "true");
        let signed = Command::new("codesign")
            .args(["--force", "--sign", "-"])
            .arg(&bin)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if signed {
            assert!(
                !has_signing_authority(&bin),
                "ad-hoc signed binary must not report a signing authority"
            );
        }
        // An unsigned file certainly has none.
        let plain = dir.join("plain");
        fs::write(&plain, "not a binary").unwrap();
        assert!(!has_signing_authority(&plain));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_update_jitter_stays_inside_its_window() {
        for _ in 0..20 {
            assert!(update_jitter() < UPDATE_JITTER_WINDOW_SECS);
        }
    }

    #[test]
    fn cargo_path_is_not_safe_to_replace() {
        assert!(!is_safe_replace_path(Path::new(
            "/Users/x/.cargo/bin/tokenstat"
        )));
        assert!(!is_safe_replace_path(Path::new("/usr/bin/tokenstat")));
        assert!(!is_safe_replace_path(Path::new(
            "/opt/homebrew/bin/tokenstat"
        )));
        assert!(!is_safe_replace_path(Path::new(
            "/usr/local/Cellar/tokenstat/0.0.1/bin/tokenstat"
        )));
        assert!(!is_safe_replace_path(Path::new(
            "/home/linuxbrew/.linuxbrew/bin/tokenstat"
        )));
    }

    /// Live check against a Developer ID signed release binary.
    ///
    /// Set `TOKENSTAT_SIGNED_BIN` to the path of a signed `tokenstat` from a
    /// GitHub Release (for example after `gh release download`). Skips when unset.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_signed_install_refuses_an_unsigned_candidate() {
        let Some(current) = signed_release_bin() else {
            return;
        };
        assert!(
            has_signing_authority(&current),
            "TOKENSTAT_SIGNED_BIN must be Developer ID signed: {}",
            current.display()
        );

        let dir = scratch("signed-refuse");
        let candidate = dir.join("unsigned");
        fs::write(&candidate, "#!/bin/sh\necho tokenstat 0.0.1\n").unwrap();
        make_runnable(&candidate).unwrap();

        let err = verify_candidate(&candidate, "0.0.1", &current).unwrap_err();
        assert!(
            err.to_string().contains("failed codesign verification"),
            "{err}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// Rollback must put a signed release back when the staged swap cannot run.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_failed_swap_restores_a_signed_release_binary() {
        let Some(signed) = signed_release_bin() else {
            return;
        };
        assert!(
            has_signing_authority(&signed),
            "TOKENSTAT_SIGNED_BIN must be Developer ID signed: {}",
            signed.display()
        );

        let dir = scratch("signed-rollback");
        let dest = dir.join("tokenstat");
        fs::copy(&signed, &dest).unwrap();
        make_runnable(&dest).unwrap();

        let candidate = dir.join("candidate");
        fs::write(&candidate, "#!/nonexistent/interpreter\ntrue\n").unwrap();

        let err = replace_executable(&candidate, &dest).unwrap_err();
        assert!(err.to_string().contains("restored"), "{err}");

        let (ok, out) = run_probe(&dest, &["--version"], PROBE_TIMEOUT).unwrap();
        assert!(ok, "signed release should still run after rollback: {out}");
        assert!(out.contains("0.0.1"), "{out}");
        assert!(
            has_signing_authority(&dest),
            "rollback must leave the signed binary in place"
        );
        assert!(!dir.join("tokenstat.old").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(target_os = "macos")]
    fn signed_release_bin() -> Option<PathBuf> {
        let path = std::env::var("TOKENSTAT_SIGNED_BIN").ok()?;
        let path = PathBuf::from(path);
        if path.is_file() { Some(path) } else { None }
    }
}
