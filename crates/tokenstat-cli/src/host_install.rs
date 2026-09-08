// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Headless installation of the remote workspace host.

#[cfg(target_os = "linux")]
use std::fs;
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::process::Command;

use crate::host_service::Service;
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

pub struct Request<'a> {
    pub binary: Option<&'a Path>,
    pub name: Option<&'a str>,
    pub code: Option<&'a crate::host_enroll::PairingCode>,
    pub agents: &'a [String],
    /// The device that installed this host, granted over the console rather
    /// than through the account server. See the plan's section 7.
    pub allow: Option<&'a str>,
    pub print_invite: bool,
}

pub fn run(service: &Service, request: &Request<'_>, json_output: bool) -> Result<()> {
    let Request {
        binary,
        name,
        code,
        agents,
        allow,
        print_invite,
    } = *request;
    // Enrollment and socket RPC currently run as the installer. A system
    // unit for another user would read a different identity and data directory.
    // Refuse before redeeming a one-time code or changing a service.
    if service.run_as != crate::host_service::current_user()? {
        bail!(
            "Installing for another account is not supported yet. Sign in as {} and run `tokenstat host --user install` so enrollment and the daemon use the same identity.",
            service.run_as
        );
    }
    let binary = resolve_binary(binary)?;
    if let Some(name) = name {
        tokenstat_identity::set_machine_label(name).map_err(anyhow::Error::msg)?;
    }
    let account = code
        .map(crate::host_enroll::PairingCode::redeem)
        .transpose()?;
    install_service(&binary, service)?;
    let socket = tokenstat_paths::data_dir()
        .context("No data directory is available")?
        .join("host.sock");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let protocol = loop {
        match crate::host_rpc::call(&socket, "protocol", json!({})) {
            Ok(value) => break value,
            Err(error) if std::time::Instant::now() >= deadline => return Err(error).context("The service was installed but has not become ready. Check `tokenstat host logs`, then run the installer again."),
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(200)),
        }
    };
    if protocol["coreVersion"].as_str() != Some(env!("CARGO_PKG_VERSION")) {
        bail!(
            "The service started a different host version. Check `tokenstat host status` and the service binary path before pairing."
        );
    }
    crate::host_rpc::call(&socket, "host.setPolicy", json!({"alwaysOn":true}))?;
    crate::host_rpc::call(&socket, "remote.serve", json!({"tunnel":true}))?;
    if let Some(name) = name {
        crate::host_rpc::call(&socket, "machine.rename", json!({"name":name}))?;
    }
    let identity = crate::host_rpc::call(&socket, "machine.identity", json!({}))?;
    // The grant travels down the console the installer is already running on,
    // and never through tokenstat.ai. A server that could hand itself a grant
    // for a key of its own choosing would undo the whole claim.
    if let Some(device) = allow {
        crate::host_rpc::call(
            &socket,
            "workspace.access.set",
            json!({"peerId": device, "allow": true, "via": "install"}),
        )?;
    }
    let invite = if print_invite {
        Some(crate::host_rpc::call(
            &socket,
            "workspace.access.invite",
            json!({}),
        )?)
    } else {
        None
    };
    let installed_agents = install_agents(&socket, agents, json_output)?;
    let result = json!({
        "installed": true,
        "service": service.description(),
        "account": account,
        "machineKey": identity["key"],
        "protocolVersion": protocol["protocolVersion"],
        "hostVersion": protocol["coreVersion"],
        "alwaysOn": true,
        "tunnelEnabled": true,
        "agents": installed_agents,
        "allowed": allow,
        "invite": invite,
    });
    if json_output {
        println!("{result}");
        return Ok(());
    }
    println!(
        "Host installed and running.\n  service: {}\n  runs as: {}\n  always-on: on\n  remote reach: enabled\n  machine key: {}",
        service.path.display(),
        service.run_as,
        identity["key"].as_str().unwrap_or("unavailable")
    );
    if service.run_as == "root" {
        println!("  Agents on this machine will run as root.");
    }
    if let Some(device) = allow {
        println!("  allowed: {device}");
    }
    match account {
        Some(account) => println!("  signed in: {account}"),
        None => println!(
            "\nUse `tokenstat login --code` to sign in if this machine is not already linked."
        ),
    }
    for agent in installed_agents.iter().filter_map(Value::as_object) {
        let name = agent["name"].as_str().unwrap_or("agent");
        match agent["state"].as_str() {
            Some("installed") => println!("  installed {name}"),
            Some("present") => println!("  {name} was already installed"),
            _ => println!(
                "  could not install {name}: {}",
                agent["error"].as_str().unwrap_or("unknown reason")
            ),
        }
    }
    if let Some(invite) = &invite {
        println!(
            "\nOne more device can be let in with this code, for the next {} minutes:\n\n    {}\n",
            invite["expiresIn"].as_u64().unwrap_or(900) / 60,
            invite["code"].as_str().unwrap_or("unavailable")
        );
        println!("Paste it in tokenstat under Devices, Add this device.");
    }
    println!("\nRun `tokenstat host status` to check the tunnel and allowed devices.");
    Ok(())
}

/// Install the agents the wizard asked for, on the machine that will run them.
///
/// A failure here is reported and not fatal: the host is up, signed in and
/// reachable, and an agent that would not install is something a person can
/// retry from the app rather than a reason to leave a machine half set up.
fn install_agents(socket: &Path, agents: &[String], json_output: bool) -> Result<Vec<Value>> {
    if agents.is_empty() {
        return Ok(Vec::new());
    }
    let catalog = crate::host_rpc::call(socket, "launcher.catalog", json!({}))?;
    let mut report = Vec::new();
    for agent in agent_plan(&catalog, agents)? {
        if agent.present {
            report.push(json!({"id": agent.id, "name": agent.name, "state": "present"}));
            continue;
        }
        if !json_output {
            println!(
                "Installing {} on this machine. This can take a minute.",
                agent.name
            );
        }
        report.push(
            match crate::host_rpc::call(socket, "launcher.install", json!({"id": agent.id})) {
                Ok(_) => json!({"id": agent.id, "name": agent.name, "state": "installed"}),
                Err(error) => json!({
                    "id": agent.id,
                    "name": agent.name,
                    "state": "failed",
                    "error": error.to_string(),
                }),
            },
        );
    }
    Ok(report)
}

struct PlannedAgent {
    id: String,
    name: String,
    present: bool,
}

/// Resolve the ids somebody typed against the catalog of the machine that
/// would run them, so an unknown id fails before anything is installed.
fn agent_plan(catalog: &Value, agents: &[String]) -> Result<Vec<PlannedAgent>> {
    let catalog = catalog
        .as_array()
        .context("The host returned an invalid agent catalog")?;
    agents
        .iter()
        .map(|id| {
            let profile = catalog
                .iter()
                .find(|profile| profile["id"].as_str() == Some(id.as_str()))
                .with_context(|| {
                    let known: Vec<&str> = catalog
                        .iter()
                        .filter_map(|profile| profile["id"].as_str())
                        .filter(|known| *known != "shell")
                        .collect();
                    format!(
                        "{id} is not an agent this machine knows. It has: {}",
                        known.join(", ")
                    )
                })?;
            Ok(PlannedAgent {
                id: id.clone(),
                name: profile["name"].as_str().unwrap_or(id).to_owned(),
                present: profile["installed"].as_bool() == Some(true),
            })
        })
        .collect()
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
    let path = path.canonicalize()?;
    let output = Command::new(&path)
        .arg("--version")
        .output()
        .context("Could not run tokenstat-hostd")?;
    if !output.status.success()
        || String::from_utf8_lossy(&output.stdout).trim()
            != format!("tokenstat-hostd {}", env!("CARGO_PKG_VERSION"))
    {
        bail!(
            "The host binary does not match this CLI version. Install both binaries from the same release."
        );
    }
    Ok(path)
}

#[cfg(target_os = "macos")]
fn install_service(binary: &Path, _: &Service) -> Result<()> {
    // Embed the app's installer so a standalone CLI uses the same launchd
    // identity, logs and lifetime policy even without a source checkout.
    let status = Command::new("bash")
        .arg("-c")
        .arg(include_str!("../../../scripts/install-host-agent.sh"))
        .arg("tokenstat-host-install")
        .arg("--always-on")
        .arg(binary)
        .stdout(std::process::Stdio::from(std::io::stderr()))
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
fn install_service(binary: &Path, service: &Service) -> Result<()> {
    let system = service.scope == "system";
    let run_as = (system && service.run_as != "root").then_some(service.run_as.as_str());
    let service = &service.path;
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
    let body = linux_unit(binary, system, run_as)?;
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
fn linux_unit(binary: &Path, system: bool, run_as: Option<&str>) -> Result<String> {
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
    let account = match run_as {
        Some(name) => {
            crate::host_service::validate_user_name(name)?;
            format!("User={name}\n")
        }
        None => String::new(),
    };
    Ok(format!(
        "[Unit]\nDescription=tokenstat remote host\nAfter=network-online.target\n\n[Service]\nExecStart=\"{path}\"\n{account}Restart=always\nRestartSec=2\nSyslogIdentifier=tokenstat-hostd\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectKernelTunables=yes\nProtectControlGroups=yes\nRestrictSUIDSGID=yes\n\n[Install]\nWantedBy={target}\n"
    ))
}

#[cfg(target_os = "linux")]
fn atomic_write(path: &Path, body: &[u8]) -> Result<()> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, body).with_context(|| format!("write {}", temp.display()))?;
    fs::rename(temp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn linux_service_survives_logout_without_blocking_workspace_writes() {
        let unit = linux_unit(Path::new("/opt/tokenstat tools/host%$\"d"), false, None).unwrap();
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
        let system = linux_unit(Path::new("/opt/tokenstat-hostd"), true, None).unwrap();
        assert!(system.contains("WantedBy=multi-user.target"));
        assert!(!system.contains("User="));
        assert!(linux_unit(Path::new("/opt/host\nExecStart=other"), true, None).is_err());
    }

    #[test]
    fn a_run_as_unit_names_one_account_and_nothing_else() {
        let unit = linux_unit(Path::new("/opt/tokenstat-hostd"), true, Some("deploy")).unwrap();
        assert!(unit.contains("\nUser=deploy\nRestart=always"));
        assert_eq!(unit.matches("User=").count(), 1);
        assert!(linux_unit(Path::new("/opt/tokenstat-hostd"), true, Some("a b")).is_err());
        assert!(
            linux_unit(
                Path::new("/opt/tokenstat-hostd"),
                true,
                Some("deploy\nExecStart=/x")
            )
            .is_err()
        );
    }

    #[test]
    fn an_unknown_agent_id_fails_before_anything_is_installed() {
        let catalog = serde_json::json!([
            {"id": "shell", "name": "Shell", "installed": true},
            {"id": "claude_code", "name": "Claude Code", "installed": false},
            {"id": "codex", "name": "Codex", "installed": true},
        ]);
        let plan = agent_plan(&catalog, &["claude_code".into(), "codex".into()]).unwrap();
        assert_eq!(plan.len(), 2);
        assert!(!plan[0].present && plan[0].name == "Claude Code");
        assert!(plan[1].present);
        let error = agent_plan(&catalog, &["claude".into()])
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("claude_code, codex"), "{error}");
        assert!(!error.contains("shell"), "{error}");
        assert!(agent_plan(&serde_json::json!({}), &["codex".into()]).is_err());
    }

    #[test]
    fn missing_binary_is_clear() {
        let error = resolve_binary(Some(Path::new("/definitely/missing/tokenstat-hostd")))
            .unwrap_err()
            .to_string();
        assert!(error.contains("was not found"));
    }
}
