// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Generate reviewable desktop integration without changing a login session.

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};

/// Logs belong to state, separate from the shared archive and identity.
pub fn state_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
    {
        return Ok(path.join("tokenstat"));
    }
    Ok(tokenstat_paths::home_dir()
        .context("No home directory is available")?
        .join(".local/state/tokenstat"))
}

fn executable_path(path: &Path) -> Result<&str> {
    let text = path
        .to_str()
        .context("The executable path must be valid UTF-8")?;
    if !path.is_absolute() || text.chars().any(char::is_control) {
        bail!("The executable needs an absolute path without control characters");
    }
    Ok(text)
}

/// Desktop entries have two escaping layers. No shell interprets this string.
pub fn desktop_entry(binary: &Path) -> Result<String> {
    let path = executable_path(binary)?
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('`', "\\`")
        .replace('$', "\\$")
        .replace('%', "%%")
        .replace('\\', "\\\\");
    Ok(format!(
        "[Desktop Entry]\nType=Application\nName=tokenstat\nComment=Local AI usage and workspaces\nExec=\"{path}\"\nIcon=ai.tokenstat.tokenstat\nTerminal=false\nCategories=Development;Utility;\nStartupWMClass=ai.tokenstat.tokenstat\n"
    ))
}

/// This unit is not enabled at installation. Always-on is a separate choice.
/// Leave descriptor limits to the user manager: an unprivileged service
/// cannot raise its hard limit, and the host raises its own soft limit within
/// the inherited ceiling.
pub fn host_unit(binary: &Path) -> Result<String> {
    let path = executable_path(binary)?
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    Ok(format!(
        "[Unit]\nDescription=tokenstat host\nStartLimitIntervalSec=60\nStartLimitBurst=5\n\n[Service]\nType=simple\nExecStart=\"{path}\"\nRestart=on-failure\nRestartSec=2\nKillMode=mixed\nTimeoutStopSec=20\nUMask=0077\nSyslogIdentifier=tokenstat-hostd\n\n[Install]\nWantedBy=default.target\n"
    ))
}

/// Stage files for inspection or packaging. This never calls systemctl.
pub fn stage(root: &Path, installed_bin_dir: &Path) -> Result<()> {
    let desktop = root.join("share/applications");
    let services = root.join("lib/systemd/user");
    std::fs::create_dir_all(&desktop)?;
    std::fs::create_dir_all(&services)?;
    std::fs::write(
        desktop.join("ai.tokenstat.tokenstat.desktop"),
        desktop_entry(&installed_bin_dir.join("tokenstat-desktop"))?,
    )?;
    std::fs::write(
        services.join("tokenstat-host.service"),
        host_unit(&installed_bin_dir.join("tokenstat-hostd"))?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_cannot_inject_desktop_keys_or_service_commands() {
        for path in [
            "relative",
            "/opt/bad\nExec=other",
            "/opt/bad\rpath",
            "/opt/bad\tpath",
        ] {
            assert!(desktop_entry(Path::new(path)).is_err());
            assert!(host_unit(Path::new(path)).is_err());
        }
        let desktop = desktop_entry(Path::new("/opt/a b/$x%y\"`/tokenstat-desktop")).unwrap();
        assert!(desktop.contains("%%"));
        assert_eq!(
            desktop.lines().filter(|l| l.starts_with("Exec=")).count(),
            1
        );
        let unit = host_unit(Path::new("/opt/a b/$x%y\"/hostd")).unwrap();
        assert!(unit.contains("$$x%%y\\\""));
        assert!(unit.contains("Restart=on-failure\n"));
        assert!(!unit.contains("Restart=always"));
        assert!(!unit.lines().any(|line| line.starts_with("LimitNOFILE=")));
    }
}
