// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Headless installation of the remote workspace host.

#[cfg(target_os = "linux")]
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::json;

pub fn run(
    install: bool,
    binary: Option<&Path>,
    name: Option<&str>,
    json_output: bool,
) -> Result<()> {
    let binary = resolve_binary(binary)?;
    let service = service_file(&binary)?;
    if !install {
        if json_output {
            println!("{}", json!({"binary": binary, "service": service}));
        } else {
            println!(
                "Remote host preview\n  binary: {}\n  service: {}\n\nRun `tokenstat host --install` to activate it.",
                binary.display(),
                service.display()
            );
        }
        return Ok(());
    }
    if let Some(name) = name {
        crate::render::device(None, Some(name), false, json_output)?;
    }
    install_service(&binary, &service)?;
    let identity =
        tokenstat_identity::MachineIdentity::load_or_create().map_err(anyhow::Error::msg)?;
    let result = json!({"installed": true, "service": service, "machineKey": identity.public_key_hex(), "next": "Open Devices and pair this host"});
    if json_output {
        println!("{result}");
    } else {
        println!(
            "Remote host installed.\n\nMachine key: {}\nOpen Devices on your other computer and add this host.",
            identity.public_key_hex()
        );
    }
    Ok(())
}

fn resolve_binary(given: Option<&Path>) -> Result<PathBuf> {
    let path = if let Some(path) = given {
        path.to_path_buf()
    } else {
        std::env::current_exe()?
            .parent()
            .context("CLI has no parent directory")?
            .join("tokenstat-hostd")
    };
    if !path.is_file() {
        bail!(
            "tokenstat-hostd was not found at {}. Install the host package or pass --binary.",
            path.display()
        );
    }
    Ok(path.canonicalize()?)
}

#[cfg(target_os = "macos")]
fn service_file(_: &Path) -> Result<PathBuf> {
    Ok(home_dir()?.join("Library/LaunchAgents/ai.tokenstat.hostd.plist"))
}
#[cfg(target_os = "linux")]
fn service_file(_: &Path) -> Result<PathBuf> {
    if user_id()? == 0 {
        Ok(PathBuf::from("/etc/systemd/system/tokenstat-host.service"))
    } else {
        Ok(home_dir()?.join(".config/systemd/user/tokenstat-host.service"))
    }
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn service_file(_: &Path) -> Result<PathBuf> {
    bail!("remote host installation supports macOS and Linux")
}

#[cfg(target_os = "macos")]
fn install_service(binary: &Path, _: &Path) -> Result<()> {
    // Embed the app's installer so a standalone CLI uses the same launchd
    // identity, logs and lifetime policy even without a source checkout.
    let status = Command::new("bash")
        .arg("-c")
        .arg(include_str!("../../../scripts/install-host-agent.sh"))
        .arg("tokenstat-host-install")
        .arg("--always-on")
        .arg(binary)
        .status()?;
    if !status.success() {
        bail!(
            "launchd could not activate the host. Check the installer output and run the command again."
        );
    }
    Ok(())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn install_service(_: &Path, _: &Path) -> Result<()> {
    bail!("remote host installation supports macOS and Linux")
}

#[cfg(target_os = "linux")]
fn install_service(binary: &Path, service: &Path) -> Result<()> {
    let system = user_id()? == 0;
    if !system {
        let _runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .filter(|path| path.join("bus").exists())
            .context("The user service manager is unavailable. Sign in through a normal SSH login with a systemd user session, then run the installer again. XDG_RUNTIME_DIR must point to that session's runtime directory.")?;
        let user = Command::new("id").arg("-un").output()?;
        if !user.status.success() {
            bail!("could not determine the user for the always-on service");
        }
        let user = String::from_utf8(user.stdout)?;
        eprintln!("Enabling lingering keeps your host running after you sign out.");
        let status = Command::new("loginctl")
            .args(["enable-linger", user.trim()])
            .status()?;
        if !status.success() {
            bail!(
                "Could not enable lingering. Ask the machine administrator to enable it for your account, then run the installer again."
            );
        }
    }
    let body = linux_unit(binary, system)?;
    fs::create_dir_all(service.parent().context("service path has no parent")?)?;
    atomic_write(service, body.as_bytes())?;
    for arguments in [
        vec!["daemon-reload"],
        vec!["enable", "tokenstat-host.service"],
        vec!["restart", "tokenstat-host.service"],
    ] {
        let mut command = Command::new("systemctl");
        if !system {
            command.arg("--user");
        }
        if !command.args(&arguments).status()?.success() {
            bail!(
                "systemd could not {} the host. Check tokenstat-host.service in the journal, then run the installer again.",
                arguments[0]
            );
        }
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn linux_unit(binary: &Path, system: bool) -> Result<String> {
    let path = binary
        .to_str()
        .context("host binary path must be valid UTF-8")?;
    if path.contains(['\n', '\r', '\0']) {
        bail!("host binary path contains a control character");
    }
    // systemd expands percent specifiers even inside quotes.
    let path = path
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    let target = if system {
        "multi-user.target"
    } else {
        "default.target"
    };
    Ok(format!(
        "[Unit]\nDescription=tokenstat remote host\nAfter=network-online.target\n\n[Service]\nExecStart=\"{path}\"\nRestart=always\nRestartSec=2\nSyslogIdentifier=tokenstat-hostd\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectKernelTunables=yes\nProtectControlGroups=yes\nRestrictSUIDSGID=yes\n\n[Install]\nWantedBy={target}\n"
    ))
}

#[cfg(target_os = "linux")]
fn atomic_write(path: &Path, body: &[u8]) -> Result<()> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, body).with_context(|| format!("write {}", temp.display()))?;
    fs::rename(temp, path)?;
    Ok(())
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn home_dir() -> Result<PathBuf> {
    Ok(directories::BaseDirs::new()
        .context("home directory unavailable")?
        .home_dir()
        .to_path_buf())
}
#[cfg(target_os = "linux")]
fn user_id() -> Result<u32> {
    let output = Command::new("id").arg("-u").output()?;
    if !output.status.success() {
        bail!("could not determine the current user");
    }
    String::from_utf8(output.stdout)?
        .trim()
        .parse()
        .context("invalid user id")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn linux_service_survives_logout_without_blocking_workspace_writes() {
        let unit = linux_unit(Path::new("/opt/tokenstat tools/host%$\"d"), false).unwrap();
        assert!(unit.contains("Restart=always\nRestartSec=2"));
        assert!(unit.contains("WantedBy=default.target"));
        assert!(unit.contains("host%%$$\\\"d"));
        for setting in [
            "NoNewPrivileges",
            "PrivateTmp",
            "ProtectKernelTunables",
            "ProtectControlGroups",
            "RestrictSUIDSGID",
        ] {
            assert!(unit.contains(&format!("{setting}=yes")));
        }
        assert!(!unit.contains("ProtectHome"));
        assert!(!unit.contains("ProtectSystem"));
        let system = linux_unit(Path::new("/opt/tokenstat-hostd"), true).unwrap();
        assert!(system.contains("WantedBy=multi-user.target"));
        assert!(!system.contains("User="));
        assert!(linux_unit(Path::new("/opt/host\nExecStart=other"), true).is_err());
    }

    #[test]
    fn missing_binary_is_clear() {
        let error = resolve_binary(Some(Path::new("/definitely/missing/tokenstat-hostd")))
            .unwrap_err()
            .to_string();
        assert!(error.contains("was not found"));
    }
}
