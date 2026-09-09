// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! What happened to the grants on this machine, and who did it.
//!
//! On a machine nobody can walk up to, a record is the substitute for having
//! been in the room. A server is provisioned from a phone, let a second device
//! in with a code, and then runs for months: without this there is no way to
//! answer "when did that device get in, and who let it".
//!
//! What it holds is deliberately small: a time, an event, the device key, the
//! label the account already carries for that device, and which authority
//! acted. Never a path, never a folder name, never anything a person typed.
//! The file never leaves the machine.

use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Where a grant came from.
///
/// All three are the console, shifted in time: somebody who can run a command
/// on this machine, somebody who ran the installer, and somebody who minted a
/// code at one of those two. Nothing here is an authority tokenstat.ai holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Authority {
    /// A command run on this machine, or the app on the machine itself.
    Console,
    /// The install line, where the grant travelled down the SSH session.
    Install,
    /// A code minted at the console and redeemed by a device.
    Invite,
}

impl Authority {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Console => "console",
            Self::Install => "install",
            Self::Invite => "invite",
        }
    }

    /// Parse a label a local caller supplied.
    ///
    /// Only a local caller may set it, and every local caller already has the
    /// authority of the console, so this records which door was used rather
    /// than proving anything.
    pub(crate) fn parse(value: Option<&str>) -> Result<Self, String> {
        match value {
            None | Some("console") => Ok(Self::Console),
            Some("install") => Ok(Self::Install),
            Some("invite") => Ok(Self::Invite),
            Some(other) => Err(format!("unknown grant authority: {other}")),
        }
    }
}

#[derive(Deserialize, Serialize)]
pub(crate) struct Entry {
    /// Wall clock, in RFC 3339, because this is read by people.
    pub at: String,
    pub event: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub by: String,
}

/// Lines kept before the oldest are dropped.
///
/// Append-only in spirit, bounded in fact. An always-on server writing an
/// unbounded file is a disk somebody else pays for, and the recent history is
/// what anybody actually reads. The trim keeps the newest half so it happens
/// rarely rather than on every write.
const MAX_LINES: usize = 4000;

fn path() -> Result<PathBuf, String> {
    tokenstat_identity::identity_dir()
        .map(|dir| dir.join("workspace-access.log"))
        .map_err(|error| error.to_string())
}

/// Write one line. A failure here never fails the act being recorded: losing
/// the record of a grant is bad, refusing a grant because the record could not
/// be written is worse.
pub(crate) fn record(event: &str, device: Option<&str>, label: Option<&str>, by: Authority) {
    if let Err(error) = write(event, device, label, by) {
        eprintln!("workspace access log: {error}");
    }
}

fn write(
    event: &str,
    device: Option<&str>,
    label: Option<&str>,
    by: Authority,
) -> Result<(), String> {
    let entry = Entry {
        at: jiff::Timestamp::now().to_string(),
        event: event.to_owned(),
        device: device.map(str::to_owned),
        label: label.map(str::to_owned),
        by: by.as_str().to_owned(),
    };
    let mut line = serde_json::to_string(&entry).map_err(|error| error.to_string())?;
    line.push('\n');
    let path = path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    // Create with 0600 from the start: the default umask would leave device
    // keys world-readable until the chmod below.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&path)
            .map_err(|error| error.to_string())?;
        let _ = file.set_permissions(fs::Permissions::from_mode(0o600));
        file.write_all(line.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    #[cfg(not(unix))]
    {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|error| error.to_string())?;
        file.write_all(line.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    trim(&path)
}

fn trim(path: &std::path::Path) -> Result<(), String> {
    let body = fs::read_to_string(path).map_err(|error| error.to_string())?;
    let lines: Vec<&str> = body.lines().collect();
    if lines.len() <= MAX_LINES {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        }
        return Ok(());
    }
    let kept = lines[lines.len() - MAX_LINES / 2..].join("\n");
    let temp = path.with_extension("tmp");
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|error| error.to_string())?;
        file.write_all(format!("{kept}\n").as_bytes())
            .map_err(|error| error.to_string())?;
    }
    #[cfg(not(unix))]
    {
        fs::write(&temp, format!("{kept}\n")).map_err(|error| error.to_string())?;
    }
    fs::rename(&temp, path).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// The newest entries first, because that is the order somebody reads them in.
pub(crate) fn read(limit: usize) -> Result<Vec<Value>, String> {
    let body = match fs::read_to_string(path()?) {
        Ok(body) => body,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.to_string()),
    };
    Ok(body
        .lines()
        .rev()
        // A line that will not parse is skipped rather than failing the read:
        // a truncated write at the end of a file must not hide the history in
        // front of it.
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .take(limit)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_authority_is_one_of_three_doors() {
        assert_eq!(Authority::parse(None).unwrap(), Authority::Console);
        assert_eq!(Authority::parse(Some("invite")).unwrap(), Authority::Invite);
        assert!(Authority::parse(Some("tokenstat.ai")).is_err());
    }

    #[test]
    fn a_record_carries_a_device_and_never_a_path() {
        let entry = Entry {
            at: "2026-09-08T00:00:00Z".into(),
            event: "granted".into(),
            device: Some("ab".repeat(32)),
            label: Some("iPhone".into()),
            by: "invite".into(),
        };
        let line = serde_json::to_string(&entry).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&line)
                .unwrap()
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<Vec<_>>(),
            ["at", "by", "device", "event", "label"]
        );
    }
}
