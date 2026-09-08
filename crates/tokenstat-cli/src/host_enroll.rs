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
                    let metadata = std::fs::symlink_metadata(path)
                        .context("Could not inspect the pairing-code file")?;
                    validate_file(&metadata)?;
                    let file = std::fs::File::open(path)
                        .context("Could not open the pairing-code file")?;
                    validate_file(&file.metadata()?)?;
                    Box::new(file)
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
                Self::parse(&value).map(Some)
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

fn validate_file(metadata: &std::fs::Metadata) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
        bail!(
            "The pairing-code file must be a regular private file. Use `chmod 600` before installing."
        );
    }
    Ok(())
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
    fn code_sources_are_exclusive() {
        assert!(PairingCode::read(None, None).unwrap().is_none());
        assert!(PairingCode::read(Some("WXYZ1234"), Some(Path::new("unused"))).is_err());
    }
}
