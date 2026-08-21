// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Headless installation of the remote workspace host.

use std::fs;
use std::path::{Path, PathBuf};
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
    Ok(home_dir()?.join("Library/LaunchAgents/ai.tokenstat.host.plist"))
}
#[cfg(target_os = "linux")]
fn service_file(_: &Path) -> Result<PathBuf> {
    Ok(home_dir()?.join(".config/systemd/user/tokenstat-host.service"))
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn service_file(_: &Path) -> Result<PathBuf> {
    bail!("remote host installation supports macOS and Linux")
}

#[cfg(target_os = "macos")]
fn install_service(binary: &Path, service: &Path) -> Result<()> {
    let parent = service.parent().context("service path has no parent")?;
    fs::create_dir_all(parent)?;
    let body = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>ai.tokenstat.host</string><key>ProgramArguments</key><array><string>{}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>\n",
        xml(binary.to_string_lossy().as_ref())
    );
    atomic_write(service, body.as_bytes())?;
    let domain = format!("gui/{}", user_id());
    let _ = Command::new("launchctl")
        .args(["bootout", &domain, service.to_string_lossy().as_ref()])
        .status();
    let status = Command::new("launchctl")
        .args(["bootstrap", &domain, service.to_string_lossy().as_ref()])
        .status()?;
    if !status.success() {
        bail!("launchctl could not activate {}", service.display());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn install_service(binary: &Path, service: &Path) -> Result<()> {
    fs::create_dir_all(service.parent().context("service path has no parent")?)?;
    let body = format!(
        "[Unit]\nDescription=tokenstat remote host\nAfter=network-online.target\n\n[Service]\nExecStart={}\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n",
        binary.display()
    );
    atomic_write(service, body.as_bytes())?;
    let status = Command::new("systemctl")
        .args(["--user", "enable", "--now", "tokenstat-host.service"])
        .status()?;
    if !status.success() {
        bail!("systemd could not activate {}", service.display());
    }
    Ok(())
}

fn atomic_write(path: &Path, body: &[u8]) -> Result<()> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, body).with_context(|| format!("write {}", temp.display()))?;
    fs::rename(temp, path)?;
    Ok(())
}

fn home_dir() -> Result<PathBuf> {
    Ok(directories::BaseDirs::new()
        .context("home directory unavailable")?
        .home_dir()
        .to_path_buf())
}
#[cfg(target_os = "macos")]
fn xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}
#[cfg(target_os = "macos")]
fn user_id() -> u32 {
    std::process::Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_binary_is_clear() {
        let error = resolve_binary(Some(Path::new("/definitely/missing/tokenstat-hostd")))
            .unwrap_err()
            .to_string();
        assert!(error.contains("was not found"));
    }
}
