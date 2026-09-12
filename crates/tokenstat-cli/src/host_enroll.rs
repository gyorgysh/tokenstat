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
                let mut reader: Box<dyn Read> = if path == Path::new("-") {
                    Box::new(std::io::stdin())
                } else {
                    Box::new(open_pairing_file(path)?)
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
                if let Some(dirs) = directories::BaseDirs::new() {
                    remove_staged_file(path, dirs.home_dir())?;
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

    pub fn redeem(&self) -> Result<String> {
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

fn remove_staged_file(path: &Path, home: &Path) -> Result<()> {
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
        std::fs::remove_file(&staged).context("Could not remove the staged pairing-code file")?;
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
        remove_staged_file(&other, &home).unwrap();
        assert!(other.is_file());
        remove_staged_file(&staged, &home).unwrap();
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
        remove_staged_file(&alias, &home).unwrap();
        // The reserved file is retired even when the read came through the
        // hardlink; the caller's own alias path is not what gets removed.
        assert!(!staged.exists());
        assert!(alias.is_file());
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn code_sources_are_exclusive() {
        assert!(PairingCode::read(None, None).unwrap().is_none());
        assert!(PairingCode::read(Some("WXYZ1234"), Some(Path::new("unused"))).is_err());
    }
}
