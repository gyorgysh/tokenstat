// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Profiles: more than one login for the same coding agent.
//!
//! The default profile is the machine itself: every agent reads whatever the
//! person is signed in to in Terminal, exactly as before profiles existed. A
//! named profile (Work, Personal) gives chosen agents a login of their own,
//! kept in a private folder the agent's own relocation variable points at.
//! Everything else the agent reads (instructions, skills, settings) is linked
//! in from the person's own folders, so a profile changes who is signed in and
//! nothing else.
//!
//! tokenstat never reads or writes a login here. The agent's own sign-in
//! fills the folder. This module only decides which folder an agent sees.
//!
//! Profiles are local to the machine. Their names and folders never leave it.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The machine's own logins. Never stored, never deleted.
pub(crate) const SYSTEM: &str = "system";

/// Agents a profile can give a login of their own, and the variable each one
/// reads its whole home from.
const AGENTS: &[(&str, &str)] = &[
    ("claude_code", "CLAUDE_CONFIG_DIR"),
    ("codex", "CODEX_HOME"),
];

/// Personal Claude Code files a profile shares with the person's own folder.
/// `.claude.json` is deliberately absent: it names the signed-in account.
const SHARED_CLAUDE: &[&str] = &[
    "CLAUDE.md",
    "settings.json",
    "agents",
    "commands",
    "skills",
    "output-styles",
    "plugins",
];

const MAX_PROFILES: usize = 24;
const MAX_NAME: usize = 40;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Store {
    #[serde(default)]
    default: Option<String>,
    #[serde(default)]
    profiles: Vec<Profile>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Profile {
    id: String,
    name: String,
    /// Agents with a login of their own here. Every other agent is the same
    /// as on the machine.
    #[serde(default)]
    own: Vec<String>,
    created_at_ms: i64,
}

/// One writer at a time inside this process. The file is replaced
/// atomically, so a reader never sees half of it.
static LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
thread_local! {
    static TEST_ROOT: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

fn root() -> Result<PathBuf, String> {
    #[cfg(test)]
    if let Some(root) = TEST_ROOT.with(|root| root.borrow().clone()) {
        return Ok(root);
    }
    tokenstat_paths::data_dir()
        .map(|dir| dir.join("profiles"))
        .ok_or_else(|| "no data folder for profiles".to_string())
}

fn store_path() -> Result<PathBuf, String> {
    Ok(root()?.join("profiles.json"))
}

fn load() -> Result<Store, String> {
    let path = store_path()?;
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            serde_json::from_str(&text).map_err(|e| format!("profiles file is damaged: {e}"))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Store::default()),
        Err(error) => Err(error.to_string()),
    }
}

fn save(store: &Store) -> Result<(), String> {
    let text = serde_json::to_string_pretty(store).map_err(|e| e.to_string())?;
    tokenstat_sync::snapshot::write_private_atomically(&store_path()?, &text)
        .map_err(|e| e.to_string())
}

fn edit<T>(change: impl FnOnce(&mut Store) -> Result<T, String>) -> Result<T, String> {
    let _held = LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut store = load()?;
    let out = change(&mut store)?;
    save(&store)?;
    Ok(out)
}

/// Every profile, the machine's first, and which one new chats start on.
pub(crate) fn list() -> Result<Value, String> {
    let store = load()?;
    let mut profiles = vec![json!({"id": SYSTEM, "system": true, "own": []})];
    profiles.extend(store.profiles.iter().map(|profile| {
        json!({"id": profile.id, "name": profile.name, "system": false, "own": profile.own})
    }));
    Ok(json!({
        "default": store.default.clone().unwrap_or_else(|| SYSTEM.to_string()),
        "agents": AGENTS.iter().map(|(id, _)| id).collect::<Vec<_>>(),
        "profiles": profiles,
    }))
}

pub(crate) fn create(name: &str) -> Result<Value, String> {
    let name = clean_name(name)?;
    let id = edit(|store| {
        if store.profiles.len() >= MAX_PROFILES {
            return Err(format!("At most {MAX_PROFILES} profiles."));
        }
        ensure_unique(store, &name, None)?;
        let id = format!("p_{:016x}", rand::random::<u64>());
        store.profiles.push(Profile {
            id: id.clone(),
            name,
            own: Vec::new(),
            created_at_ms: crate::chat::now_ms(),
        });
        Ok(id)
    })?;
    Ok(json!({"id": id, "profiles": list()?}))
}

pub(crate) fn rename(id: &str, name: &str) -> Result<Value, String> {
    let name = clean_name(name)?;
    edit(|store| {
        ensure_unique(store, &name, Some(id))?;
        find_mut(store, id)?.name = name;
        Ok(())
    })?;
    list()
}

/// Give an agent a login of its own in this profile, or share the machine's
/// again. Sharing again keeps the folder, so switching back is not a new
/// sign-in. Deleting the profile is what removes logins.
pub(crate) fn set_agent(id: &str, agent: &str, own: bool) -> Result<Value, String> {
    variable(agent).ok_or_else(|| format!("{agent} cannot have a login of its own yet"))?;
    edit(|store| {
        let profile = find_mut(store, id)?;
        profile.own.retain(|known| known != agent);
        if own {
            profile.own.push(agent.to_string());
            profile.own.sort();
        }
        Ok(())
    })?;
    list()
}

pub(crate) fn set_default(id: &str) -> Result<Value, String> {
    edit(|store| {
        if id != SYSTEM {
            find_mut(store, id)?;
        }
        store.default = (id != SYSTEM).then(|| id.to_string());
        Ok(())
    })?;
    list()
}

/// Remove a profile and the logins kept in it. Claude Code keeps its login in
/// the Keychain under a name tied to the folder, so it is asked to sign out
/// first, or the login would outlive the folder it belongs to.
pub(crate) fn delete(id: &str) -> Result<Value, String> {
    if id == SYSTEM {
        return Err("This Mac's own logins cannot be removed.".into());
    }
    let own = {
        let store = load()?;
        store
            .profiles
            .iter()
            .find(|p| p.id == id)
            .ok_or("no such profile")?
            .own
            .clone()
    };
    if own.iter().any(|agent| agent == "claude_code") {
        let env = environment(Some(id), "claude_code").unwrap_or_default();
        crate::launcher::run_agent_quietly("claude_code", &["auth", "logout"], &env);
    }
    edit(|store| {
        store.profiles.retain(|profile| profile.id != id);
        if store.default.as_deref() == Some(id) {
            store.default = None;
        }
        Ok(())
    })?;
    let folder = root()?.join(id);
    if folder.starts_with(root()?) {
        let _ = std::fs::remove_dir_all(folder);
    }
    list()
}

/// The profile new chats start on, or the machine's.
pub(crate) fn default_id() -> String {
    load()
        .ok()
        .and_then(|store| store.default)
        .unwrap_or_else(|| SYSTEM.to_string())
}

/// Whether `id` names a profile that exists. The machine's always does.
pub(crate) fn exists(id: &str) -> bool {
    id == SYSTEM || load().is_ok_and(|store| store.profiles.iter().any(|p| p.id == id))
}

/// The variables an agent starts with in a profile. Empty for the machine's
/// own logins and for an agent the profile shares, which is what keeps every
/// existing chat exactly as it was. A profile that no longer exists is an
/// error, never a quiet fall back to the machine's account.
pub(crate) fn environment(
    profile: Option<&str>,
    agent: &str,
) -> Result<Vec<(String, String)>, String> {
    let Some(id) = profile.filter(|id| !id.is_empty() && *id != SYSTEM) else {
        return Ok(Vec::new());
    };
    let store = load()?;
    let profile = store
        .profiles
        .iter()
        .find(|p| p.id == id)
        .ok_or("That profile was removed. Start a new chat to pick another.")?;
    if !profile.own.iter().any(|own| own == agent) {
        return Ok(Vec::new());
    }
    let Some(var) = variable(agent) else {
        return Ok(Vec::new());
    };
    let folder = agent_folder(id, agent)?;
    prepare(agent, &folder)?;
    Ok(vec![(var.to_string(), folder.display().to_string())])
}

fn variable(agent: &str) -> Option<&'static str> {
    AGENTS
        .iter()
        .find(|(id, _)| *id == agent)
        .map(|(_, var)| *var)
}

fn agent_folder(id: &str, agent: &str) -> Result<PathBuf, String> {
    if !id.starts_with("p_") || !id[2..].chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("not a profile id".into());
    }
    Ok(root()?.join(id).join(agent))
}

/// Create the folder, private to the person, and share their own settings
/// into it. Runs before every use, so a skill added today reaches a profile
/// made last month.
fn prepare(agent: &str, folder: &Path) -> Result<(), String> {
    std::fs::create_dir_all(folder).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        for dir in [folder, folder.parent().unwrap_or(folder)] {
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
    }
    match agent {
        "claude_code" => {
            if let Some(source) = user_claude_dir().filter(|source| source != folder) {
                for name in SHARED_CLAUDE {
                    let original = source.join(name);
                    if original.exists() {
                        let _ = crate::chat_gate::link_shared(&original, &folder.join(name));
                    }
                }
            }
        }
        "codex" => crate::chat_gate::share_user_codex_home(folder),
        _ => {}
    }
    Ok(())
}

/// The person's own Claude Code folder: their `CLAUDE_CONFIG_DIR` from the
/// login shell when set, else `~/.claude`.
fn user_claude_dir() -> Option<PathBuf> {
    let login = tokenstat_pty::login_env();
    login
        .as_ref()
        .and_then(|env| env.vars.get("CLAUDE_CONFIG_DIR"))
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from))
        .filter(|dir| dir.is_absolute())
        .or_else(|| tokenstat_paths::home_dir().map(|home| home.join(".claude")))
}

fn clean_name(name: &str) -> Result<String, String> {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err("Give the profile a name.".into());
    }
    if name.chars().count() > MAX_NAME || name.chars().any(char::is_control) {
        return Err(format!("Use a name of at most {MAX_NAME} characters."));
    }
    Ok(name)
}

fn ensure_unique(store: &Store, name: &str, except: Option<&str>) -> Result<(), String> {
    let taken = store
        .profiles
        .iter()
        .any(|p| Some(p.id.as_str()) != except && p.name.eq_ignore_ascii_case(name));
    if taken {
        Err("A profile with that name already exists.".into())
    } else {
        Ok(())
    }
}

fn find_mut<'a>(store: &'a mut Store, id: &str) -> Result<&'a mut Profile, String> {
    store
        .profiles
        .iter_mut()
        .find(|p| p.id == id)
        .ok_or_else(|| "no such profile".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_data_dir(test: impl FnOnce(&Path)) {
        let dir = tempfile::tempdir().unwrap();
        TEST_ROOT.with(|root| *root.borrow_mut() = Some(dir.path().to_path_buf()));
        test(dir.path());
        TEST_ROOT.with(|root| *root.borrow_mut() = None);
    }

    #[test]
    fn the_machine_comes_first_and_shares_everything() {
        with_data_dir(|_| {
            let listed = list().unwrap();
            assert_eq!(listed["default"], SYSTEM);
            assert_eq!(listed["profiles"][0]["id"], SYSTEM);
            assert!(environment(None, "claude_code").unwrap().is_empty());
            assert!(environment(Some(SYSTEM), "codex").unwrap().is_empty());
        });
    }

    #[test]
    fn a_profile_gives_only_its_own_agents_a_folder_of_their_own() {
        with_data_dir(|data| {
            let id = create("  Work  ").unwrap()["id"]
                .as_str()
                .unwrap()
                .to_string();
            assert!(
                environment(Some(&id), "claude_code").unwrap().is_empty(),
                "shares until told"
            );
            set_agent(&id, "claude_code", true).unwrap();
            let env = environment(Some(&id), "claude_code").unwrap();
            assert_eq!(env.len(), 1);
            assert_eq!(env[0].0, "CLAUDE_CONFIG_DIR");
            let folder = PathBuf::from(&env[0].1);
            assert!(folder.starts_with(data) && folder.is_dir());
            assert!(environment(Some(&id), "codex").unwrap().is_empty());
            assert!(set_agent(&id, "cursor_agent", true).is_err());
            // Sharing again keeps the folder for next time.
            set_agent(&id, "claude_code", false).unwrap();
            assert!(environment(Some(&id), "claude_code").unwrap().is_empty());
            assert!(folder.is_dir());
        });
    }

    #[test]
    fn names_are_cleaned_unique_and_short() {
        with_data_dir(|_| {
            create("Work").unwrap();
            assert!(create("work").is_err());
            assert!(create("   ").is_err());
            assert!(create(&"x".repeat(41)).is_err());
            assert!(create("Line\u{7}bell").is_err());
            let listed = create("Client   A").unwrap();
            assert_eq!(listed["profiles"]["profiles"][2]["name"], "Client A");
        });
    }

    #[test]
    fn a_removed_profile_never_falls_back_to_the_machine() {
        with_data_dir(|_| {
            let id = create("Personal").unwrap()["id"]
                .as_str()
                .unwrap()
                .to_string();
            set_default(&id).unwrap();
            assert_eq!(default_id(), id);
            delete(&id).unwrap();
            assert_eq!(default_id(), SYSTEM);
            assert!(environment(Some(&id), "codex").is_err());
            assert!(!exists(&id));
            assert!(delete(SYSTEM).is_err());
        });
    }

    #[test]
    fn a_folder_name_cannot_leave_the_profiles_folder() {
        with_data_dir(|_| {
            assert!(agent_folder("../x", "codex").is_err());
            assert!(agent_folder("p_zz", "codex").is_err());
            assert!(agent_folder("p_0a", "codex").is_ok());
        });
    }
}
