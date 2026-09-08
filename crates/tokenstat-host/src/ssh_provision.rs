// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Setting a machine up over the SSH session a person just opened.
//!
//! This is the provisioning plane, and its whole rule is in one sentence:
//! **it may install and enroll, and it may not do work.** Cloning a folder,
//! launching an agent and opening a terminal all happen afterwards, over the
//! tunnel, through the same methods every other machine uses. If something
//! here wants to reach for the SSH channel after enrollment, the host is
//! missing a method.
//!
//! Nothing a caller sends becomes a command. The three things this runs on the
//! far side are written out below, in full, and a client picks one by name.

use serde::Deserialize;
use serde_json::{Value, json};

/// Where the pairing code is put while the installer reads it.
///
/// A file, not the command line. On the command line the code lands in the
/// shell history and, briefly, in `/proc`, and somebody who finds a credential
/// in `~/.bash_history` is right to stop believing everything else this
/// product says about privacy. It is written on its own channel, so the
/// interactive shell never sees it either.
pub(crate) const CODE_PATH: &str = "$HOME/.tokenstat-pairing";

/// What this machine is, before anything is written to it.
///
/// One `sh` script rather than several round trips, and every line is a
/// question somebody would ask before trusting a server with an installer.
/// It writes nothing and changes nothing.
pub(crate) const CHECK_SCRIPT: &str = concat!(
    "echo os=$(uname -s); ",
    "echo arch=$(uname -m); ",
    "echo uid=$(id -u); ",
    "echo user=$(id -un); ",
    "echo home=$HOME; ",
    "if [ -r /etc/os-release ]; then . /etc/os-release; echo distro=\"$NAME $VERSION_ID\"; fi; ",
    "command -v systemctl >/dev/null 2>&1 && echo systemd=yes || echo systemd=no; ",
    "command -v curl >/dev/null 2>&1 && echo curl=yes || echo curl=no; ",
    "command -v git >/dev/null 2>&1 && echo git=yes || echo git=no; ",
    "[ -w \"$HOME\" ] && echo homeWritable=yes || echo homeWritable=no; ",
    "command -v tokenstat >/dev/null 2>&1 && echo installed=yes || echo installed=no; ",
    "echo diskFreeMb=$(df -Pm \"$HOME\" 2>/dev/null | awk 'NR==2 {print $4}')",
);

pub(crate) fn stage_code_command() -> String {
    format!("umask 077; set -C; cat > \"{CODE_PATH}\"")
}

pub(crate) fn clear_code_command() -> String {
    format!("rm -f \"{CODE_PATH}\"")
}

/// Turn the script's key=value lines into an answer a screen can read.
///
/// Unknown keys are dropped rather than passed through: this is output from
/// somebody else's machine, and the shape of the answer is decided here.
pub(crate) fn parse_check(output: &str) -> Value {
    let mut facts = serde_json::Map::new();
    for line in output.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        let key = key.trim();
        match key {
            "os" | "arch" | "user" | "home" | "distro" => {
                if !value.is_empty() {
                    facts.insert(key.to_string(), json!(value));
                }
            }
            "systemd" | "curl" | "git" | "homeWritable" | "installed" => {
                facts.insert(key.to_string(), json!(value == "yes"));
            }
            "uid" => {
                if let Ok(uid) = value.parse::<u32>() {
                    facts.insert("uid".into(), json!(uid));
                    facts.insert("root".into(), json!(uid == 0));
                }
            }
            "diskFreeMb" => {
                if let Ok(free) = value.parse::<u64>() {
                    facts.insert("diskFreeMb".into(), json!(free));
                }
            }
            _ => {}
        }
    }
    // The one judgement this makes, so the wizard and the by-hand screen agree
    // on what "ready" means rather than each deciding.
    let yes = |key: &str| facts.get(key).and_then(Value::as_bool) == Some(true);
    let linux = facts.get("os").and_then(Value::as_str) == Some("Linux");
    let mut blockers: Vec<&str> = Vec::new();
    if !linux {
        blockers.push("This only sets up a Linux server. A Mac gets the desktop app instead.");
    }
    if !yes("systemd") {
        blockers.push("systemd is not on this machine, and the always-on service needs it.");
    }
    if !yes("curl") {
        blockers.push("curl is not installed, and the installer is fetched with it.");
    }
    if !yes("homeWritable") {
        blockers.push("This account cannot write to its own home directory.");
    }
    if facts
        .get("diskFreeMb")
        .and_then(Value::as_u64)
        .is_some_and(|free| free < 200)
    {
        blockers.push("There is less than 200 MB free.");
    }
    facts.insert("blockers".into(), json!(blockers));
    facts.insert("ready".into(), json!(blockers.is_empty()));
    Value::Object(facts)
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct LineParams {
    /// This device's public key, granted at install time over the console.
    #[serde(default)]
    pub allow: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub agents: Vec<String>,
    #[serde(default)]
    pub print_invite: bool,
    /// Whether the code was staged in a file first. A person pasting this
    /// themselves has the code on their screen instead.
    #[serde(default)]
    pub code_file: bool,
    #[serde(default)]
    pub code: Option<String>,
}

/// The install line, in the two shapes it is needed in.
///
/// `oneLine` is what the app types into the session it opened. `annotated` is
/// the same command for somebody who would rather run it themselves, with a
/// comment per flag, because that one is read as well as run.
///
/// Both are composed here rather than in a client, so the two cannot drift and
/// a third front end does not invent a third spelling.
pub(crate) fn install_line(p: &LineParams) -> Result<Value, String> {
    let mut flags: Vec<(String, &'static str)> = vec![(
        "--host".into(),
        "install the always-on host as well as the CLI",
    )];
    if p.code_file {
        flags.push((
            format!("--code-file \"{}\"", super::ssh_provision::CODE_PATH),
            "sign this machine in with the code already written there",
        ));
    } else if let Some(code) = p.code.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
        validate_code(code)?;
        flags.push((
            format!("--code {code}"),
            "sign this machine in to your account, once, within fifteen minutes",
        ));
    }
    if let Some(allow) = p.allow.as_deref().map(str::trim).filter(|a| !a.is_empty()) {
        validate_hex_key(allow)?;
        flags.push((
            format!("--allow {allow}"),
            "let the device you are holding open the work here",
        ));
    }
    if let Some(name) = p.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        flags.push((
            format!("--name {}", shell_quote(name)?),
            "what this machine is called on your account",
        ));
    }
    if !p.agents.is_empty() {
        for agent in &p.agents {
            validate_agent_id(agent)?;
        }
        flags.push((
            format!("--agents {}", p.agents.join(",")),
            "install these agents on the machine that will run them",
        ));
    }
    if p.print_invite {
        flags.push((
            "--print-invite".into(),
            "print a one-time code for a second device when it finishes",
        ));
    }
    let one_line = format!(
        "curl -fsSL https://tokenstat.ai/install.sh | bash -s -- {}",
        flags
            .iter()
            .map(|(flag, _)| flag.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    );
    // Comments belong on separate lines: a backslash followed by a comment
    // escapes a space, not the newline, and silently drops the remaining flags.
    let mut annotated = flags
        .iter()
        .map(|(flag, why)| format!("# {flag}: {why}\n"))
        .collect::<String>();
    annotated.push_str(&one_line);
    Ok(json!({"oneLine": one_line, "annotated": annotated.trim_end()}))
}

/// Anything that reaches a shell is checked here, by shape, before it does.
fn validate_hex_key(value: &str) -> Result<(), String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("A device key is 64 hexadecimal characters.".into());
    }
    Ok(())
}

fn validate_code(value: &str) -> Result<(), String> {
    let plain: String = value.chars().filter(|c| *c != '-').collect();
    if plain.len() != 8 || !plain.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        return Err("A pairing code is eight letters or digits.".into());
    }
    Ok(())
}

fn validate_agent_id(value: &str) -> Result<(), String> {
    let valid = !value.is_empty()
        && value.len() <= 40
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-');
    if valid {
        Ok(())
    } else {
        Err(format!("{value} is not an agent id."))
    }
}

/// A machine name is the one field a person types freely, so it is the one
/// field that is quoted rather than merely checked.
fn shell_quote(value: &str) -> Result<String, String> {
    if value.len() > 64 || value.chars().any(char::is_control) {
        return Err("That name is too long or has a control character in it.".into());
    }
    Ok(format!("'{}'", value.replace('\'', "'\\''")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn annotated_command_preserves_every_argument() {
        let line = install_line(&LineParams {
            allow: Some("ab".repeat(32)),
            name: Some("cloud one's machine".into()),
            agents: vec!["claude_code".into(), "codex".into()],
            code_file: true,
            ..Default::default()
        })
        .unwrap();
        // Replace the network/installer pipeline with an argument printer.
        let script = line["annotated"].as_str().unwrap().replace(
            "curl -fsSL https://tokenstat.ai/install.sh | bash -s --",
            "printf '%s\\n'",
        );
        let output = std::process::Command::new("sh")
            .args(["-c", &script])
            .env("HOME", "/tmp/home with spaces")
            .output()
            .unwrap();
        assert!(output.status.success(), "{:?}", output);
        assert_eq!(
            String::from_utf8(output.stdout)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            vec![
                "--host",
                "--code-file",
                "/tmp/home with spaces/.tokenstat-pairing",
                "--allow",
                &"ab".repeat(32),
                "--name",
                "cloud one's machine",
                "--agents",
                "claude_code,codex"
            ]
        );
    }

    #[test]
    #[cfg(unix)]
    fn staging_never_overwrites_an_existing_file() {
        let root = std::env::temp_dir().join(format!("tokenstat-stage-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join(".tokenstat-pairing");
        std::fs::write(&path, "keep me").unwrap();
        let output = std::process::Command::new("sh")
            .args(["-c", &stage_code_command()])
            .env("HOME", &root)
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "keep me");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_check_reads_as_facts_and_one_verdict() {
        let facts = parse_check(
            "os=Linux\narch=x86_64\nuid=0\nuser=root\nhome=/root\n\
             distro=Ubuntu 24.04\nsystemd=yes\ncurl=yes\ngit=yes\n\
             homeWritable=yes\ninstalled=no\ndiskFreeMb=40960\nrogue=whatever\n",
        );
        assert_eq!(facts["os"], "Linux");
        assert_eq!(facts["root"], true);
        assert_eq!(facts["ready"], true);
        assert_eq!(facts["blockers"].as_array().unwrap().len(), 0);
        assert!(facts.get("rogue").is_none(), "unknown keys are dropped");

        let poor = parse_check("os=Darwin\nsystemd=no\ncurl=no\nhomeWritable=no\ndiskFreeMb=10\n");
        assert_eq!(poor["ready"], false);
        assert_eq!(poor["blockers"].as_array().unwrap().len(), 5);
        assert_eq!(poor["root"], Value::Null);
    }

    #[test]
    fn nothing_a_caller_sends_can_become_another_command() {
        let line = install_line(&LineParams {
            allow: Some("ab".repeat(32)),
            name: Some("cloud one".into()),
            agents: vec!["claude_code".into(), "codex".into()],
            print_invite: true,
            code_file: true,
            code: None,
        })
        .unwrap();
        let one = line["oneLine"].as_str().unwrap();
        assert!(one.contains("--host"));
        assert!(one.contains("--code-file \"$HOME/.tokenstat-pairing\""));
        assert!(one.contains("--name 'cloud one'"));
        assert!(one.contains("--agents claude_code,codex"));
        assert!(
            line["annotated"]
                .as_str()
                .unwrap()
                .contains("what this machine is called")
        );

        assert!(
            install_line(&LineParams {
                allow: Some("nope".into()),
                ..Default::default()
            })
            .is_err()
        );
        assert!(
            install_line(&LineParams {
                agents: vec!["x; id".into()],
                ..Default::default()
            })
            .is_err()
        );
        assert!(
            install_line(&LineParams {
                code: Some("WXYZ; id".into()),
                ..Default::default()
            })
            .is_err()
        );
        let quoted = install_line(&LineParams {
            name: Some("a'; rm -rf / #".into()),
            ..Default::default()
        })
        .unwrap();
        assert!(
            quoted["oneLine"]
                .as_str()
                .unwrap()
                .contains("--name 'a'\\''; rm -rf / #'")
        );
    }
}
