// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Console controls use the same host methods as the native clients.

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use crate::{host_install, host_rpc, host_service::Service};

#[derive(Args)]
pub struct HostArgs {
    #[command(subcommand)]
    command: Option<HostCommand>,
    /// Local daemon socket, for a separately installed host
    #[arg(long, global = true, value_name = "PATH")]
    socket: Option<PathBuf>,
    /// Use this account's login service
    #[arg(long, global = true, conflicts_with = "system")]
    user: bool,
    /// Use the system service (Linux, from a root console)
    #[arg(long, global = true, conflicts_with = "user")]
    system: bool,
    /// Compatibility with the original installer
    #[arg(long, hide = true)]
    install: bool,
    #[arg(long, hide = true, value_name = "PATH")]
    binary: Option<PathBuf>,
    #[arg(long, hide = true, value_name = "NAME")]
    name: Option<String>,
}

#[derive(Args)]
struct InstallArgs {
    /// Path to tokenstat-hostd, defaults to a sibling of this CLI
    #[arg(long, value_name = "PATH")]
    binary: Option<PathBuf>,
    /// Friendly machine name for this machine on your account
    #[arg(long, value_name = "NAME")]
    name: Option<String>,
    /// Pairing code from your signed-in device
    #[arg(long, conflicts_with = "code_file")]
    code: Option<String>,
    /// Private file holding a pairing code, or - to read standard input
    #[arg(long, value_name = "PATH", conflicts_with = "code")]
    code_file: Option<PathBuf>,
    /// Account the host and its agents run as (Linux, from a root console)
    #[arg(long, value_name = "USER")]
    run_as: Option<String>,
    /// Agents to install on this machine, by id, separated by commas
    #[arg(long, value_name = "IDS", value_delimiter = ',')]
    agents: Vec<String>,
    /// Let this device key work here straight away, without a second step
    #[arg(long, value_name = "DEVICE", value_parser = peer_key)]
    allow: Option<String>,
    /// Print a one-time code for a second device when the install finishes
    #[arg(long)]
    print_invite: bool,
}

impl InstallArgs {
    fn legacy(args: &HostArgs) -> Self {
        Self {
            binary: args.binary.clone(),
            name: args.name.clone(),
            code: None,
            code_file: None,
            run_as: None,
            agents: Vec::new(),
            allow: None,
            print_invite: false,
        }
    }
}

#[derive(Subcommand)]
enum HostCommand {
    /// Show the service and the running host's state
    Status,
    /// Read the running host’s public identity without fetching account data
    Identity,
    /// Install and activate the always-on service
    Install(InstallArgs),
    /// Stop the host and remove the service, leaving every folder alone
    Uninstall {
        /// Also delete tokenstat's own data on this machine
        #[arg(long)]
        purge: bool,
        /// Do not ask for confirmation
        #[arg(long, short = 'y')]
        yes: bool,
    },
    /// Start the installed host service
    Start,
    /// Stop the host service, keeping its configuration and data
    Stop,
    /// Restart the installed service to load an updated daemon
    Restart,
    /// Read the host's log
    Logs {
        #[arg(long)]
        follow: bool,
        #[arg(short = 'n', long, default_value_t = 100, value_parser = clap::value_parser!(u32).range(1..=10000))]
        lines: u32,
    },
    /// List or change which devices may work on this machine
    Access {
        #[command(subcommand)]
        command: Option<AccessCommand>,
    },
}

#[derive(Subcommand)]
enum AccessCommand {
    /// Print a one-time code that lets one more device work here
    Invite,
    /// Show what happened to the grants on this machine
    Log {
        #[arg(short = 'n', long, default_value_t = 50, value_parser = clap::value_parser!(u32).range(1..=1000))]
        lines: u32,
    },
    /// Allow an exact device public key to reach the work here
    Allow {
        #[arg(value_parser = peer_key)]
        device: String,
    },
    /// Approve a pending request without pasting the full device key
    ///
    /// With no target it lists the pending requests and asks which to let
    /// in. Pass a list number, a key prefix, or a device label. Pass --all
    /// to approve every pending request at once. CI: --yes skips the prompt,
    /// --json prints what was approved.
    Approve {
        /// List number, key prefix, full key, or device label. Omit to choose interactively.
        target: Option<String>,
        /// Approve every pending request
        #[arg(long)]
        all: bool,
        /// Do not ask for confirmation
        #[arg(long, short = 'y')]
        yes: bool,
    },
    /// Revoke an exact device public key's access to the work here
    Deny {
        #[arg(value_parser = peer_key)]
        device: String,
    },
}

fn peer_key(value: &str) -> std::result::Result<String, String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(
            "Use the full 64-character device key shown by `tokenstat host access`.".into(),
        );
    }
    Ok(value.to_ascii_lowercase())
}

pub fn run(args: &HostArgs, json_output: bool) -> Result<()> {
    if args.install && args.command.is_some() {
        bail!("Use `tokenstat host install` without the legacy --install flag");
    }
    let legacy = args.install.then(|| InstallArgs::legacy(args));
    if !args.install && (args.binary.is_some() || args.name.is_some()) {
        bail!("--binary and --name apply to `tokenstat host install`");
    }
    let install = match &args.command {
        Some(HostCommand::Install(install)) => Some(install),
        _ => legacy.as_ref(),
    };
    let service = Service::select(
        args.user,
        args.system,
        install.and_then(|install| install.run_as.as_deref()),
    )?;
    if let Some(install) = install {
        if args.socket.is_some() {
            bail!("--socket selects a running daemon and cannot configure an installation");
        }
        let code = crate::host_enroll::PairingCode::read(
            install.code.as_deref(),
            install.code_file.as_deref(),
        )?;
        return host_install::run(
            &service,
            &host_install::Request {
                binary: install.binary.as_deref(),
                name: install.name.as_deref(),
                code: code.as_ref(),
                agents: &install.agents,
                allow: install.allow.as_deref(),
                print_invite: install.print_invite,
            },
            json_output,
        );
    }
    match &args.command {
        Some(HostCommand::Uninstall { purge, yes }) => {
            if args.socket.is_some() {
                bail!("--socket selects a running daemon and cannot remove an installation");
            }
            return uninstall(&service, *purge, *yes, json_output);
        }
        Some(HostCommand::Start | HostCommand::Stop | HostCommand::Restart) => {
            if args.socket.is_some() {
                bail!("Service controls use the installed service. Omit --socket.");
            }
            let action = match args.command {
                Some(HostCommand::Start) => "start",
                Some(HostCommand::Stop) => "stop",
                _ => "restart",
            };
            service.control(action)?;
            if json_output {
                println!("{}", json!({"action": action, "completed": true}));
            } else {
                println!("Host service {action} completed.");
            }
            return Ok(());
        }
        Some(HostCommand::Logs { follow, lines }) => {
            if args.socket.is_some() {
                bail!("Logs come from the installed service. Omit --socket.");
            }
            if json_output {
                bail!("Host logs are text. Omit --json.");
            }
            return service.logs(*lines, *follow);
        }
        _ => {}
    }
    let socket = match &args.socket {
        Some(path) => path.clone(),
        None => tokenstat_paths::data_dir()
            .context("No data directory is available")?
            .join("host.sock"),
    };
    match &args.command {
        Some(HostCommand::Identity) => {
            let identity = host_rpc::call(&socket, "machine.identity", json!({}))?;
            if json_output {
                println!("{identity}");
            } else {
                println!(
                    "{}",
                    identity["key"]
                        .as_str()
                        .context("The host returned no identity")?
                );
            }
            Ok(())
        }
        Some(HostCommand::Access { command }) => access(&socket, command.as_ref(), json_output),
        None | Some(HostCommand::Status) => status(
            &socket,
            json_output,
            args.socket.is_none().then_some(&service),
        ),
        Some(
            HostCommand::Install(_)
            | HostCommand::Uninstall { .. }
            | HostCommand::Start
            | HostCommand::Stop
            | HostCommand::Restart
            | HostCommand::Logs { .. },
        ) => unreachable!("service command handled above"),
    }
}

/// Remove the service, and only ever tokenstat's own files with it.
///
/// A registered folder is somebody's work. It is never touched here, not even
/// with `--purge`, which drops this machine's identity, settings and archive
/// and nothing outside them.
fn uninstall(service: &Service, purge: bool, assume_yes: bool, json_output: bool) -> Result<()> {
    let folders = registered_folders();
    let removable = if purge {
        data_directories()?
    } else {
        Vec::new()
    };
    if !assume_yes {
        if json_output {
            bail!("Removing a host is not reversible. Pass --yes to confirm it without a prompt.");
        }
        println!(
            "This removes the host service at {}.",
            service.path.display()
        );
        if cfg!(target_os = "macos") {
            // The app owns the same launchd label, so removing it here is not
            // the last word on this Mac and saying otherwise would be a lie.
            println!("The desktop app installs it again the next time it opens.");
        }
        if purge {
            println!("--purge also deletes this machine's tokenstat data:");
            for path in &removable {
                println!("    {}", path.display());
            }
        }
        match folders {
            Some(0) => println!("No folders are registered."),
            Some(count) => println!(
                "{count} registered folder{} stay{} exactly where {} are. Nothing in them is touched.",
                if count == 1 { "" } else { "s" },
                if count == 1 { "s" } else { "" },
                if count == 1 { "it" } else { "they" }
            ),
            None => println!("Your folders and their contents are never touched."),
        }
        if !confirm("Remove the host?")? {
            println!("Nothing was changed.");
            return Ok(());
        }
    }
    service.uninstall()?;
    let mut purged = Vec::new();
    for path in removable {
        std::fs::remove_dir_all(&path)
            .with_context(|| format!("Could not remove {}", path.display()))?;
        purged.push(path);
    }
    if json_output {
        println!(
            "{}",
            json!({"removed": true, "service": service.path, "purged": purged})
        );
        return Ok(());
    }
    println!("Removed the host service at {}.", service.path.display());
    for path in &purged {
        println!("  deleted {}", path.display());
    }
    if purged.is_empty() {
        println!("Its data is still here, so installing again picks up where this left off.");
    }
    if service.scope == "user" && cfg!(target_os = "linux") {
        println!(
            "Lingering is left enabled for this account. Turn it off with `loginctl disable-linger` if nothing else needs it."
        );
    }
    Ok(())
}

/// How many folders this machine has registered, when the host can be asked.
///
/// Best effort on purpose: a stopped host still has to be removable, and the
/// count is reassurance rather than a precondition.
fn registered_folders() -> Option<usize> {
    let socket = tokenstat_paths::data_dir()?.join("host.sock");
    host_rpc::call(&socket, "workspace.list", json!({}))
        .ok()?
        .as_array()
        .map(Vec::len)
}

/// The directories this product owns on this machine, and no others.
fn data_directories() -> Result<Vec<PathBuf>> {
    let mut paths: Vec<PathBuf> = [
        tokenstat_paths::data_dir(),
        tokenstat_paths::data_local_dir(),
        tokenstat_paths::config_dir(),
        tokenstat_paths::cache_dir(),
    ]
    .into_iter()
    .flatten()
    .filter(|path| path.is_dir())
    .collect();
    paths.sort();
    paths.dedup();
    for path in &paths {
        // A recursive delete gets one guard that does not depend on the
        // directory lookup being right.
        let ours = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains("tokenstat"));
        if !ours {
            bail!(
                "Refusing to delete {}, which is not a tokenstat directory.",
                path.display()
            );
        }
    }
    Ok(paths)
}

fn confirm(question: &str) -> Result<bool> {
    use std::io::Write;
    print!("{question} [y/N] ");
    std::io::stdout().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn access(
    socket: &std::path::Path,
    command: Option<&AccessCommand>,
    json_output: bool,
) -> Result<()> {
    match command {
        Some(AccessCommand::Invite) => return invite(socket, json_output),
        Some(AccessCommand::Log { lines }) => return log(socket, *lines, json_output),
        Some(AccessCommand::Approve { target, all, yes }) => {
            return approve(socket, target.as_deref(), *all, *yes, json_output);
        }
        _ => {}
    }
    if let Some(command) = command {
        let (device, allow) = match command {
            AccessCommand::Allow { device } => (device, true),
            AccessCommand::Deny { device } => (device, false),
            AccessCommand::Invite | AccessCommand::Log { .. } | AccessCommand::Approve { .. } => {
                unreachable!("handled above")
            }
        };
        let result = host_rpc::call(
            socket,
            "workspace.access.set",
            json!({"peerId": device, "allow": allow, "via": "console"}),
        )?;
        if json_output {
            println!("{result}");
        } else {
            println!(
                "{} access for {device}.",
                if allow { "Allowed" } else { "Revoked" }
            );
        }
        return Ok(());
    }
    let allowed = host_rpc::call(socket, "workspace.access.list", json!({}))?;
    let pending = host_rpc::call(socket, "workspace.access.pending", json!({}))?;
    if json_output {
        println!("{}", json!({"allowed":allowed,"pending":pending}));
    } else {
        println!("Allowed devices");
        for key in allowed
            .as_array()
            .context("The host returned an invalid device list")?
        {
            println!(
                "  {}",
                key.as_str()
                    .context("The host returned an invalid device key")?
            );
        }
        if allowed.as_array().is_some_and(Vec::is_empty) {
            println!("  None yet");
        }
        println!("\nPending requests");
        let pending_list = pending
            .as_array()
            .context("The host returned an invalid request list")?;
        for (index, request) in pending_list.iter().enumerate() {
            let key = request["peerId"].as_str().unwrap_or("unavailable");
            let label = request["label"].as_str().unwrap_or("");
            let name = if label.is_empty() {
                "unnamed device"
            } else {
                label
            };
            println!("  [{}] {name} ({})", index + 1, short(key));
            println!("      {key}");
        }
        if pending_list.is_empty() {
            println!("  None");
        } else {
            println!("\nApprove without pasting the key:");
            println!("  tokenstat host access approve      # choose from the list");
            println!("  tokenstat host access approve 1    # by list number");
            println!("  tokenstat host access approve --all");
            println!("\nExact key still works:");
            println!("  tokenstat host access allow <device key>");
        }
    }
    Ok(())
}

/// Approve pending requests by list number, key prefix, or label.
///
/// Numbered so a key never has to be retyped over SSH. `--all` takes every
/// pending request at once; a single target plus `--yes` (or `--json`) runs
/// without a prompt for scripts.
fn approve(
    socket: &std::path::Path,
    target: Option<&str>,
    all: bool,
    assume_yes: bool,
    json_output: bool,
) -> Result<()> {
    let pending = host_rpc::call(socket, "workspace.access.pending", json!({}))
        .map_err(|error| older_host("access requests", error))?;
    let pending_list: Vec<Value> = pending
        .as_array()
        .context("The host returned an invalid request list")?
        .clone();
    if pending_list.is_empty() {
        if json_output {
            println!("{}", json!({"approved": []}));
        } else {
            println!("No pending requests.");
        }
        return Ok(());
    }
    let keys: Vec<String> = pending_list
        .iter()
        .filter_map(|request| request["peerId"].as_str().map(str::to_owned))
        .collect();
    let chosen: Vec<String> = if all {
        keys.clone()
    } else if let Some(target) = target {
        vec![resolve_target(target, &pending_list)?]
    } else if json_output {
        bail!("Pass a list number, key, label, or --all with --json.");
    } else {
        print_pending(&pending_list);
        prompt_choices(&pending_list, &keys)?
    };
    if !json_output && !assume_yes && !prompt_confirm(&chosen, &pending_list)? {
        println!("Nothing was changed.");
        return Ok(());
    }
    let mut approved = Vec::new();
    for key in &chosen {
        host_rpc::call(
            socket,
            "workspace.access.set",
            json!({"peerId": key, "allow": true, "via": "console"}),
        )?;
        approved.push(key.clone());
    }
    if json_output {
        println!("{}", json!({"approved": approved}));
    } else if approved.len() == 1 {
        println!(
            "Allowed access for {}.",
            describe(&approved[0], &pending_list)
        );
    } else {
        println!("Allowed access for {} devices.", approved.len());
    }
    Ok(())
}

/// One pending request, by number (1-based), full key, unique key prefix, or
/// case-insensitive label. Numbers are what SSH sessions want: short, exact,
/// and visible in the list above.
fn resolve_target(target: &str, pending: &[Value]) -> Result<String> {
    let needle = target.trim();
    if let Ok(number) = needle.parse::<usize>() {
        if number >= 1 && number <= pending.len() {
            return pending[number - 1]["peerId"]
                .as_str()
                .map(str::to_owned)
                .context("The host returned an invalid device key");
        }
        bail!(
            "There are {} pending requests, so {number} is out of range.",
            pending.len()
        );
    }
    let lowered = needle.to_ascii_lowercase();
    // Full key first: exact, no ambiguity.
    if let Some(hit) = pending.iter().find(|request| {
        request["peerId"]
            .as_str()
            .is_some_and(|key| key.to_ascii_lowercase() == lowered)
    }) {
        return Ok(hit["peerId"].as_str().unwrap_or_default().to_owned());
    }
    // Key prefix, when it names exactly one request.
    let prefix: Vec<String> = pending
        .iter()
        .filter_map(|request| request["peerId"].as_str())
        .filter(|key| key.to_ascii_lowercase().starts_with(&lowered))
        .map(str::to_owned)
        .collect();
    if prefix.len() == 1 {
        return Ok(prefix[0].clone());
    }
    if prefix.len() > 1 {
        bail!(
            "{needle} matches {} pending requests. Use more of the key or a list number.",
            prefix.len()
        );
    }
    // Device label, when it names exactly one request.
    let labels: Vec<String> = pending
        .iter()
        .filter(|request| {
            request["label"]
                .as_str()
                .is_some_and(|label| label.to_ascii_lowercase().contains(&lowered))
        })
        .filter_map(|request| request["peerId"].as_str().map(str::to_owned))
        .collect();
    match labels.len() {
        1 => Ok(labels[0].clone()),
        0 => {
            bail!("No pending request matches {needle}. Use `tokenstat host access` to list them.")
        }
        _ => bail!(
            "{needle} matches {} pending requests. Use a list number instead.",
            labels.len()
        ),
    }
}

fn print_pending(pending: &[Value]) {
    println!("Pending requests");
    for (index, request) in pending.iter().enumerate() {
        println!(
            "  [{}] {}",
            index + 1,
            describe(request["peerId"].as_str().unwrap_or(""), pending)
        );
    }
}

fn describe(key: &str, pending: &[Value]) -> String {
    let label = pending
        .iter()
        .find(|request| request["peerId"].as_str() == Some(key))
        .and_then(|request| request["label"].as_str())
        .unwrap_or("");
    if label.is_empty() {
        format!("{} ({})", key, short(key))
    } else {
        format!("{label} ({})", short(key))
    }
}

fn prompt_choices(pending: &[Value], keys: &[String]) -> Result<Vec<String>> {
    use std::io::Write;
    print!(
        "Approve which? [1-{}, a for all, q to quit] ",
        pending.len()
    );
    std::io::stdout().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    let answer = answer.trim().to_ascii_lowercase();
    if answer == "q" || answer == "quit" || answer == "n" || answer == "no" || answer.is_empty() {
        bail!("Nothing was changed.");
    }
    if answer == "a" || answer == "all" {
        return Ok(keys.to_vec());
    }
    // Comma-separated numbers like `1,3` approve several at once.
    if answer.contains(',') {
        let mut out = Vec::new();
        for part in answer.split(',') {
            out.push(resolve_target(part, pending)?);
        }
        return Ok(out);
    }
    Ok(vec![resolve_target(&answer, pending)?])
}

fn prompt_confirm(chosen: &[String], pending: &[Value]) -> Result<bool> {
    use std::io::Write;
    if chosen.len() == 1 {
        print!("Allow {}? [y/N] ", describe(&chosen[0], pending));
    } else {
        print!("Allow {} devices? [y/N] ", chosen.len());
    }
    std::io::stdout().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

/// Mint the code that lets one more device in.
///
/// The console is the authority here: somebody who can run this could read the
/// folders with `cat` regardless. The code never reaches tokenstat.ai, which
/// is what keeps the account server unable to let itself in.
pub fn invite(socket: &std::path::Path, json_output: bool) -> Result<()> {
    let result = host_rpc::call(socket, "workspace.access.invite", json!({}))
        .map_err(|error| older_host("invites", error))?;
    if json_output {
        println!("{result}");
        return Ok(());
    }
    let minutes = result["expiresIn"].as_u64().unwrap_or(900) / 60;
    println!(
        "Give this to the device you want to let in. It expires in {minutes} minutes.\n\n    {}\n",
        text(&result["code"])
    );
    println!("Paste it in tokenstat under Devices, Add this device.");
    // A code only lets in a device on the same account, so a machine that is
    // signed out has nothing the code could ever match.
    if host_rpc::call(socket, "account.status", json!({}))
        .ok()
        .is_some_and(|account| account["signedIn"].as_bool() == Some(false))
    {
        println!(
            "\nThis machine is signed out, so no device can use the code yet. Sign it in with `tokenstat login --code`."
        );
    }
    Ok(())
}

fn log(socket: &std::path::Path, lines: u32, json_output: bool) -> Result<()> {
    let entries = host_rpc::call(socket, "workspace.access.log", json!({"limit": lines}))
        .map_err(|error| older_host("an access log", error))?;
    if json_output {
        println!("{entries}");
        return Ok(());
    }
    let entries = entries
        .as_array()
        .context("The host returned an invalid access log")?;
    if entries.is_empty() {
        println!("Nothing has been granted or revoked on this machine yet.");
        return Ok(());
    }
    for entry in entries {
        let device = entry["device"].as_str().unwrap_or("");
        println!(
            "{}  {:<16}  {:<8}  {}",
            when(text(&entry["at"])),
            text(&entry["event"]),
            text(&entry["by"]),
            match entry["label"].as_str() {
                Some(label) => format!("{label} ({})", short(device)),
                None if device.is_empty() => String::new(),
                None => short(device),
            }
        );
    }
    Ok(())
}

/// A daemon that predates a method answers "unknown method", which is a
/// sentence about our protocol rather than about this machine. Say what a
/// person can do instead.
fn older_host(feature: &str, error: anyhow::Error) -> anyhow::Error {
    if error.to_string().contains("unknown") {
        return anyhow::anyhow!(
            "This machine is running an older host, which has no {feature}. Update both binaries, then run `tokenstat host restart`."
        );
    }
    error
}

/// Seconds are enough. The record keeps the full stamp; a console does not
/// need six decimal places to say when somebody let a phone in.
fn when(at: &str) -> String {
    match at.split_once('.') {
        Some((head, _)) => format!("{head}Z").replace('T', " "),
        None => at.replace('T', " "),
    }
}

/// Enough of a device key to recognise, not enough to retype by mistake.
fn short(device: &str) -> String {
    if device.chars().count() <= 16 {
        return device.to_owned();
    }
    // Byte slicing panics on multi-byte chars; the audit file is locally
    // editable, so truncate on char boundaries.
    let head: String = device.chars().take(8).collect();
    let tail: String = device
        .chars()
        .rev()
        .take(8)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!("{head}…{tail}")
}

fn status(
    socket: &std::path::Path,
    json_output: bool,
    installed_service: Option<&Service>,
) -> Result<()> {
    let service = installed_service
        .map(Service::description)
        .unwrap_or(Value::Null);
    let mut report = json!({
        "socket": socket,
        "cliVersion": env!("CARGO_PKG_VERSION"),
        "service": service,
    });
    match host_rpc::call(socket, "protocol", json!({})) {
        Ok(protocol) => {
            report["running"] = json!(true);
            report["reachable"] = json!(true);
            report["protocol"] = protocol;
        }
        Err(error) => {
            // Unreachable is not the same as stopped, and saying "stopped"
            // about a host that is running behind a bad socket path sends
            // somebody to fix the wrong thing.
            report["running"] = Value::Null;
            report["reachable"] = json!(false);
            report["error"] = json!(error.to_string());
            if json_output {
                println!("{report}");
            } else {
                println!("Host unavailable");
                print_service(installed_service);
                println!("  socket: {}", socket.display());
                println!("\n{error}");
            }
            return Ok(());
        }
    }
    for (field, method) in [
        ("identity", "machine.identity"),
        ("policy", "host.policy"),
        ("remote", "remote.status"),
        ("allowed", "workspace.access.list"),
        ("pending", "workspace.access.pending"),
        ("folders", "workspace.list"),
        ("agents", "launcher.catalog"),
        ("account", "account.status"),
    ] {
        report[field] = match host_rpc::call(socket, method, json!({})) {
            Ok(value) => value,
            Err(error) => json!({"unavailable": error.to_string()}),
        };
    }
    if json_output {
        println!("{report}");
        return Ok(());
    }

    // The order is the order somebody debugs in: is it up, what is it, who is
    // it, and only then what it holds.
    println!("Host running");
    print_service(installed_service);
    println!("  socket: {}", socket.display());
    println!(
        "  protocol: {}  (host {}, CLI {})",
        text(&report["protocol"]["protocolVersion"]),
        text(&report["protocol"]["coreVersion"]),
        env!("CARGO_PKG_VERSION")
    );
    if report["protocol"]["coreVersion"].as_str() != Some(env!("CARGO_PKG_VERSION")) {
        println!(
            "    The running host and this CLI are different versions. Update both, then run `tokenstat host restart`."
        );
    }
    let account = &report["account"];
    println!(
        "  account: {}",
        match account["signedIn"].as_bool() {
            Some(false) => "signed out",
            Some(true) => account["handle"]
                .as_str()
                .or_else(|| account["displayName"].as_str())
                .unwrap_or("signed in"),
            None => "unavailable",
        }
    );
    println!(
        "  machine: {}\n  fingerprint: {}\n  always-on: {}",
        text(&report["identity"]["label"]),
        text(&report["identity"]["fingerprint"]),
        match report["policy"]["alwaysOn"].as_bool() {
            Some(true) => "on",
            Some(false) => "off",
            None => "unavailable",
        }
    );
    let remote = &report["remote"];
    println!(
        "  tunnel: {}",
        match remote["tunnelOnline"].as_bool() {
            Some(true) => "connected",
            Some(false) if remote["tunnel"].as_bool() == Some(false) => "off",
            Some(false) => "disconnected",
            None => "unavailable",
        }
    );
    if let Some(error) = remote["tunnelError"].as_str() {
        println!("    {error}");
    }
    for (field, label) in [
        ("allowed", "allowed devices"),
        ("pending", "pending requests"),
        ("folders", "registered folders"),
    ] {
        match report[field].as_array() {
            Some(items) => println!("  {label}: {}", items.len()),
            None => println!("  {label}: unavailable"),
        }
    }
    match report["agents"].as_array() {
        Some(agents) => {
            let installed: Vec<_> = agents
                .iter()
                .filter(|agent| agent["installed"].as_bool() == Some(true))
                .filter_map(|agent| agent["name"].as_str())
                .collect();
            println!(
                "  installed agents: {}",
                if installed.is_empty() {
                    "none".into()
                } else {
                    installed.join(", ")
                }
            );
        }
        None => println!("  installed agents: unavailable"),
    }
    for field in [
        "identity", "policy", "account", "remote", "allowed", "pending", "folders", "agents",
    ] {
        if let Some(error) = report[field]["unavailable"].as_str() {
            println!("\n{field}: {error}");
        }
    }
    Ok(())
}

/// Who the host runs as comes first, because a root install gives every agent
/// on this machine root and that is not something to discover later.
fn print_service(service: Option<&Service>) {
    let Some(service) = service else {
        return;
    };
    println!("  runs as: {}", service.run_as);
    if service.run_as == "root" {
        println!("    Agents on this machine run as root.");
    }
    println!(
        "  service: {} scope, {}{}",
        service.scope,
        service.path.display(),
        if service.path.is_file() {
            ""
        } else {
            "  (not installed)"
        }
    );
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap_or("unavailable")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn the_host_command_tree_parses_real_console_commands() {
        use clap::{CommandFactory, Parser};
        crate::Cli::command().debug_assert();
        for arguments in [
            vec!["tokenstat", "host"],
            vec!["tokenstat", "host", "status", "--json"],
            vec!["tokenstat", "host", "identity", "--json"],
            vec!["tokenstat", "host", "install", "--name", "server"],
            vec!["tokenstat", "host", "--install"],
            vec!["tokenstat", "host", "access"],
            vec!["tokenstat", "host", "start"],
            vec!["tokenstat", "host", "stop"],
            vec!["tokenstat", "host", "restart"],
            vec!["tokenstat", "host", "logs", "--follow", "-n", "50"],
            vec!["tokenstat", "host", "uninstall"],
            vec!["tokenstat", "host", "uninstall", "--purge", "--yes"],
            vec!["tokenstat", "host", "access", "invite"],
            vec!["tokenstat", "host", "access", "log", "-n", "10"],
            vec!["tokenstat", "host", "access", "approve"],
            vec!["tokenstat", "host", "access", "approve", "1", "--yes"],
            vec!["tokenstat", "host", "access", "approve", "--all", "--yes"],
            vec![
                "tokenstat",
                "host",
                "access",
                "approve",
                "--all",
                "--yes",
                "--json",
            ],
            vec![
                "tokenstat",
                "host",
                "install",
                "--allow",
                "ab00000000000000000000000000000000000000000000000000000000000000",
                "--print-invite",
            ],
            vec![
                "tokenstat",
                "host",
                "install",
                "--run-as",
                "deploy",
                "--agents",
                "claude_code,codex",
            ],
        ] {
            assert!(
                crate::Cli::try_parse_from(&arguments).is_ok(),
                "{arguments:?} did not parse"
            );
        }
        assert!(
            crate::Cli::try_parse_from(["tokenstat", "host", "access", "allow", "short"]).is_err()
        );
        assert!(crate::Cli::try_parse_from(["tokenstat", "host", "--binary", "/x"]).is_ok());
        // A grant is an exact key. Half of one, or a label, is not a device.
        assert!(
            crate::Cli::try_parse_from(["tokenstat", "host", "install", "--allow", "my-phone"])
                .is_err()
        );
    }

    #[test]
    fn agents_arrive_as_separate_ids() {
        use clap::Parser;
        let cli = crate::Cli::try_parse_from([
            "tokenstat",
            "host",
            "install",
            "--agents",
            "claude_code,codex",
        ])
        .unwrap();
        let Some(crate::Command::Host(args)) = &cli.command else {
            panic!("not the host command");
        };
        let Some(HostCommand::Install(install)) = &args.command else {
            panic!("not the install command");
        };
        assert_eq!(install.agents, ["claude_code", "codex"]);
    }

    #[test]
    fn an_older_host_is_named_rather_than_its_protocol_error() {
        let error = older_host(
            "invites",
            anyhow::anyhow!("workspace.access.invite: unknown workspace access method"),
        )
        .to_string();
        assert!(error.contains("older host"), "{error}");
        assert!(!error.contains("unknown workspace"), "{error}");
        // Anything else is passed through as it arrived.
        let error = older_host("invites", anyhow::anyhow!("Cannot reach the host")).to_string();
        assert_eq!(error, "Cannot reach the host");
    }

    #[test]
    fn a_log_line_is_readable_at_a_glance() {
        assert_eq!(when("2026-09-08T10:15:28.175141Z"), "2026-09-08 10:15:28Z");
        assert_eq!(when("2026-09-08T10:15:28Z"), "2026-09-08 10:15:28Z");
        assert_eq!(short(&"ab".repeat(32)), "abababab…abababab");
        assert_eq!(short("short"), "short");
    }

    #[test]
    fn purge_never_reaches_outside_this_products_own_directories() {
        for path in data_directories().unwrap() {
            let name = path.file_name().unwrap().to_str().unwrap();
            assert!(name.contains("tokenstat"), "{}", path.display());
        }
    }

    #[test]
    fn access_requires_an_exact_normalized_public_key() {
        assert_eq!(peer_key(&"AB".repeat(32)).unwrap(), "ab".repeat(32));
        for value in ["", "a-device", "abcd", &"g".repeat(64)] {
            assert!(peer_key(value).is_err());
        }
    }

    #[test]
    fn approve_targets_resolve_by_number_key_or_label() {
        let pending = vec![
            json!({"peerId": "aa".repeat(32), "label": "phone"}),
            json!({"peerId": "bb".repeat(32), "label": "tablet"}),
        ];
        assert_eq!(resolve_target("1", &pending).unwrap(), "aa".repeat(32));
        assert_eq!(resolve_target("2", &pending).unwrap(), "bb".repeat(32));
        assert!(resolve_target("3", &pending).is_err());
        assert_eq!(
            resolve_target(&"AA".repeat(32), &pending).unwrap(),
            "aa".repeat(32)
        );
        assert_eq!(
            resolve_target(&"aa".repeat(4), &pending).unwrap(),
            "aa".repeat(32)
        );
        assert_eq!(resolve_target("tablet", &pending).unwrap(), "bb".repeat(32));
        assert!(resolve_target("nope", &pending).is_err());
    }
}
