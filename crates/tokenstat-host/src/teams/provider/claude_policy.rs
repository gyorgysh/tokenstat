// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Managed Claude settings outrank --settings and survive an empty
//! --setting-sources. They can execute startup hooks or replace the explicit
//! MCP server. Inspect source presence only; never read managed payloads.

use std::{
    fs, io,
    path::{Path, PathBuf},
};
use unicode_normalization::UnicodeNormalization;

pub(super) fn ensure_unmanaged(home: &Path, native_folder: &Path) -> io::Result<()> {
    let config = super::native_env("CLAUDE_CONFIG_DIR")
        .map(|path| PathBuf::from(path.nfc().collect::<String>()))
        .unwrap_or_else(|| home.join(".claude"));
    let config = if config.is_absolute() {
        config
    } else {
        native_folder.join(config)
    };
    let mut paths = system_paths();
    paths.push(config.join("remote-settings.json"));
    refuse_profile_connection_overrides(&config, native_folder)?;
    #[cfg(target_os = "macos")]
    {
        let username = super::local_username()?;
        paths.push(
            PathBuf::from("/Library/Managed Preferences")
                .join(username)
                .join("com.anthropic.claudecode.plist"),
        );
    }
    refuse_sources(&paths)?;
    #[cfg(windows)]
    refuse_registry()?;
    #[cfg(all(unix, not(target_os = "macos")))]
    refuse_wsl_registry()?;
    Ok(())
}

fn refuse_profile_connection_overrides(config: &Path, folder: &Path) -> io::Result<()> {
    let mut paths = vec![
        config.join("settings.json"),
        config.join("settings.local.json"),
    ];
    for ancestor in folder.ancestors().take(64) {
        paths.extend(
            ["settings.json", "settings.local.json"]
                .map(|name| ancestor.join(".claude").join(name)),
        );
        match fs::symlink_metadata(ancestor.join(".git")) {
            Ok(_) => break,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return Err(unavailable()),
        }
    }
    refuse_connection_overrides(&paths)
}

fn refuse_connection_overrides(paths: &[PathBuf]) -> io::Result<()> {
    use std::io::Read;
    for path in paths {
        match super::startup_source_metadata(path) {
            Ok(None) => continue,
            Ok(Some(metadata)) if metadata.is_file() => {}
            _ => return Err(unavailable()),
        }
        let mut options = fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let file = options.open(path).map_err(|_| unavailable())?;
        if !file.metadata().map_err(|_| unavailable())?.is_file() {
            return Err(unavailable());
        }
        let mut bytes = Vec::new();
        file.take(64 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| unavailable())?;
        if bytes.len() > 64 * 1024 {
            return Err(unavailable());
        }
        let settings: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| unavailable())?;
        let settings = settings.as_object().ok_or_else(unavailable)?;
        // Native auth prefers this helper over cached subscription OAuth.
        // The metadata probe masks callbacks, so refuse the original helper
        // rather than accidentally selecting another cached account.
        if let Some(helper) = settings.get("apiKeyHelper")
            && helper.as_str() != Some("")
        {
            return Err(io::Error::other(
                "Claude API-key helpers cannot be isolated for Team runs. The configured helper has not been executed or replaced with another cached sign-in.",
            ));
        }
        if let Some(environment) = settings.get("env") {
            let environment = environment.as_object().ok_or_else(unavailable)?;
            if environment.keys().any(|key| connection_override(key)) {
                return Err(io::Error::other(
                    "Claude connection or sign-in overrides in personal/project settings cannot be isolated for Team runs. The native CLI environment sign-in and endpoint are supported; personal settings are not imported.",
                ));
            }
        }
    }
    Ok(())
}

fn connection_override(key: &str) -> bool {
    key.starts_with("ANTHROPIC_")
        || key.starts_with("CLAUDE_CODE_USE_")
        || key.starts_with("CLAUDE_CODE_OAUTH_")
        || matches!(
            key,
            "HOME"
                | "USERPROFILE"
                | "CLAUDE_CONFIG_DIR"
                | "CLAUDE_SECURESTORAGE_CONFIG_DIR"
                | "HTTP_PROXY"
                | "HTTPS_PROXY"
                | "ALL_PROXY"
                | "NO_PROXY"
                | "SSL_CERT_FILE"
                | "NODE_EXTRA_CA_CERTS"
        )
}

/// Native status reports cached sign-in metadata without exporting a token or
/// spending a model request. Compare the real profile with the isolated one:
/// stripping a personal provider setting must never switch a run's account.
pub(super) fn admit(
    program: &crate::team_process::Program,
    auth: &super::Auth,
    native_folder: &Path,
) -> io::Result<Mode> {
    if super::native_env("ANTHROPIC_UNIX_SOCKET").is_some_and(|socket| !socket.is_empty()) {
        return Err(io::Error::other(
            "Claude's native Unix-socket provider cannot be isolated for Team runs; its endpoint has not been changed.",
        ));
    }
    let scratch = tempfile::tempdir()?;
    let home = super::super::run_home::prepare(scratch.path(), &program.folder, program)?;
    let executable = program
        .env
        .get("TOKENSTAT_TEAM_CLI_EXECUTABLE")
        .cloned()
        .unwrap_or_else(|| program.executable.display().to_string());
    let mut isolated = program.clone();
    isolated.executable = PathBuf::from(&executable);
    isolated.env.clone_from(&home.env);
    super::configure_with_auth(
        &home,
        &mut isolated,
        &std::env::current_exe()?,
        "claude",
        false,
        auth,
        native_folder,
    )?;
    let mut baseline = isolated.env.clone();
    baseline.remove("CLAUDE_CONFIG_DIR");
    baseline.remove("CLAUDE_SECURESTORAGE_CONFIG_DIR");
    for key in NATIVE_PROFILE_ENV {
        if let Some(value) = super::native_env(key) {
            baseline.insert((*key).into(), value);
        }
    }
    let original = status(&executable, native_folder, &baseline, false)?;
    let mode = original.mode()?;
    let guarded = status(
        &executable,
        &isolated.folder,
        &isolated.env,
        mode == Mode::Bare,
    )?;
    matching_mode(
        &original,
        &guarded,
        auth.environment
            .get("ANTHROPIC_API_KEY")
            .is_some_and(|key| !key.trim().is_empty()),
    )
}

fn matching_mode(original: &Status, guarded: &Status, has_key: bool) -> io::Result<Mode> {
    let mode = original.mode()?;
    if original.auth_method != guarded.auth_method
        || original.provider != guarded.provider
        || original.subscription != guarded.subscription
        || original.key_source != guarded.key_source
    {
        return Err(io::Error::other(
            "Claude's native sign-in or provider changes when personal settings are isolated. This sign-in configuration is not supported for Team runs.",
        ));
    }
    guarded.mode()?;
    if mode == Mode::Bare && !has_key {
        return Err(io::Error::other(
            "Claude Console Team runs currently require the CLI's existing ANTHROPIC_API_KEY environment sign-in. Cached Console keys and API-key helpers cannot be isolated in bare mode.",
        ));
    }
    Ok(mode)
}

// These select the original profile/provider only for the metadata probe.
// Cloud providers are refused explicitly; their credentials are never copied
// into the guarded first-party process.
const NATIVE_PROFILE_ENV: &[&str] = &[
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS",
    "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
    "CLAUDE_CODE_USE_MANTLE",
    "CLAUDE_CODE_USE_GATEWAY",
    "ANTHROPIC_UNIX_SOCKET",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Mode {
    Personal,
    Bare,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    logged_in: bool,
    auth_method: String,
    #[serde(rename = "apiProvider")]
    provider: String,
    #[serde(default, rename = "subscriptionType")]
    subscription: Option<String>,
    #[serde(default, rename = "apiKeySource")]
    key_source: Option<String>,
}

impl Status {
    fn mode(&self) -> io::Result<Mode> {
        if !self.logged_in {
            return Err(io::Error::other(
                "Claude's native CLI is not signed in for this Team run.",
            ));
        }
        if self.provider != "firstParty" {
            return Err(io::Error::other(
                "This Claude CLI uses a cloud provider or gateway that is not yet supported by isolated Team runs. Its native provider has not been changed.",
            ));
        }
        match self.auth_method.as_str() {
            "claude.ai" if matches!(self.subscription.as_deref(), Some("pro" | "max")) => {
                Ok(Mode::Personal)
            }
            "api_key" if self.key_source.as_deref() == Some("ANTHROPIC_API_KEY") => Ok(Mode::Bare),
            _ => Err(io::Error::other(
                "This Claude sign-in can receive organization startup policy, or its personal subscription could not be verified. Team runs support native personal Pro/Max sign-ins and ANTHROPIC_API_KEY sign-ins in bare mode; this sign-in cannot be isolated safely.",
            )),
        }
    }
}

fn status_unavailable() -> io::Error {
    io::Error::other(
        "Claude's native sign-in metadata could not be verified for this isolated Team run.",
    )
}

fn status(
    executable: &str,
    folder: &Path,
    environment: &std::collections::BTreeMap<String, String>,
    bare: bool,
) -> io::Result<Status> {
    use std::{
        io::Read,
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let mut args = vec![
        "--settings".into(),
        // auth status normally retrieves apiKeyHelper. A metadata preflight
        // must not execute that user callback, even in the original profile.
        r#"{"apiKeyHelper":""}"#.into(),
        "auth".into(),
        "status".into(),
        "--json".into(),
    ];
    if bare {
        args.insert(0, "--bare".into());
    }
    let (executable, args) = super::invocation(executable, &args)?;
    let mut command = Command::new(executable);
    command
        .env_clear()
        .envs(
            environment
                .iter()
                .filter(|(key, _)| !key.starts_with("TOKENSTAT_TEAM_")),
        )
        .current_dir(folder)
        .env("PWD", folder)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|_| status_unavailable())?;
    let stdout = child.stdout.take().ok_or_else(status_unavailable)?;
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take(16 * 1024 + 1).read_to_end(&mut bytes);
        let _ = send.send(
            result
                .ok()
                .filter(|_| bytes.len() <= 16 * 1024)
                .map(|_| bytes),
        );
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    let code = loop {
        match child.try_wait() {
            Ok(Some(code)) => break Some(code),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(25)),
            _ => break None,
        }
    };
    let bytes = code
        .filter(|code| code.success())
        .and_then(|_| {
            receive
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .ok()
        })
        .flatten();
    // A launcher retaining the output pipe must not leave helpers behind on
    // failure. No metadata, including account identifiers, is logged.
    #[cfg(unix)]
    if bytes.is_none() {
        unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL) };
    }
    #[cfg(windows)]
    if bytes.is_none() {
        let _ = Command::new("taskkill")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    if bytes.is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
    serde_json::from_slice(&bytes.ok_or_else(status_unavailable)?).map_err(|_| status_unavailable())
}

fn system_paths() -> Vec<PathBuf> {
    #[cfg(target_os = "macos")]
    let directory = Path::new("/Library/Application Support/ClaudeCode");
    #[cfg(windows)]
    let directory = Path::new(r"C:\Program Files\ClaudeCode");
    #[cfg(not(any(target_os = "macos", windows)))]
    let directory = Path::new("/etc/claude-code");
    #[cfg_attr(windows, allow(unused_mut))]
    let mut paths = [
        "managed-settings.json",
        "managed-settings.d",
        "managed-mcp.json",
    ]
    .map(|name| directory.join(name))
    .to_vec();
    #[cfg(target_os = "macos")]
    paths.push(PathBuf::from(
        "/Library/Managed Preferences/com.anthropic.claudecode.plist",
    ));
    #[cfg(all(unix, not(target_os = "macos")))]
    paths.extend(
        [
            "managed-settings.json",
            "managed-settings.d",
            "managed-mcp.json",
        ]
        .map(|name| Path::new("/mnt/c/Program Files/ClaudeCode").join(name)),
    );
    paths
}

fn refuse_sources(paths: &[PathBuf]) -> io::Result<()> {
    for path in paths {
        match super::startup_source_metadata(path) {
            Ok(None) => {}
            Err(_) => return Err(unavailable()),
            Ok(Some(_)) => return Err(managed()),
        }
    }
    Ok(())
}

fn managed() -> io::Error {
    io::Error::other(
        "Claude managed startup settings can load hooks or MCP servers before the Team guard. This configuration cannot be isolated for a Team run.",
    )
}
fn unavailable() -> io::Error {
    io::Error::other(
        "Claude managed startup settings could not be checked for this isolated Team run.",
    )
}

#[cfg(windows)]
fn refuse_registry() -> io::Result<()> {
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn RegOpenKeyExW(
            key: isize,
            subkey: *const u16,
            options: u32,
            access: u32,
            result: *mut isize,
        ) -> i32;
        fn RegCloseKey(key: isize) -> i32;
    }
    let path = "SOFTWARE\\Policies\\ClaudeCode\0"
        .encode_utf16()
        .collect::<Vec<_>>();
    for hive in [0x80000002u32, 0x80000001u32] {
        for view in [0x0100, 0x0200] {
            let mut key = 0;
            let status = unsafe {
                RegOpenKeyExW(
                    hive as i32 as isize,
                    path.as_ptr(),
                    0,
                    0x20019 | view,
                    &mut key,
                )
            };
            if status == 0 {
                unsafe { RegCloseKey(key) };
            }
            registry_status(status as u32)?;
        }
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn registry_status(status: u32) -> io::Result<()> {
    match status {
        2 | 3 => Ok(()),
        0 => Err(managed()),
        _ => Err(unavailable()),
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn refuse_wsl_registry() -> io::Result<()> {
    // WSL can opt into the Windows policy chain. Query only key existence
    // through the native registry API; neither values nor profiles are read.
    let bridge = Path::new("/mnt/c/Windows/System32/reg.exe");
    match fs::symlink_metadata(bridge) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(unavailable()),
        Ok(_) => {}
    }
    let script = r#"try { foreach($h in @([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryHive]::CurrentUser)) { foreach($v in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) { $b=[Microsoft.Win32.RegistryKey]::OpenBaseKey($h,$v); try { $k=$b.OpenSubKey('SOFTWARE\Policies\ClaudeCode',$false); if($null -ne $k) { $k.Dispose(); exit 1 } } finally { $b.Dispose() } } }; exit 0 } catch { exit 1 }"#;
    let result = crate::agent_models::run_cli_probe(
        "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
        &["-NoProfile", "-NonInteractive", "-Command", script],
        std::time::Duration::from_secs(5),
        4096,
        None,
        &[],
    )
    .ok_or_else(unavailable)?;
    if result.success {
        Ok(())
    } else {
        Err(unavailable())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn metadata(
        method: &str,
        subscription: Option<&str>,
        provider: &str,
        source: Option<&str>,
    ) -> Status {
        serde_json::from_value(serde_json::json!({
            "loggedIn":true, "authMethod":method, "apiProvider":provider,
            "subscriptionType":subscription,"apiKeySource":source,
        }))
        .unwrap()
    }

    #[test]
    fn native_auth_metadata_allows_only_known_personal_or_env_key_modes() {
        for subscription in ["pro", "max"] {
            let status = metadata("claude.ai", Some(subscription), "firstParty", None);
            assert_eq!(
                matching_mode(&status, &status, false).unwrap(),
                Mode::Personal
            );
        }
        let key = metadata("api_key", None, "firstParty", Some("ANTHROPIC_API_KEY"));
        assert_eq!(matching_mode(&key, &key, true).unwrap(), Mode::Bare);
        assert!(matching_mode(&key, &key, false).is_err());
        for subscription in [Some("team"), Some("enterprise"), Some("unknown"), None] {
            assert!(
                metadata("claude.ai", subscription, "firstParty", None)
                    .mode()
                    .is_err()
            );
        }
        for method in ["oauth_token", "api_key_helper", "none", "future"] {
            assert!(
                metadata(method, Some("pro"), "firstParty", None)
                    .mode()
                    .is_err()
            );
        }
        for provider in [
            "bedrock",
            "vertex",
            "foundry",
            "anthropicAws",
            "anthropicGoogleCloud",
            "mantle",
            "gateway",
            "unknown",
        ] {
            assert!(
                metadata("api_key", None, provider, Some("ANTHROPIC_API_KEY"))
                    .mode()
                    .is_err()
            );
        }
        let pro = metadata("claude.ai", Some("pro"), "firstParty", None);
        let max = metadata("claude.ai", Some("max"), "firstParty", None);
        assert!(matching_mode(&pro, &max, false).is_err());
        assert!(matching_mode(&pro, &key, true).is_err());
        assert!(
            metadata("api_key", None, "firstParty", Some("/login managed key"))
                .mode()
                .is_err()
        );
    }

    #[test]
    fn api_key_helpers_are_refused_before_masked_status_can_select_cached_oauth() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        let paths = [path.clone()];
        // Matching masked native status alone would admit this cached Pro
        // account even though a real invocation would prefer its helper.
        let cached = metadata("claude.ai", Some("pro"), "firstParty", None);
        assert_eq!(
            matching_mode(&cached, &cached, false).unwrap(),
            Mode::Personal
        );
        for helper in [
            serde_json::json!("printf fictional-helper-key"),
            serde_json::json!(" "),
            serde_json::Value::Null,
            serde_json::json!(false),
            serde_json::json!({"unknown":"format"}),
            serde_json::json!([]),
        ] {
            fs::write(
                &path,
                serde_json::json!({"apiKeyHelper":helper}).to_string(),
            )
            .unwrap();
            assert!(refuse_connection_overrides(&paths).is_err());
        }
        fs::write(&path, r#"{"apiKeyHelper":""}"#).unwrap();
        assert!(refuse_connection_overrides(&paths).is_ok());
        fs::write(&path, "{}").unwrap();
        assert!(refuse_connection_overrides(&paths).is_ok());
    }

    #[test]
    fn settings_connection_overrides_and_unknown_files_cannot_change_auth_routing() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("settings.json");
        let paths = [path.clone()];
        assert!(refuse_connection_overrides(&paths).is_ok());
        fs::write(&path, r#"{"env":{"UNRELATED_VALUE":"fixture"}}"#).unwrap();
        assert!(refuse_connection_overrides(&paths).is_ok());
        for key in [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR",
            "HTTPS_PROXY",
        ] {
            fs::write(
                &path,
                serde_json::json!({"env":{key:"fictional value"}}).to_string(),
            )
            .unwrap();
            assert!(refuse_connection_overrides(&paths).is_err(), "{key}");
        }
        for invalid in ["not JSON".to_owned(), "[]".to_owned(), "x".repeat(65537)] {
            fs::write(&path, invalid).unwrap();
            assert!(refuse_connection_overrides(&paths).is_err());
        }
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(refuse_connection_overrides(&paths).is_err());
        #[cfg(unix)]
        {
            fs::remove_dir(&path).unwrap();
            std::os::unix::fs::symlink(root.path().join("absent"), &path).unwrap();
            assert!(refuse_connection_overrides(&paths).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn metadata_probe_is_bounded_and_excludes_run_capabilities() {
        use std::{collections::BTreeMap, os::unix::fs::PermissionsExt};
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("native-cli");
        let env = BTreeMap::from([
            ("PATH".into(), "/usr/bin:/bin".into()),
            (
                "TOKENSTAT_TEAM_SDK_TOKEN".into(),
                "fictional capability".into(),
            ),
            (
                "TOKENSTAT_TEAM_SDK_ADDRESS".into(),
                "fictional address".into(),
            ),
            ("TOKENSTAT_TEAM_SDK_GENERATION".into(), "17".into()),
        ]);
        fs::write(&executable, r#"#!/bin/sh
[ -z "$TOKENSTAT_TEAM_SDK_TOKEN$TOKENSTAT_TEAM_SDK_ADDRESS$TOKENSTAT_TEAM_SDK_GENERATION" ] || exit 2
[ "$1" = --bare ] || exit 3
[ "$2" = --settings ] || exit 4
[ "$3" = '{"apiKeyHelper":""}' ] || exit 5
[ "$4 $5 $6" = 'auth status --json' ] || exit 6
printf '%s' '{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","apiKeySource":"ANTHROPIC_API_KEY"}'
"#).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            status(executable.to_str().unwrap(), root.path(), &env, true)
                .unwrap()
                .mode()
                .unwrap(),
            Mode::Bare
        );
        fs::write(&executable, "#!/bin/sh\nprintf '%17000s' ''\n").unwrap();
        assert!(status(executable.to_str().unwrap(), root.path(), &env, false).is_err());
        fs::write(
            &executable,
            "#!/bin/sh\nprintf '%s' '{unrecognized metadata}'\n",
        )
        .unwrap();
        assert!(status(executable.to_str().unwrap(), root.path(), &env, false).is_err());
    }

    #[test]
    fn managed_sources_are_checked_by_presence_without_reading_payloads() {
        let root = tempfile::tempdir().unwrap();
        let paths = [
            "managed-settings.json",
            "managed-settings.d",
            "managed-mcp.json",
            "com.anthropic.claudecode.plist",
            "remote-settings.json",
        ]
        .map(|name| root.path().join(name));
        assert!(refuse_sources(&paths).is_ok());
        for path in &paths {
            fs::write(path, "not a valid payload: presence alone must refuse").unwrap();
            assert!(refuse_sources(&paths).is_err());
            fs::remove_file(path).unwrap();
        }
        fs::create_dir(&paths[1]).unwrap();
        assert!(refuse_sources(&paths).is_err());
        fs::remove_dir(&paths[1]).unwrap();
        let parent = root.path().join("not-a-directory");
        fs::write(&parent, "").unwrap();
        assert!(refuse_sources(&[parent.join("policy")]).is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.path().join("absent"), &paths[0]).unwrap();
            assert!(refuse_sources(&paths).is_err());
        }
    }
    #[test]
    fn registry_policy_presence_and_lookup_failures_refuse() {
        assert!(registry_status(2).is_ok());
        assert!(registry_status(3).is_ok());
        assert!(registry_status(0).is_err());
        assert!(registry_status(5).is_err());
    }
}
