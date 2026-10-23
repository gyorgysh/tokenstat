// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! A fresh home for one Team run.
//!
//! The backend process starts with an empty environment except the path it
//! needs to find its own tools and the variables the scoped SDK adds later.
//! Personal hooks, resume state and memory stay in the person's own home.
//! Preparation imports none of them. The provider may subsequently route only
//! its CLI's native sign-in, using the same credential routing as private chat.

use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
};

use crate::team_process::Program;

pub(super) struct RunHome {
    root: PathBuf,
    pub cwd: PathBuf,
    pub env: BTreeMap<String, String>,
}

impl RunHome {
    /// A file in the run's private root, beside its home and config.
    pub fn file(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }
}

impl Drop for RunHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

pub(super) fn prepare(scratch: &Path, cwd: &Path, program: &Program) -> io::Result<RunHome> {
    let cwd = cwd.canonicalize()?;
    if !cwd.is_dir() {
        return Err(invalid());
    }
    let asked = program.folder.canonicalize()?;
    if asked != cwd {
        return Err(invalid());
    }
    fs::create_dir_all(scratch)?;
    #[cfg(unix)]
    set_private(scratch)?;
    let root = scratch.join(format!("{:032x}", rand::random::<u128>()));
    fs::create_dir(&root)?;
    #[cfg(unix)]
    set_private(&root)?;
    let home = root.join("home");
    let config = root.join("config");
    let cache = root.join("cache");
    let tmp = root.join("tmp");
    let claude = config.join("claude");
    let codex = config.join("codex");
    for directory in [&home, &config, &cache, &tmp, &claude, &codex] {
        fs::create_dir(directory)?;
        #[cfg(unix)]
        set_private(directory)?;
    }
    // Native CLI discovery must stop inside this private cwd even when the
    // scratch directory lives below a person's project or real home. Build
    // a valid empty Git boundary directly: git-init could load user templates.
    for directory in [home.join(".git/objects"), home.join(".git/refs/heads")] {
        fs::create_dir_all(directory)?;
    }
    fs::write(home.join(".git/HEAD"), "ref: refs/heads/team-run\n")?;
    fs::write(
        home.join(".git/config"),
        "[core]\nrepositoryformatversion = 0\nbare = false\n",
    )?;
    let mut env = BTreeMap::new();
    if let Some(path) = program.env.get("PATH") {
        if path.is_empty() || path.contains('\0') || path.len() > 64 * 1024 {
            return Err(invalid());
        }
        env.insert("PATH".into(), path.clone());
    }
    env.insert("HOME".into(), home.to_string_lossy().into_owned());
    env.insert(
        "XDG_CONFIG_HOME".into(),
        config.to_string_lossy().into_owned(),
    );
    env.insert(
        "XDG_CACHE_HOME".into(),
        cache.to_string_lossy().into_owned(),
    );
    env.insert("XDG_DATA_HOME".into(), home.to_string_lossy().into_owned());
    env.insert("TMPDIR".into(), tmp.to_string_lossy().into_owned());
    env.insert(
        "CLAUDE_CONFIG_DIR".into(),
        claude.to_string_lossy().into_owned(),
    );
    env.insert("CODEX_HOME".into(), codex.to_string_lossy().into_owned());
    #[cfg(windows)]
    {
        let roaming = home.join("AppData/Roaming");
        let local = home.join("AppData/Local");
        fs::create_dir_all(&roaming)?;
        fs::create_dir_all(&local)?;
        env.insert("APPDATA".into(), roaming.to_string_lossy().into_owned());
        env.insert("LOCALAPPDATA".into(), local.to_string_lossy().into_owned());
        env.insert("USERPROFILE".into(), home.to_string_lossy().into_owned());
        env.insert("TEMP".into(), tmp.to_string_lossy().into_owned());
        env.insert("TMP".into(), tmp.to_string_lossy().into_owned());
    }
    Ok(RunHome { root, cwd, env })
}

fn invalid() -> io::Error {
    io::Error::other("The Team run home could not be prepared.")
}

#[cfg(unix)]
fn set_private(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn program(folder: &Path) -> Program {
        Program {
            executable: folder.join("agent"),
            args: Vec::new(),
            env: BTreeMap::from([
                ("HOME".into(), "/personal/home".into()),
                ("CLAUDE_CONFIG_DIR".into(), "/personal/claude".into()),
                ("CODEX_HOME".into(), "/personal/codex".into()),
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("TEAM_HOOK".into(), "/personal/hooks".into()),
            ]),
            folder: folder.into(),
            input: folder.join("input"),
            output: folder.join("output"),
            errors: folder.join("errors"),
        }
    }

    #[test]
    fn a_run_home_keeps_the_checkout_and_drops_personal_state() {
        let scratch = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        fs::write(checkout.path().join("hooks.json"), "personal hook").unwrap();
        let home = prepare(scratch.path(), checkout.path(), &program(checkout.path())).unwrap();
        assert_eq!(home.cwd, checkout.path().canonicalize().unwrap());
        assert_eq!(
            home.env.get("PATH").map(String::as_str),
            Some("/usr/bin:/bin")
        );
        assert_ne!(
            home.env.get("HOME").map(String::as_str),
            Some("/personal/home")
        );
        assert!(!home.env.contains_key("TEAM_HOOK"));
        let claude = PathBuf::from(home.env["CLAUDE_CONFIG_DIR"].as_str());
        let codex = PathBuf::from(home.env["CODEX_HOME"].as_str());
        assert!(claude.starts_with(&home.root) && claude.read_dir().unwrap().next().is_none());
        assert!(codex.starts_with(&home.root) && codex.read_dir().unwrap().next().is_none());
        assert!(
            !fs::read_dir(&home.root)
                .unwrap()
                .any(|entry| entry.unwrap().file_name() == "hooks.json")
        );
        assert_eq!(
            fs::read_to_string(checkout.path().join("hooks.json")).unwrap(),
            "personal hook"
        );
    }

    #[test]
    fn a_different_folder_is_refused() {
        let scratch = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let mut launched = program(checkout.path());
        launched.folder = other.path().into();
        assert!(prepare(scratch.path(), checkout.path(), &launched).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn native_git_discovery_stops_at_the_private_cli_home() {
        let scratch = tempfile::tempdir().unwrap();
        let checkout = tempfile::tempdir().unwrap();
        let home = prepare(scratch.path(), checkout.path(), &program(checkout.path())).unwrap();
        let output = std::process::Command::new("git")
            .args(["--no-optional-locks", "rev-parse", "--show-toplevel"])
            .current_dir(home.file("home"))
            .env_clear()
            .envs(&home.env)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            Path::new(String::from_utf8(output.stdout).unwrap().trim())
                .canonicalize()
                .unwrap(),
            home.file("home").canonicalize().unwrap()
        );
        assert!(!home.file("home/.git/hooks").exists());
    }
}
