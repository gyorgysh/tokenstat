// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Service-manager operations remain available when the daemon is stopped.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

pub struct Service {
    pub path: PathBuf,
    pub scope: &'static str,
    /// The account agents on this machine run as, in words, because a root
    /// install gives every agent root and nobody should have to infer that.
    pub run_as: String,
    #[cfg(target_os = "macos")]
    domain: String,
}

impl Service {
    pub fn select(user: bool, system: bool, run_as: Option<&str>) -> Result<Self> {
        if let Some(name) = run_as {
            validate_user_name(name)?;
            if user {
                bail!("--run-as installs a system service. Omit --user.");
            }
            if cfg!(target_os = "macos") {
                bail!("macOS runs the host as the account that installed it. Omit --run-as.");
            }
        }
        let is_root = current_uid()? == "0";
        let system = select_system(
            user,
            system || run_as.is_some(),
            is_root,
            cfg!(target_os = "macos"),
        )?;
        if let Some(name) = run_as {
            account_exists(name)?;
        }
        #[cfg(target_os = "linux")]
        {
            let path = if system {
                PathBuf::from("/etc/systemd/system/tokenstat-host.service")
            } else {
                home()?.join(".config/systemd/user/tokenstat-host.service")
            };
            let run_as = match (system, run_as) {
                (false, _) => current_user()?,
                (true, Some(name)) => name.to_owned(),
                // No `User=` in a system unit means root. Read it back from
                // the unit that is actually installed rather than guessing,
                // so status describes this machine and not this command line.
                (true, None) => unit_user(&path).unwrap_or_else(|| "root".into()),
            };
            Ok(Self {
                path,
                scope: if system { "system" } else { "user" },
                run_as,
            })
        }
        #[cfg(target_os = "macos")]
        {
            let _ = system;
            Ok(Self {
                path: home()?.join("Library/LaunchAgents/ai.tokenstat.hostd.plist"),
                scope: "user",
                run_as: current_user()?,
                domain: format!("gui/{}", current_uid()?),
            })
        }
    }

    pub fn description(&self) -> Value {
        json!({
            "scope": self.scope,
            "path": self.path,
            "installed": self.path.is_file(),
            "runAs": self.run_as,
        })
    }

    pub fn control(&self, action: &str) -> Result<()> {
        if !matches!(action, "start" | "stop" | "restart") {
            bail!("Unknown service action");
        }
        self.require_installed()?;
        #[cfg(target_os = "linux")]
        {
            checked(
                self.systemctl().args([action, "tokenstat-host.service"]),
                action,
            )?;
        }
        #[cfg(target_os = "macos")]
        {
            let target = format!("{}/ai.tokenstat.hostd", self.domain);
            let loaded = Command::new("launchctl")
                .args(["print", &target])
                .output()?
                .status
                .success();
            match (action, loaded) {
                ("stop", true) => {
                    checked(Command::new("launchctl").args(["bootout", &target]), action)?;
                }
                ("stop", false) => {}
                (_, false) => {
                    checked(
                        Command::new("launchctl")
                            .arg("bootstrap")
                            .arg(&self.domain)
                            .arg(&self.path),
                        action,
                    )?;
                    checked(
                        Command::new("launchctl").args(["kickstart", &target]),
                        action,
                    )?;
                }
                ("start", true) => {
                    checked(
                        Command::new("launchctl").args(["kickstart", &target]),
                        action,
                    )?;
                }
                (_, true) => {
                    checked(
                        Command::new("launchctl").args(["kickstart", "-k", &target]),
                        action,
                    )?;
                }
            }
        }
        Ok(())
    }

    /// Stop the host and remove the service, leaving every folder alone.
    ///
    /// Removal is best effort past the point of no return: a unit that is
    /// already stopped, or already gone, must not leave the next attempt with
    /// half a service and an error.
    pub fn uninstall(&self) -> Result<()> {
        self.require_installed()?;
        #[cfg(target_os = "linux")]
        {
            let _ = self
                .systemctl()
                .args(["disable", "--now", "tokenstat-host.service"])
                .output();
            std::fs::remove_file(&self.path)
                .with_context(|| format!("Could not remove {}", self.path.display()))?;
            let _ = self.systemctl().arg("daemon-reload").output();
            let _ = self
                .systemctl()
                .args(["reset-failed", "tokenstat-host.service"])
                .output();
        }
        #[cfg(target_os = "macos")]
        {
            // The same script that installs it, so one file owns the label,
            // the plist path and the legacy cleanup.
            let status = Command::new("bash")
                .arg("-c")
                .arg(include_str!("../../../scripts/install-host-agent.sh"))
                .arg("tokenstat-host-uninstall")
                .arg("--uninstall")
                .stdout(std::process::Stdio::from(std::io::stderr()))
                .status()?;
            if !status.success() {
                bail!("launchd could not remove the host service.");
            }
        }
        Ok(())
    }

    fn require_installed(&self) -> Result<()> {
        if self.path.is_file() {
            return Ok(());
        }
        bail!(
            "No host service is installed at {}. Run `tokenstat host install` first.",
            self.path.display()
        )
    }

    pub fn logs(&self, lines: u32, follow: bool) -> Result<()> {
        #[cfg(target_os = "linux")]
        let mut command = {
            let mut command = Command::new("journalctl");
            if self.scope == "user" {
                command.arg("--user");
            }
            command
                .args([
                    "--unit",
                    "tokenstat-host.service",
                    "--no-pager",
                    "--output",
                    "cat",
                    "--lines",
                ])
                .arg(lines.to_string());
            if follow {
                command.arg("--follow");
            }
            command
        };
        #[cfg(target_os = "macos")]
        let mut command = {
            let dir = home()?.join("Library/Logs/tokenstat");
            // launchd splits the daemon's own output in two. A person asking
            // for the log wants both halves, in the order they were written.
            let files: Vec<PathBuf> = ["hostd.err.log", "hostd.out.log"]
                .iter()
                .map(|name| dir.join(name))
                .filter(|path| path.is_file())
                .collect();
            if files.is_empty() {
                bail!(
                    "The host has not written a log yet. Run `tokenstat host status` to check the service."
                );
            }
            let mut command = Command::new("tail");
            command.arg("-n").arg(lines.to_string());
            if follow {
                command.arg("-F");
            }
            command.args(&files);
            command
        };
        let status = command.status().context("Could not read the host log")?;
        if !status.success() {
            bail!("The log reader exited before finishing");
        }
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn systemctl(&self) -> Command {
        let mut command = Command::new("systemctl");
        if self.scope == "user" {
            command.arg("--user");
        }
        command
    }
}

fn checked(command: &mut Command, action: &str) -> Result<()> {
    let output = command
        .output()
        .with_context(|| format!("Could not {action} the host service"))?;
    if !output.status.success() {
        bail!(
            "Could not {action} the host service: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

fn current_uid() -> Result<String> {
    let output = Command::new("id").arg("-u").output()?;
    let uid = String::from_utf8(output.stdout)?;
    let uid = uid.trim();
    if !output.status.success() || uid.is_empty() || !uid.bytes().all(|byte| byte.is_ascii_digit())
    {
        bail!("Could not determine the current service user");
    }
    Ok(uid.to_owned())
}

pub fn current_user() -> Result<String> {
    let output = Command::new("id").arg("-un").output()?;
    let name = String::from_utf8(output.stdout)?;
    let name = name.trim();
    if !output.status.success() || name.is_empty() {
        bail!("Could not determine the current service user");
    }
    Ok(name.to_owned())
}

fn account_exists(name: &str) -> Result<()> {
    let found = Command::new("id")
        .arg("-u")
        .arg(name)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false);
    if !found {
        bail!(
            "There is no account called {name} on this machine. The installer never creates one, because a created account is the one that gets blocked later. Create it yourself, or omit --run-as."
        );
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn unit_user(path: &std::path::Path) -> Option<String> {
    let body = std::fs::read_to_string(path).ok()?;
    body.lines()
        .filter_map(|line| line.trim().strip_prefix("User="))
        .next_back()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
}

/// A unit file is line-oriented and a service name is not quoted, so an
/// account name reaches systemd exactly as typed. Refuse anything that could
/// be more than a name.
pub fn validate_user_name(name: &str) -> Result<()> {
    let valid = !name.is_empty()
        && name.len() <= 32
        && !name.starts_with('-')
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'));
    if !valid {
        bail!("--run-as takes a plain account name, like `deploy`");
    }
    Ok(())
}

fn home() -> Result<PathBuf> {
    Ok(directories::BaseDirs::new()
        .context("Home directory unavailable")?
        .home_dir()
        .to_path_buf())
}

fn select_system(user: bool, system: bool, root: bool, macos: bool) -> Result<bool> {
    if user && system {
        bail!("Choose either --user or --system");
    }
    if macos {
        if system {
            bail!("macOS uses a login agent. Omit --system.");
        }
        return Ok(false);
    }
    if system && !root {
        bail!(
            "A system service must be installed or managed from a root console. No privileges were changed."
        );
    }
    Ok(system || (root && !user))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn service_scope_never_silently_escalates() {
        assert!(!select_system(false, false, false, false).unwrap());
        assert!(select_system(false, false, true, false).unwrap());
        assert!(!select_system(true, false, true, false).unwrap());
        assert!(select_system(false, true, false, false).is_err());
        assert!(select_system(true, true, true, false).is_err());
        assert!(select_system(false, true, true, true).is_err());
        assert!(!select_system(false, false, true, true).unwrap());
    }

    #[test]
    fn run_as_never_becomes_a_second_line_in_the_unit() {
        for name in ["deploy", "web-1", "build.agent", "a_b"] {
            assert!(validate_user_name(name).is_ok());
        }
        for name in [
            "",
            "-deploy",
            "deploy\nUser=root",
            "deploy root",
            "deploy;id",
            &"a".repeat(33),
        ] {
            assert!(validate_user_name(name).is_err(), "{name} was accepted");
        }
    }

    #[test]
    fn run_as_is_a_system_service_and_says_so() {
        let error = Service::select(true, false, Some("deploy"))
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("system service"), "{error}");
        assert!(Service::select(false, false, Some("deploy nope")).is_err());
    }

    #[test]
    fn a_system_units_account_is_read_back_rather_than_assumed() {
        let dir = std::env::temp_dir().join(format!("tokenstat-unit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tokenstat-host.service");
        std::fs::write(&path, "[Service]\nExecStart=/x\nUser=deploy\n").unwrap();
        assert_eq!(unit_user(&path).as_deref(), Some("deploy"));
        std::fs::write(&path, "[Service]\nExecStart=/x\n").unwrap();
        assert_eq!(unit_user(&path), None);
        assert_eq!(unit_user(&dir.join("absent")), None);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
