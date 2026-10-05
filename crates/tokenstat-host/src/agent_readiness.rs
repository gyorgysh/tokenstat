// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Whether an agent on this machine can actually start work.
//!
//! Installed and signed in are two different facts, and the launcher only ever
//! knew the first. A fresh server with `claude` on its PATH and no login looks
//! ready in every list until somebody sends a prompt and reads an auth error,
//! which is the worst possible moment to find out.
//!
//! The only evidence used here is the agent's own credential store, on disk,
//! where that tool put it. Never a running process, never terminal output, and
//! never the presence of the executable: those say nothing about a login. The
//! file's *contents* are not read as credentials either. Presence, and an
//! expiry timestamp where the format carries one in the clear, is all that
//! leaves this module. No token, path or file body reaches a caller.
//!
//! Where nothing can be checked the answer is `unknown`, in words. Reporting
//! "signed out" for a tool this machine cannot inspect would send somebody to
//! redo a sign-in that was fine, and reporting "signed in" would be the same
//! lie in the other direction.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use tokenstat_sync::discover::cursor_auth_file;

/// What the front end may say about an agent, and what it may offer next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Readiness {
    /// The command is not on this machine.
    NotInstalled,
    /// Installed, and its credential store is not there. A sign-in is the
    /// next step, and this is the one negative answer worth acting on.
    NeedsSignIn,
    /// Installed, with a stored login this machine can see.
    SignedIn,
    /// Installed, with a stored login whose own expiry has passed.
    Expired,
    /// Installed, and nothing here can tell. Say so rather than guess.
    Unknown,
}

impl Readiness {
    fn id(self) -> &'static str {
        match self {
            Self::NotInstalled => "notInstalled",
            Self::NeedsSignIn => "needsSignIn",
            Self::SignedIn => "signedIn",
            Self::Expired => "expired",
            Self::Unknown => "unknown",
        }
    }
}

/// Where one agent keeps its own login, relative to the user's home.
///
/// Every entry was taken from code in this repository that already reads that
/// tool's files, not from a guess at a convention. A tool with no verified
/// location is deliberately absent: it gets `unknown` and honest words.
struct Store {
    id: &'static str,
    /// Candidate paths under `$HOME`, in the order the tool prefers them.
    paths: &'static [&'static str],
    /// An environment variable that relocates the tool's whole home, if it has
    /// one. Read from this daemon's environment, which is the environment the
    /// agent is spawned with, so it is the same answer the agent would get.
    home_var: Option<(&'static str, &'static str)>,
    /// Reads an expiry in milliseconds since the epoch out of the store, when
    /// the format states one in the clear. `None` where it does not.
    expiry: Option<fn(&str) -> Option<i64>>,
    /// Whether a Mac keeps this login somewhere other than a file, so a
    /// missing file there is "cannot tell" rather than "signed out".
    keychain_on_macos: bool,
}

const STORES: &[Store] = &[
    Store {
        id: "claude_code",
        paths: &[".claude/.credentials.json"],
        home_var: Some(("CLAUDE_CONFIG_DIR", ".credentials.json")),
        expiry: Some(claude_expiry),
        keychain_on_macos: true,
    },
    Store {
        id: "codex",
        paths: &[".codex/auth.json"],
        home_var: Some(("CODEX_HOME", "auth.json")),
        expiry: None,
        keychain_on_macos: false,
    },
    Store {
        id: "grok",
        paths: &[".grok/auth.json"],
        home_var: None,
        expiry: None,
        keychain_on_macos: false,
    },
    // opencode is deliberately absent. Its free models work with no login at
    // all, so a missing credentials file says nothing about whether it can
    // answer, and reading it as "needs sign-in" would send somebody to set up
    // an account they do not need.
];

/// Claude Code writes its OAuth expiry as milliseconds, in the clear, beside
/// the tokens. Only that number is taken.
fn claude_expiry(raw: &str) -> Option<i64> {
    serde_json::from_str::<Value>(raw)
        .ok()?
        .get("claudeAiOauth")?
        .get("expiresAt")?
        .as_i64()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_millis() as i64)
        .unwrap_or_default()
}

/// How one agent signs in, when its own documented flow works in a terminal on
/// a machine with no browser.
///
/// A sign-in that needs a browser callback landing on *this* server is not one
/// of these. The person's browser is on the device in their hand, the callback
/// would arrive on the server's own loopback, and offering the flow anyway would
/// end in a page that never loads. Only flows that print something to copy are
/// here.
pub(crate) struct SignIn {
    id: &'static str,
    /// Arguments appended to the agent's own command. The command itself comes
    /// from the launcher's hardcoded table, so nothing here is caller-supplied.
    pub(crate) args: &'static [&'static str],
    /// What the person is about to see, so a screen can say it in advance
    /// rather than leaving them to work out what the terminal wants.
    kind: &'static str,
}

const SIGN_INS: &[SignIn] = &[
    // The dedicated login command also works when renewing an existing login.
    // The CLI owns browser authorization and any code pasted back into its PTY.
    SignIn {
        id: "claude_code",
        args: &["auth", "login"],
        kind: "browserCode",
    },
    // Codex's own answer for a machine with no browser. It prints a URL and a
    // one-time code; the browser can be anywhere, including the device running
    // this app.
    SignIn {
        id: "codex",
        args: &["login", "--device-auth"],
        kind: "deviceCode",
    },
    // Cursor's CLI login is a link that the CLI then polls for, with no
    // callback to this machine's loopback, so the browser can be on any
    // device. It opens one itself when it can and prints the link either way.
    SignIn {
        id: "cursor_agent",
        args: &["login"],
        kind: "browserCode",
    },
    // Muse signs in to a Meta account with a device code: it prints a page
    // and a code like `ABCD-EFGH`, then waits for the browser to approve it.
    SignIn {
        id: "muse",
        args: &["login"],
        kind: "deviceCode",
    },
];

pub(crate) fn sign_in(id: &str) -> Option<&'static SignIn> {
    SIGN_INS.iter().find(|flow| flow.id == id)
}

/// The readiness of one agent id, given whether the launcher found its command.
pub(crate) fn readiness(id: &str, installed: bool) -> (Readiness, Option<i64>) {
    let uses_launch_environment = matches!(id, "cursor_agent" | "muse");
    let home = if uses_launch_environment {
        launch_home_dir()
    } else {
        home_dir()
    };
    match home {
        Some(home) => readiness_in(
            id,
            installed,
            &home,
            now_ms(),
            if uses_launch_environment {
                &from_launch_environment
            } else {
                &from_environment
            },
        ),
        // No home to look in is not evidence either way.
        None if installed => (Readiness::Unknown, None),
        None => (Readiness::NotInstalled, None),
    }
}

/// A tool's own relocation variable, as this daemon sees it.
///
/// Passed in rather than read where it is used, because a test that supplies a
/// home directory has to be able to supply the whole answer. Reading the
/// process environment half way down made the result depend on whether the
/// machine running the tests happened to export `CLAUDE_CONFIG_DIR`.
fn from_environment(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from)
}

/// Cursor and Muse run with the captured login shell's variables over the
/// daemon's environment. Match that overlay without waiting on a catalog read.
fn launch_environment(
    var: &str,
    login: Option<&tokenstat_pty::LoginEnv>,
    process: &dyn Fn(&str) -> Option<PathBuf>,
) -> Option<PathBuf> {
    login
        .and_then(|login| login.vars.get(var))
        .map(PathBuf::from)
        .or_else(|| process(var))
}

fn from_launch_environment(var: &str) -> Option<PathBuf> {
    let login = tokenstat_pty::login_env();
    launch_environment(var, login.as_deref(), &from_environment)
}

fn launch_home_dir() -> Option<PathBuf> {
    from_launch_environment("HOME")
        .filter(|home| !home.as_os_str().is_empty())
        .or_else(home_dir)
}

/// The same decision against a given home, clock and environment, so it can be
/// tested without touching the machine running the tests.
fn readiness_in(
    id: &str,
    installed: bool,
    home: &Path,
    now: i64,
    env: &dyn Fn(&str) -> Option<PathBuf>,
) -> (Readiness, Option<i64>) {
    if !installed {
        return (Readiness::NotInstalled, None);
    }
    // A catalog read never asks the keychain. That spawns `security`, which
    // can wait behind an access prompt, so on a Mac this stays `unknown` until
    // an explicit check (`describe_checked`) asks.
    if id == "cursor_agent" {
        return cursor_agent_readiness(home, now, env, &|| KeychainAnswer::Unreadable);
    }
    if id == "muse" {
        return muse_readiness(home, env);
    }
    let Some(store) = STORES.iter().find(|store| store.id == id) else {
        return (Readiness::Unknown, None);
    };
    let Some(path) = existing_store(store, home, env) else {
        if store.keychain_on_macos && cfg!(target_os = "macos") {
            return (Readiness::Unknown, None);
        }
        // Codex can be configured to keep its login in the system keyring
        // instead of a file. Then a missing file says nothing at all.
        if id == "codex" && codex_uses_keyring(home, env) {
            return (Readiness::Unknown, None);
        }
        return (Readiness::NeedsSignIn, None);
    };
    // An empty or unreadable file is not a login, but it is not proof of one
    // being absent either: a half-written store is a state a person should be
    // told about rather than sent to sign in over.
    let Ok(raw) = read_store(&path) else {
        return (Readiness::Unknown, None);
    };
    // A partially written or empty JSON store is not positive evidence of
    // a saved login. This still describes local storage, not online validity.
    if !serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|value| value.as_object().map(|fields| !fields.is_empty()))
        .unwrap_or(false)
    {
        return (Readiness::Unknown, None);
    }
    match store.expiry.and_then(|read| read(&raw)) {
        Some(expires) if expires <= now => (Readiness::Expired, Some(expires)),
        Some(expires) => (Readiness::SignedIn, Some(expires)),
        None => (Readiness::SignedIn, None),
    }
}

/// What the macOS keychain holds for the Cursor CLI.
enum KeychainAnswer {
    /// The stored tokens, possibly none.
    #[cfg(any(target_os = "macos", test))]
    Found(Vec<String>),
    /// A stored API key can obtain fresh tokens after both JWTs expire.
    #[cfg(target_os = "macos")]
    ApiKey,
    /// The keychain could not be asked. Not evidence either way.
    Unreadable,
}

/// Cursor's CLI keeps its login in the macOS keychain unless
/// `AGENT_CLI_CREDENTIAL_STORE=file` says otherwise, and in an `auth.json`
/// under its config directory everywhere else. Both hold JWTs whose expiry is
/// in the clear, and only that number is taken.
///
/// The CLI's own `status` command is no help here: with every token expired it
/// still printed "Login successful" while each run was refused with
/// "Authentication required". A stored expiry is the better witness.
fn cursor_agent_readiness(
    home: &Path,
    now: i64,
    env: &dyn Fn(&str) -> Option<PathBuf>,
    keychain: &dyn Fn() -> KeychainAnswer,
) -> (Readiness, Option<i64>) {
    // A key in the environment is a login with no file and no expiry.
    if ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]
        .iter()
        .any(|var| env(var).is_some_and(|key| !key.as_os_str().is_empty()))
    {
        return (Readiness::SignedIn, None);
    }
    let store = env("AGENT_CLI_CREDENTIAL_STORE");
    // Memory mode ignores any saved login. A separate CLI sign-in process
    // cannot leave credentials for a future turn, so file/keychain evidence
    // cannot establish readiness here.
    if store.as_deref() == Some(Path::new("memory")) {
        return (Readiness::Unknown, None);
    }
    let file_store = store.as_deref() == Some(Path::new("file"));
    let tokens: Vec<String> = if cfg!(target_os = "macos") && !file_store {
        match keychain() {
            #[cfg(any(target_os = "macos", test))]
            KeychainAnswer::Found(tokens) => tokens,
            #[cfg(target_os = "macos")]
            KeychainAnswer::ApiKey => return (Readiness::SignedIn, None),
            KeychainAnswer::Unreadable => return (Readiness::Unknown, None),
        }
    } else {
        let path = cursor_auth_file(home, env);
        let raw = match read_store(&path) {
            Ok(raw) => raw,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return (Readiness::NeedsSignIn, None);
            }
            Err(_) => return (Readiness::Unknown, None),
        };
        let Ok(value) = serde_json::from_str::<Value>(&raw) else {
            return (Readiness::Unknown, None);
        };
        if value
            .get("apiKey")
            .and_then(Value::as_str)
            .is_some_and(|key| !key.is_empty())
        {
            return (Readiness::SignedIn, None);
        }
        ["accessToken", "refreshToken"]
            .iter()
            .filter_map(|key| value.get(*key)?.as_str().map(str::to_string))
            .filter(|token| !token.is_empty())
            .collect()
    };
    if tokens.is_empty() {
        return (Readiness::NeedsSignIn, None);
    }
    // The refresh token can renew the access token, so the login lasts as long
    // as the later of the two.
    let expires = tokens
        .iter()
        .filter_map(|token| tokenstat_sync::discover::jwt_expiry(token))
        .max()
        .map(|seconds| seconds.saturating_mul(1000));
    match expires {
        Some(expires) if expires <= now => (Readiness::Expired, Some(expires)),
        Some(expires) => (Readiness::SignedIn, Some(expires)),
        None => (Readiness::SignedIn, None),
    }
}

/// Muse records which provider it is signed in to in `auth.json`, and keeps
/// the token itself in the keychain. The record is the evidence: an entry for
/// `meta`, the provider a chat turn starts with, is a login. The file holds no
/// expiry, so none is reported.
fn muse_readiness(home: &Path, env: &dyn Fn(&str) -> Option<PathBuf>) -> (Readiness, Option<i64>) {
    if env("META_API_KEY").is_some_and(|key| !key.as_os_str().is_empty()) {
        return (Readiness::SignedIn, None);
    }
    let config_home = env("XDG_CONFIG_HOME");
    let Some(directory) =
        crate::chat_gate::muse_config_directory(config_home.as_deref(), Some(home))
    else {
        return (Readiness::Unknown, None);
    };
    let raw = match read_store(&directory.join("auth.json")) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (Readiness::NeedsSignIn, None);
        }
        Err(_) => return (Readiness::Unknown, None),
    };
    let Ok(value) = serde_json::from_str::<Value>(&raw) else {
        return (Readiness::Unknown, None);
    };
    match value.pointer("/providers/meta").and_then(Value::as_object) {
        Some(entry) if !entry.is_empty() => (Readiness::SignedIn, None),
        _ => (Readiness::NeedsSignIn, None),
    }
}

/// Ask the login keychain for the CLI's login items, through the same lookup the
/// limits read uses. A missing item is an answer. A keychain that cannot be
/// asked is not.
fn cursor_keychain() -> KeychainAnswer {
    #[cfg(target_os = "macos")]
    {
        use tokenstat_sync::discover::{KeychainItem, keychain_item};
        match keychain_item("cursor-api-key", "cursor-user") {
            KeychainItem::Found(key) if !key.is_empty() => return KeychainAnswer::ApiKey,
            KeychainItem::Unreadable => return KeychainAnswer::Unreadable,
            _ => {}
        }
        let mut tokens = Vec::new();
        for service in ["cursor-access-token", "cursor-refresh-token"] {
            match keychain_item(service, "cursor-user") {
                KeychainItem::Found(token) => tokens.push(token),
                KeychainItem::Missing => {}
                KeychainItem::Unreadable => return KeychainAnswer::Unreadable,
            }
        }
        KeychainAnswer::Found(tokens)
    }
    #[cfg(not(target_os = "macos"))]
    {
        KeychainAnswer::Unreadable
    }
}

/// Codex's `cli_auth_credentials_store` decides where its login lives. Only
/// `file` guarantees the file this module looks for.
fn codex_uses_keyring(home: &Path, env: &dyn Fn(&str) -> Option<PathBuf>) -> bool {
    let config = match env("CODEX_HOME") {
        Some(dir) => dir.join("config.toml"),
        None => home.join(".codex/config.toml"),
    };
    let raw = match read_store(&config) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return false,
        // Unreadable configuration cannot prove that credentials belong in
        // a file. Keep readiness unknown instead of prompting another login.
        Err(_) => return true,
    };
    raw.lines()
        .map(str::trim)
        .filter(|line| line.starts_with("cli_auth_credentials_store"))
        .any(|line| line.contains("keyring") || line.contains("auto"))
}

/// Credential/config inspection is small even if a broken tool writes a huge
/// file. Enforce the limit on the reader, including files growing during read.
fn read_store(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    const MAX_BYTES: u64 = 1024 * 1024;
    let mut raw = String::new();
    std::fs::File::open(path)?
        .take(MAX_BYTES + 1)
        .read_to_string(&mut raw)?;
    if raw.len() as u64 > MAX_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "agent configuration exceeds the inspection limit",
        ));
    }
    Ok(raw)
}

fn existing_store(
    store: &Store,
    home: &Path,
    env: &dyn Fn(&str) -> Option<PathBuf>,
) -> Option<PathBuf> {
    if let Some((var, file)) = store.home_var
        && let Some(dir) = env(var)
    {
        let candidate = dir.join(file);
        return candidate.is_file().then_some(candidate);
    }
    store
        .paths
        .iter()
        .map(|relative| home.join(relative))
        .find(|candidate| candidate.is_file())
}

fn home_dir() -> Option<PathBuf> {
    directories::UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

/// One agent's readiness, as the wire shape every front end reads.
///
/// `signedIn` stays for older clients and keeps its old meaning: true, false,
/// or null where nothing can be checked. `readiness` is the answer with the
/// states a screen actually needs.
pub(crate) fn describe(id: &str, installed: bool) -> Value {
    let (state, expires) = readiness(id, installed);
    wire(id, state, expires)
}

/// `describe` for an explicit sign-in check of an installed agent, which may
/// also read evidence a catalog read must not wait on: the macOS keychain.
pub(crate) fn describe_checked(id: &str) -> Value {
    let (state, expires) = match launch_home_dir() {
        Some(home) if id == "cursor_agent" => {
            cursor_agent_readiness(&home, now_ms(), &from_launch_environment, &cursor_keychain)
        }
        _ => readiness(id, true),
    };
    wire(id, state, expires)
}

fn wire(id: &str, state: Readiness, expires: Option<i64>) -> Value {
    json!({
        "readiness": state.id(),
        "signedIn": match state {
            Readiness::SignedIn => Value::Bool(true),
            Readiness::NeedsSignIn | Readiness::Expired => Value::Bool(false),
            Readiness::NotInstalled | Readiness::Unknown => Value::Null,
        },
        "expiresAt": expires.map(Value::from).unwrap_or(Value::Null),
        "checked": !matches!(state, Readiness::Unknown),
        "signIn": match sign_in(id) {
            Some(flow) => json!({"supported": true, "kind": flow.kind}),
            None => json!({"supported": false, "kind": Value::Null}),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_and_oversized_stores_cannot_confirm_a_login() {
        for body in ["{", "not json", "{}", "null", "[]"] {
            let home = home_with(".codex/auth.json", body);
            assert_eq!(
                readiness_in("codex", true, home.path(), 0, &no_env).0,
                Readiness::Unknown
            );
        }
        let home = home_with(
            ".codex/auth.json",
            &format!(r#"{{"padding":"{}"}}"#, "x".repeat(1024 * 1024)),
        );
        assert_eq!(
            readiness_in("codex", true, home.path(), 0, &no_env).0,
            Readiness::Unknown
        );
        std::fs::remove_file(home.path().join(".codex/auth.json")).unwrap();
        std::fs::write(
            home.path().join(".codex/config.toml"),
            "x".repeat(1024 * 1024 + 1),
        )
        .unwrap();
        assert_eq!(
            readiness_in("codex", true, home.path(), 0, &no_env).0,
            Readiness::Unknown
        );
    }

    #[test]
    fn a_tool_that_is_not_here_is_never_asked_about_its_login() {
        let (state, expiry) = readiness("claude_code", false);
        assert_eq!(state, Readiness::NotInstalled);
        assert!(expiry.is_none());
    }

    #[test]
    fn an_agent_with_no_verified_store_says_it_cannot_tell() {
        let (state, _) = readiness("cline", true);
        assert_eq!(state, Readiness::Unknown);
        assert_eq!(describe("cline", true)["signedIn"], Value::Null);
        assert_eq!(describe("cline", true)["checked"], json!(false));
    }

    #[test]
    fn a_stored_login_reports_its_own_expiry_and_nothing_else() {
        let raw = r#"{"claudeAiOauth":{"accessToken":"secret","expiresAt":1893456000000}}"#;
        assert_eq!(claude_expiry(raw), Some(1_893_456_000_000));
        let body = describe("claude_code", true);
        assert!(!body.to_string().contains("secret"));
    }

    #[test]
    fn a_blob_without_an_oauth_section_carries_no_expiry() {
        assert_eq!(claude_expiry(r#"{"other":{"expiresAt":1}}"#), None);
        assert_eq!(claude_expiry("not json"), None);
    }

    #[test]
    fn a_sign_in_flow_exists_only_where_a_terminal_is_enough() {
        assert!(sign_in("claude_code").is_some());
        assert!(sign_in("codex").is_some());
        // Cursor Agent's login polls rather than calling back, so it works
        // from any browser. The editor's own `cursor` command has no such flow.
        assert!(sign_in("cursor_agent").is_some());
        assert_eq!(sign_in("muse").map(|flow| flow.kind), Some("deviceCode"));
        assert!(sign_in("cursor").is_none());
        assert_eq!(
            describe("cursor", true)["signIn"]["supported"],
            json!(false)
        );
    }

    fn cursor_jwt(exp: i64) -> String {
        let claims = crate::base64::encode(json!({"exp": exp}).to_string().as_bytes());
        let claims = claims
            .trim_end_matches('=')
            .replace('+', "-")
            .replace('/', "_");
        format!("header.{claims}.signature")
    }

    #[test]
    fn cursor_agent_reads_the_later_expiry_and_never_the_status_command() {
        let home = tempfile::tempdir().unwrap();
        let now = 2_000_000_000_000;
        let stale = cursor_jwt(1_900_000_000);
        let live = cursor_jwt(2_100_000_000);
        let keychain = |tokens: Vec<String>| move || KeychainAnswer::Found(tokens.clone());
        let file_env =
            |var: &str| (var == "AGENT_CLI_CREDENTIAL_STORE").then(|| PathBuf::from("file"));
        let env: &dyn Fn(&str) -> Option<PathBuf> = if cfg!(target_os = "macos") {
            &no_env
        } else {
            &file_env
        };
        let write = |tokens: &[&String]| {
            let path = cursor_auth_file(home.path(), env);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let body = json!({"accessToken": tokens.first(), "refreshToken": tokens.get(1)});
            std::fs::write(path, body.to_string()).unwrap();
        };

        write(&[&stale, &stale]);
        let found = cursor_agent_readiness(home.path(), now, env, &keychain(vec![stale.clone()]));
        assert_eq!(found, (Readiness::Expired, Some(1_900_000_000_000)));

        write(&[&stale, &live]);
        let found = cursor_agent_readiness(
            home.path(),
            now,
            env,
            &keychain(vec![stale.clone(), live.clone()]),
        );
        assert_eq!(found, (Readiness::SignedIn, Some(2_100_000_000_000)));

        std::fs::remove_file(cursor_auth_file(home.path(), env)).unwrap();
        let found = cursor_agent_readiness(home.path(), now, env, &keychain(Vec::new()));
        assert_eq!(found.0, Readiness::NeedsSignIn);

        let key = |var: &str| (var == "CURSOR_API_KEY").then(|| PathBuf::from("key"));
        let found = cursor_agent_readiness(home.path(), now, &key, &keychain(Vec::new()));
        assert_eq!(found, (Readiness::SignedIn, None));
    }

    #[test]
    fn cursor_memory_store_ignores_saved_logins_and_accepts_environment_auth() {
        let home = tempfile::tempdir().unwrap();
        let memory =
            |var: &str| (var == "AGENT_CLI_CREDENTIAL_STORE").then(|| PathBuf::from("memory"));
        let auth = cursor_auth_file(home.path(), &memory);
        std::fs::create_dir_all(auth.parent().unwrap()).unwrap();
        std::fs::write(&auth, json!({"apiKey": "saved-key"}).to_string()).unwrap();
        let no_keychain = || panic!("memory mode must not read the keychain");
        assert_eq!(
            cursor_agent_readiness(home.path(), 0, &memory, &no_keychain),
            (Readiness::Unknown, None)
        );
        let auth_token = |var: &str| {
            if var == "CURSOR_AUTH_TOKEN" {
                Some(PathBuf::from("token-from-env"))
            } else {
                memory(var)
            }
        };
        assert_eq!(
            cursor_agent_readiness(home.path(), 0, &auth_token, &no_keychain),
            (Readiness::SignedIn, None)
        );
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn cursor_keychain_api_key_can_renew_expired_login_tokens() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(
            cursor_agent_readiness(home.path(), i64::MAX, &no_env, &|| KeychainAnswer::ApiKey),
            (Readiness::SignedIn, None)
        );
    }

    #[test]
    fn cursor_and_muse_readiness_uses_the_environment_their_turn_inherits() {
        let process = |var: &str| match var {
            "XDG_CONFIG_HOME" => Some(PathBuf::from("/daemon-config")),
            "META_API_KEY" => Some(PathBuf::from("daemon-key")),
            "AGENT_CLI_CREDENTIAL_STORE" => Some(PathBuf::from("file")),
            _ => None,
        };
        let login = tokenstat_pty::LoginEnv {
            path: String::new(),
            vars: std::collections::HashMap::from([
                ("XDG_CONFIG_HOME".into(), "/login-config".into()),
                ("META_API_KEY".into(), String::new()),
                ("HOME".into(), "/login-home".into()),
            ]),
        };
        let env = |var: &str| launch_environment(var, Some(&login), &process);
        assert_eq!(env("XDG_CONFIG_HOME"), Some(PathBuf::from("/login-config")));
        assert_eq!(env("META_API_KEY"), Some(PathBuf::new()));
        assert_eq!(env("HOME"), Some(PathBuf::from("/login-home")));
        assert_eq!(
            env("AGENT_CLI_CREDENTIAL_STORE"),
            Some(PathBuf::from("file"))
        );
        assert_eq!(
            launch_environment("META_API_KEY", None, &process),
            process("META_API_KEY")
        );
    }

    #[test]
    fn muse_is_signed_in_when_its_record_names_the_meta_provider() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(
            muse_readiness(home.path(), &no_env).0,
            Readiness::NeedsSignIn
        );

        let auth = home.path().join(".config/muse/auth.json");
        std::fs::create_dir_all(auth.parent().unwrap()).unwrap();
        std::fs::write(
            &auth,
            r#"{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#,
        )
        .unwrap();
        assert_eq!(
            muse_readiness(home.path(), &no_env),
            (Readiness::SignedIn, None)
        );

        std::fs::write(&auth, r#"{"schema_version":1,"providers":{}}"#).unwrap();
        assert_eq!(
            muse_readiness(home.path(), &no_env).0,
            Readiness::NeedsSignIn
        );

        std::fs::write(&auth, "{").unwrap();
        assert_eq!(muse_readiness(home.path(), &no_env).0, Readiness::Unknown);

        let key = |var: &str| (var == "META_API_KEY").then(|| PathBuf::from("key"));
        std::fs::remove_file(&auth).unwrap();
        assert_eq!(muse_readiness(home.path(), &key).0, Readiness::SignedIn);
    }

    #[test]
    fn a_sign_in_command_is_never_taken_from_a_caller() {
        // Arguments are a fixed table, so a client can only pick a row.
        for flow in SIGN_INS {
            assert!(flow.args.iter().all(|arg| !arg.contains(' ')));
        }
    }

    #[test]
    fn a_keyring_store_makes_a_missing_file_mean_nothing() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(".codex")).unwrap();
        std::fs::write(
            dir.path().join(".codex/config.toml"),
            "cli_auth_credentials_store = \"keyring\"\n",
        )
        .unwrap();
        assert!(codex_uses_keyring(dir.path(), &no_env));
        std::fs::write(
            dir.path().join(".codex/config.toml"),
            "cli_auth_credentials_store = \"file\"\n",
        )
        .unwrap();
        assert!(!codex_uses_keyring(dir.path(), &no_env));
    }

    #[test]
    fn every_described_state_is_one_the_client_knows() {
        for state in [
            Readiness::NotInstalled,
            Readiness::NeedsSignIn,
            Readiness::SignedIn,
            Readiness::Expired,
            Readiness::Unknown,
        ] {
            assert!(
                [
                    "notInstalled",
                    "needsSignIn",
                    "signedIn",
                    "expired",
                    "unknown"
                ]
                .contains(&state.id())
            );
        }
    }

    /// A machine with none of the relocation variables set, which is what the
    /// cases below are about. Nothing here may depend on the environment of
    /// whatever machine is running the tests.
    fn no_env(_: &str) -> Option<PathBuf> {
        None
    }

    fn home_with(file: &str, body: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, body).unwrap();
        dir
    }

    #[test]
    fn a_machine_nobody_has_signed_in_on_says_exactly_that() {
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(
            readiness_in("claude_code", true, empty.path(), 0, &no_env).0,
            // A Mac keeps this one in the keychain, so a missing file there
            // proves nothing. Everywhere else it is the plain answer.
            if cfg!(target_os = "macos") {
                Readiness::Unknown
            } else {
                Readiness::NeedsSignIn
            }
        );
        assert_eq!(
            readiness_in("codex", true, empty.path(), 0, &no_env).0,
            Readiness::NeedsSignIn
        );
    }

    #[test]
    fn a_login_is_signed_in_until_its_own_expiry_passes() {
        let home = home_with(
            ".claude/.credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}"#,
        );
        assert_eq!(
            readiness_in("claude_code", true, home.path(), 999, &no_env),
            (Readiness::SignedIn, Some(1000))
        );
        assert_eq!(
            readiness_in("claude_code", true, home.path(), 1000, &no_env),
            (Readiness::Expired, Some(1000))
        );
        assert_eq!(
            readiness_in("claude_code", true, home.path(), 5000, &no_env),
            (Readiness::Expired, Some(1000))
        );
    }

    /// A store with no expiry in it is a login, and saying when it runs out is
    /// not something to invent.
    #[test]
    fn a_store_that_states_no_expiry_reports_none() {
        let home = home_with(".codex/auth.json", r#"{"tokens":{"id_token":"x"}}"#);
        assert_eq!(
            readiness_in("codex", true, home.path(), 0, &no_env),
            (Readiness::SignedIn, None)
        );
    }

    /// Half a file is not half a login. It is a state to be told about.
    #[test]
    fn an_empty_store_is_not_read_as_signed_out() {
        let home = home_with(".codex/auth.json", "   \n");
        assert_eq!(
            readiness_in("codex", true, home.path(), 0, &no_env).0,
            Readiness::Unknown
        );
    }

    #[test]
    fn an_uninstalled_agent_is_never_looked_up_on_disk() {
        let home = home_with(
            ".claude/.credentials.json",
            r#"{"claudeAiOauth":{"expiresAt":1}}"#,
        );
        assert_eq!(
            readiness_in("claude_code", false, home.path(), 0, &no_env),
            (Readiness::NotInstalled, None)
        );
    }

    /// The relocation variable is part of the answer, so a test that supplies
    /// a home has to supply it too. This is the case that used to read the
    /// machine running the tests.
    #[test]
    fn a_relocated_config_directory_is_where_the_login_is_looked_for() {
        let home = home_with(
            ".claude/.credentials.json",
            r#"{"claudeAiOauth":{"expiresAt":9}}"#,
        );
        let elsewhere = tempfile::tempdir().unwrap();
        let moved = elsewhere.path().to_path_buf();
        let env = move |var: &str| (var == "CLAUDE_CONFIG_DIR").then(|| moved.clone());
        // The home's own file is not consulted once the variable names another
        // directory, and that directory has no login in it.
        assert_eq!(
            readiness_in("claude_code", true, home.path(), 0, &env).0,
            if cfg!(target_os = "macos") {
                Readiness::Unknown
            } else {
                Readiness::NeedsSignIn
            }
        );
        std::fs::write(
            elsewhere.path().join(".credentials.json"),
            r#"{"claudeAiOauth":{"expiresAt":50}}"#,
        )
        .unwrap();
        assert_eq!(
            readiness_in("claude_code", true, home.path(), 0, &env),
            (Readiness::SignedIn, Some(50))
        );
    }
}
