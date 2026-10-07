// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Pairing material is read once and never echoed into installer output.

use std::io::Read;
use std::path::Path;

use anyhow::{Context, Result, bail};

pub struct PairingCode(String);

impl PairingCode {
    pub fn read(code: Option<&str>, file: Option<&Path>) -> Result<Option<Self>> {
        match (code, file) {
            (Some(_), Some(_)) => bail!("Use either --code or --code-file"),
            (None, None) => Ok(None),
            (Some(value), None) => Self::parse(value).map(Some),
            (None, Some(path)) => {
                let (mut reader, opened): (Box<dyn Read>, Option<std::fs::Metadata>) =
                    if path == Path::new("-") {
                        (Box::new(std::io::stdin()), None)
                    } else {
                        let file = open_pairing_file(path)?;
                        let metadata = file
                            .metadata()
                            .context("Could not inspect the opened pairing file")?;
                        (Box::new(file), Some(metadata))
                    };
                let mut value = String::new();
                reader
                    .by_ref()
                    .take(129)
                    .read_to_string(&mut value)
                    .context("Could not read the pairing code")?;
                if value.len() > 128 {
                    bail!("The pairing-code file is too long");
                }
                let code = Self::parse(&value)?;
                // The SSH wizard owns this reserved staging file. Once read,
                // keep the code in memory and retire the file even if enrollment
                // fails later or the phone disconnects. Other input files belong
                // to the caller and are left alone.
                if let (Some(dirs), Some(opened)) = (directories::BaseDirs::new(), opened) {
                    remove_staged_file(path, dirs.home_dir(), &opened)?;
                }
                Ok(Some(code))
            }
        }
    }

    fn parse(value: &str) -> Result<Self> {
        let value = value.trim();
        let plain: String = value.chars().filter(|c| *c != '-').collect();
        if plain.len() != 8 || !plain.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
            bail!("The pairing code must contain eight letters or digits, like WXYZ-1234");
        }
        Ok(Self(plain.to_ascii_uppercase()))
    }

    pub fn redeem(&self) -> Result<Option<String>> {
        tokenstat_sync::login_with_code(None, &self.0)
            .map(|result| result.handle)
            .map_err(|error| {
                let hyphenated = format!("{}-{}", &self.0[..4], &self.0[4..]);
                let message = error
                    .to_string()
                    .replace(&self.0, "[pairing code]")
                    .replace(&hyphenated, "[pairing code]");
                anyhow::anyhow!("Could not pair this machine: {message}")
            })
    }
}

fn remove_staged_file(path: &Path, home: &Path, opened: &std::fs::Metadata) -> Result<()> {
    // Compare canonical forms: `./~/.tokenstat-pairing`, double slashes, or a
    // hardlink spelling must still retire the wizard's file, and a symlink
    // pointing at it must not delete through the link check below.
    let staged = home.join(".tokenstat-pairing");
    let canonical_same = path == staged
        || std::fs::canonicalize(path).ok().as_ref() == Some(&staged)
        || std::fs::canonicalize(&staged)
            .ok()
            .as_ref()
            .zip(std::fs::canonicalize(path).ok().as_ref())
            .is_some_and(|(a, b)| a == b);
    // Canonicalize spells one path per inode, so two hardlinks to the staged
    // file still compare unequal. The device/inode pair names the file itself
    // and catches every alias.
    #[cfg(unix)]
    let same = canonical_same || {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(path)
            .and_then(|p| std::fs::metadata(&staged).map(|s| (p, s)))
            .is_ok_and(|(p, s)| p.dev() == s.dev() && p.ino() == s.ino())
    };
    #[cfg(not(unix))]
    let same = canonical_same;
    if same {
        // Use the same lock as SSH staging/cleanup. Compare the file actually
        // read, not the path reopened after a new attempt replaced it.
        let _guard = acquire_pairing_lock(&home.join(".tokenstat-pairing.lock"))?;
        let current = match std::fs::symlink_metadata(&staged) {
            Ok(current) if current.is_file() => current,
            Ok(_) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error).context("Could not inspect the staged pairing-code file");
            }
        };
        #[cfg(unix)]
        let unchanged = {
            use std::os::unix::fs::MetadataExt;
            current.dev() == opened.dev() && current.ino() == opened.ino()
        };
        #[cfg(not(unix))]
        let unchanged =
            current.len() == opened.len() && current.modified().ok() == opened.modified().ok();
        if unchanged {
            std::fs::remove_file(&staged)
                .context("Could not remove the staged pairing-code file")?;
            match std::fs::remove_file(home.join(".tokenstat-pairing.owner")) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).context("Could not remove the pairing staging receipt");
                }
            }
        }
    }
    Ok(())
}

/// Open the pairing file without following symlinks, then validate what was
/// opened. `symlink_metadata` + `File::open` is a TOCTOU: a writer in the
/// directory can swap file and link between the two calls. `O_NOFOLLOW` fails
/// the open itself when the final component is a link.
#[cfg(unix)]
fn open_pairing_file(path: &Path) -> Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .context("Could not open the pairing-code file")?;
    // `metadata()` here is fstat on the opened fd, so it describes what will
    // be read rather than what the path named at some earlier instant.
    validate_file(&file.metadata()?)?;
    Ok(file)
}

#[cfg(not(unix))]
fn open_pairing_file(path: &Path) -> Result<std::fs::File> {
    let metadata =
        std::fs::symlink_metadata(path).context("Could not inspect the pairing-code file")?;
    validate_file(&metadata)?;
    let file = std::fs::File::open(path).context("Could not open the pairing-code file")?;
    validate_file(&file.metadata()?)?;
    Ok(file)
}

const PAIRING_LOCK_STALE: std::time::Duration = std::time::Duration::from_secs(5);

struct PairingLock(std::path::PathBuf);
impl Drop for PairingLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0.join("pid"));
        let _ = std::fs::remove_dir(&self.0);
    }
}

fn acquire_pairing_lock(lock: &Path) -> Result<PairingLock> {
    for _ in 0..50 {
        match std::fs::create_dir(lock) {
            Ok(()) => {
                if let Err(error) =
                    std::fs::write(lock.join("pid"), format!("{}\n", std::process::id()))
                {
                    let _ = std::fs::remove_dir(lock);
                    return Err(error).context("Could not record the pairing lock");
                }
                return Ok(PairingLock(lock.to_path_buf()));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                if !reclaim_pairing_lock(lock) {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
            Err(error) => return Err(error).context("Could not lock the pairing-code file"),
        }
    }
    anyhow::bail!("The pairing-code file is busy; retry setup")
}

/// A dead pid, or an empty directory older than the shell's wait, is not a holder.
fn reclaim_pairing_lock(lock: &Path) -> bool {
    let stale = match std::fs::read_to_string(lock.join("pid")) {
        Ok(text) => !process_alive(text.trim().parse().unwrap_or(0)),
        Err(_) => std::fs::metadata(lock)
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age >= PAIRING_LOCK_STALE),
    };
    if !stale {
        return false;
    }
    let _ = std::fs::remove_file(lock.join("pid"));
    std::fs::remove_dir(lock).is_ok()
}

fn process_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // `ps` reports a live pid without signaling it. A missing `ps` is treated
    // as live so a lock is not stolen just because the check could not run.
    match std::process::Command::new("ps")
        .args(["-p", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
    {
        Ok(status) => status.success(),
        Err(_) => true,
    }
}

fn validate_file(metadata: &std::fs::Metadata) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
            bail!(
                "The pairing-code file must be a regular private file. Use `chmod 600` before installing."
            );
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        if !metadata.is_file() {
            bail!("The pairing-code file must be a regular file.");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_pairing_material_is_never_repeated_in_errors() {
        let secret = "this-is-a-secret-value";
        let error = PairingCode::parse(secret).err().unwrap();
        assert!(!error.to_string().contains(secret));
        assert_eq!(PairingCode::parse(" wxyz-1234\n").unwrap().0, "WXYZ1234");
        assert!(PairingCode::parse("WXYZ/1234").is_err());
    }

    #[test]
    fn file_codes_require_private_regular_files_and_bounded_contents() {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("tokenstat-enroll-test-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("code");
        std::fs::write(&path, "WXYZ-1234\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(PairingCode::read(None, Some(&path)).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            PairingCode::read(None, Some(&path)).unwrap().unwrap().0,
            "WXYZ1234"
        );
        let link = dir.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(PairingCode::read(None, Some(&link)).is_err());
        assert!(PairingCode::read(None, Some(&dir)).is_err());
        std::fs::write(&path, "A".repeat(129)).unwrap();
        assert!(PairingCode::read(None, Some(&path)).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn only_the_wizards_reserved_file_is_removed() {
        let home = std::env::temp_dir().join(format!("tokenstat-retire-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let staged = home.join(".tokenstat-pairing");
        let other = home.join("my-code");
        std::fs::write(&staged, "WXYZ-1234").unwrap();
        std::fs::write(&other, "WXYZ-1234").unwrap();
        remove_staged_file(&other, &home, &std::fs::metadata(&other).unwrap()).unwrap();
        assert!(other.is_file());
        remove_staged_file(&staged, &home, &std::fs::metadata(&staged).unwrap()).unwrap();
        assert!(!staged.exists());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_hardlink_alias_still_retires_the_staged_file() {
        let home = std::env::temp_dir().join(format!("tokenstat-hardlink-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let staged = home.join(".tokenstat-pairing");
        let alias = home.join("alias-code");
        std::fs::write(&staged, "WXYZ-1234").unwrap();
        std::fs::hard_link(&staged, &alias).unwrap();
        remove_staged_file(&alias, &home, &std::fs::metadata(&alias).unwrap()).unwrap();
        // The reserved file is retired even when the read came through the
        // hardlink; the caller's own alias path is not what gets removed.
        assert!(!staged.exists());
        assert!(alias.is_file());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn a_consumed_predecessor_cannot_delete_a_newly_staged_code() {
        let home =
            std::env::temp_dir().join(format!("tokenstat-enroll-race-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let staged = home.join(".tokenstat-pairing");
        std::fs::write(&staged, "WXYZ-1234").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let file = open_pairing_file(&staged).unwrap();
        let opened = file.metadata().unwrap();
        let next = home.join("next");
        std::fs::write(&next, "ABCD-5678").unwrap();
        std::fs::rename(&next, &staged).unwrap();
        std::fs::write(home.join(".tokenstat-pairing.owner"), "successor").unwrap();
        remove_staged_file(&staged, &home, &opened).unwrap();
        assert_eq!(std::fs::read_to_string(&staged).unwrap(), "ABCD-5678");
        assert_eq!(
            std::fs::read_to_string(home.join(".tokenstat-pairing.owner")).unwrap(),
            "successor"
        );
        assert!(!home.join(".tokenstat-pairing.lock").exists());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_dead_pairing_lock_is_reclaimed_and_a_live_one_is_not() {
        let home =
            std::env::temp_dir().join(format!("tokenstat-enroll-lock-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let staged = home.join(".tokenstat-pairing");
        std::fs::write(&staged, "WXYZ-1234").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600)).unwrap();
        let opened = open_pairing_file(&staged).unwrap().metadata().unwrap();
        let dead = home.join(".tokenstat-pairing.lock");
        std::fs::create_dir(&dead).unwrap();
        std::fs::write(dead.join("pid"), "2147483647\n").unwrap();
        remove_staged_file(&staged, &home, &opened).unwrap();
        assert!(!staged.exists());
        assert!(!dead.exists());

        std::fs::write(&staged, "WXYZ-1234").unwrap();
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600)).unwrap();
        let opened = open_pairing_file(&staged).unwrap().metadata().unwrap();
        let live = home.join(".tokenstat-pairing.lock");
        std::fs::create_dir(&live).unwrap();
        std::fs::write(live.join("pid"), format!("{}\n", std::process::id())).unwrap();
        let error = remove_staged_file(&staged, &home, &opened).unwrap_err();
        assert!(error.to_string().contains("busy"), "{error}");
        assert!(staged.is_file());
        assert!(live.is_dir());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn code_sources_are_exclusive() {
        assert!(PairingCode::read(None, None).unwrap().is_none());
        assert!(PairingCode::read(Some("WXYZ1234"), Some(Path::new("unused"))).is_err());
    }
}
