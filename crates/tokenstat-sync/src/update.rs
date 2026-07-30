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
//! Opt-in auto-apply uses a 24h check stamp so scans stay quiet most of the time.
//! `scheduled_update` is the daily-timer entry point and ignores that stamp,
//! since the schedule is the cadence.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

const REPO: &str = "gyorgysh/tokenstat";
const CHECK_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const USER_AGENT: &str = concat!("tokenstat/", env!("CARGO_PKG_VERSION"));

#[derive(Debug, Error)]
pub enum UpdateError {
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
}

#[derive(Debug, Clone)]
pub struct ApplyReport {
    pub from: String,
    pub to: String,
    pub path: PathBuf,
}

#[derive(Debug, Deserialize)]
struct GhRelease {
    tag_name: String,
    html_url: String,
    #[serde(default)]
    prerelease: bool,
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
pub fn check_latest() -> Result<UpdateCheck, UpdateError> {
    let current = env!("CARGO_PKG_VERSION").to_string();
    let client = client()?;
    let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
    let mut req = client.get(&url);
    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        if !token.is_empty() {
            req = req.header("authorization", format!("Bearer {token}"));
        }
    }
    let resp = req.send()?;
    if resp.status().as_u16() == 404 {
        // Public repo with no release yet is the common case. A private repo
        // without GITHUB_TOKEN looks the same; mention that only as a footnote.
        if github_token().is_none() {
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
        });
    }
    if !resp.status().is_success() {
        return Err(UpdateError::Message(format!(
            "GitHub releases returned {}",
            resp.status()
        )));
    }
    let release: GhRelease = resp.json()?;
    if release.prerelease {
        // /releases/latest already skips prereleases, but be defensive.
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
    })
}

/// A GitHub token from the environment, if one is set and non-empty.
fn github_token() -> Option<String> {
    std::env::var("GITHUB_TOKEN")
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

/// Download a release asset.
///
/// Without a token this is a plain GET of the browser download url, which is what
/// a published release needs. With one, it goes through the API asset endpoint,
/// because `browser_download_url` returns 404 on a private repository however the
/// request is authenticated.
///
/// Redirects are followed by hand rather than by the client, so the token is
/// never sent to the storage host the API redirects to. That host needs no
/// credentials of its own: the signed url is the credential.
fn download_asset(
    client: &reqwest::blocking::Client,
    browser_url: &str,
    api_url: Option<&str>,
) -> Result<Vec<u8>, UpdateError> {
    let Some(token) = github_token() else {
        return Ok(client
            .get(browser_url)
            .send()?
            .error_for_status()?
            .bytes()?
            .to_vec());
    };
    let url = api_url.unwrap_or(browser_url);
    let no_redirect = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent(USER_AGENT)
        .redirect(reqwest::redirect::Policy::none())
        .build()?;

    let resp = no_redirect
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
        return Ok(client
            .get(&location)
            .send()?
            .error_for_status()?
            .bytes()?
            .to_vec());
    }
    Ok(resp.error_for_status()?.bytes()?.to_vec())
}

/// Download, verify, and replace the current executable.
pub fn apply_update() -> Result<ApplyReport, UpdateError> {
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
    let archive_bytes = download_asset(&client, asset_url, check.asset_api_url.as_deref())?;
    let sums_bytes = download_asset(&client, sums_url, check.sums_api_url.as_deref())?;
    let sums_text = String::from_utf8_lossy(&sums_bytes).to_string();
    let expected = expected_sha256(&sums_text, asset_name)
        .ok_or_else(|| UpdateError::Message(format!("SHA256SUMS has no entry for {asset_name}")))?;
    let actual = hex_sha256(&archive_bytes);
    if actual != expected {
        return Err(UpdateError::Message(format!(
            "checksum mismatch for {asset_name}: expected {expected}, got {actual}"
        )));
    }

    let tmp = tempfile_dir()?;
    let archive_path = tmp.join(asset_name);
    fs::write(&archive_path, &archive_bytes)?;
    let extracted = extract_binary(&archive_path, &tmp)?;
    let dest = std::env::current_exe()
        .map_err(|e| UpdateError::Message(format!("cannot locate current binary: {e}")))?;
    if !is_safe_replace_path(&dest) {
        return Err(UpdateError::Message(format!(
            "refusing to replace {} (install via cargo/homebrew, or copy to ~/.local/bin first)",
            dest.display()
        )));
    }
    // A previous cycle may have been unable to delete the binary it replaced
    // (Windows keeps a running image locked against deletion). Clear it now,
    // while nothing is holding it, rather than leaving it forever.
    sweep_replaced_binary(&dest);

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
    verify_candidate(&extracted, &check.latest, &dest)?;

    replace_executable(&extracted, &dest)?;
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("xattr").args(["-cr"]).arg(&dest).status();
    }

    let _ = fs::remove_dir_all(&tmp);
    Ok(ApplyReport {
        from: check.current,
        to: check.latest,
        path: dest,
    })
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
    let dir = tempfile_dir()?;
    // Unique per call: two probes overlapping in one process (the preflight pair,
    // or a caller doing this concurrently) must not read each other's output or
    // delete a file still being written.
    static PROBE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = PROBE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let out_path = dir.join(format!(
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
    let _ = fs::remove_file(&out_path);
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
/// Three questions, in order of how cheaply they fail: does it run at all, is it
/// the version the release claims, and on macOS, is it signed at least as well as
/// what it is replacing.
fn verify_candidate(
    candidate: &Path,
    expect_version: &str,
    current: &Path,
) -> Result<(), UpdateError> {
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

    verify_signature(candidate, current)?;
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
    if !verified || !has_signing_authority(candidate) {
        return Err(UpdateError::Message(
            "the downloaded binary is not signed by a real identity, and the installed one is; \
             refusing to replace a signed binary with an unsigned one"
                .into(),
        ));
    }
    Ok(())
}

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
    touch_check_stamp()?;
    if !check.newer {
        return Ok(Some(UpdateOutcome::UpToDate(check)));
    }
    if auto_apply && is_safe_replace_path(&std::env::current_exe().unwrap_or_default()) {
        let report = apply_update()?;
        return Ok(Some(UpdateOutcome::Applied(report)));
    }
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
    if !auto_apply_enabled() {
        return Ok(ScheduledUpdate::Disabled);
    }
    std::thread::sleep(Duration::from_secs(update_jitter()));

    let check = check_latest()?;
    touch_check_stamp()?;
    if !check.newer {
        return Ok(ScheduledUpdate::UpToDate(check.current));
    }
    let dest = std::env::current_exe().unwrap_or_default();
    if !is_safe_replace_path(&dest) {
        return Ok(ScheduledUpdate::NotOurs {
            latest: check.latest,
            path: dest,
        });
    }
    let report = apply_update()?;
    Ok(ScheduledUpdate::Applied(report))
}

/// Whether auto-apply is enabled (config / env). Default: off (notify only).
pub fn auto_apply_enabled() -> bool {
    if let Ok(v) = std::env::var("TOKENSTAT_AUTO_UPDATE") {
        let v = v.trim().to_ascii_lowercase();
        return matches!(v.as_str(), "1" | "true" | "yes" | "on");
    }
    crate::config::load()
        .ok()
        .and_then(|c| c.update.auto)
        .unwrap_or(false)
}

fn expected_sha256(sums: &str, asset_name: &str) -> Option<String> {
    for line in sums.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // "hash  filename" or "hash *filename"
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let name = parts.next()?.trim_start_matches('*');
        if name == asset_name || name.ends_with(asset_name) {
            return Some(hash.to_ascii_lowercase());
        }
    }
    None
}

fn hex_sha256(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn tempfile_dir() -> Result<PathBuf, UpdateError> {
    let base = std::env::temp_dir().join(format!("tokenstat-update-{}", std::process::id()));
    fs::create_dir_all(&base)?;
    Ok(base)
}

fn extract_binary(archive: &Path, dest_dir: &Path) -> Result<PathBuf, UpdateError> {
    let name = archive.file_name().and_then(|s| s.to_str()).unwrap_or("");
    #[cfg(windows)]
    {
        let _ = name;
        let status = Command::new("powershell")
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "Expand-Archive -LiteralPath '{}' -DestinationPath '{}' -Force",
                    archive.display(),
                    dest_dir.display()
                ),
            ])
            .status()?;
        if !status.success() {
            return Err(UpdateError::Message("failed to extract zip".into()));
        }
    }
    #[cfg(not(windows))]
    {
        if name.ends_with(".tar.gz") || name.ends_with(".tgz") {
            let status = Command::new("tar")
                .args(["-xzf"])
                .arg(archive)
                .arg("-C")
                .arg(dest_dir)
                .status()?;
            if !status.success() {
                return Err(UpdateError::Message("failed to extract tar.gz".into()));
            }
        } else {
            return Err(UpdateError::Message(format!(
                "unsupported archive format: {name}"
            )));
        }
    }
    find_binary(dest_dir)
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
            let p = e.path();
            if p.is_dir() {
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
    let dirs = directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
        .ok_or_else(|| UpdateError::Message("no data directory".into()))?;
    let dir = dirs.data_dir().join("cache");
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
    use super::*;

    #[test]
    fn newer_release_sorts_above_current() {
        assert_eq!(version_cmp("0.1.0", "0.0.1"), std::cmp::Ordering::Greater);
        assert_eq!(version_cmp("0.0.1", "0.1.0"), std::cmp::Ordering::Less);
        assert_eq!(version_cmp("v1.2.3", "1.2.3"), std::cmp::Ordering::Equal);
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
            err.to_string().contains("not signed by a real identity"),
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
