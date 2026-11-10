// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Device presentation/selection from Machine, ClientDeviceIcon and MachinesModel.
//! Account status remains the source of these records; no peer is contacted here.

use crate::localization;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    #[serde(rename = "id")]
    pub machine_id: Option<String>,
    pub label: Option<String>,
    pub last_sync_at: Option<String>,
    pub online: Option<bool>,
    pub last_seen_at: Option<String>,
    pub public_identity: Option<String>,
    pub trust_state: Option<String>,
    pub kind: Option<String>,
    pub platform: Option<String>,
    pub label_source: Option<String>,
}
impl Machine {
    pub fn id(&self) -> &str {
        self.machine_id
            .as_deref()
            .or(self.label.as_deref())
            .unwrap_or("unidentified")
    }
    pub fn is_host(&self) -> bool {
        self.kind.as_deref() != Some("client")
    }
    pub fn display_name(&self) -> String {
        self.label
            .as_deref()
            .filter(|s| !s.is_empty())
            .or(self.machine_id.as_deref())
            .map(str::to_owned)
            .unwrap_or_else(|| localization::text("apple.models.unnamed_device.72ac73e4", &[]))
    }
    pub fn subtitle(&self) -> Option<&str> {
        self.label
            .as_deref()
            .filter(|s| !s.is_empty())
            .and(self.machine_id.as_deref())
    }
    pub fn home_label(&self) -> String {
        self.label
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(|| localization::text("apple.desktophomework.device.6ba0bdec", &[]))
    }
    pub fn home_status(&self) -> String {
        localization::text(
            match self.online {
                Some(true) => "apple.desktophomework.awake.9123b5f4",
                Some(false) => "apple.desktophomework.asleep.60135e8f",
                None => "apple.desktophomework.status_unknown.e412d872",
            },
            &[],
        )
    }
    pub fn symbol(&self) -> &'static str {
        device_symbol(
            Some(self.label.as_deref().unwrap_or(&self.display_name())),
            self.is_host(),
            self.platform.as_deref(),
        )
    }
    pub fn fixture() -> Vec<Self> {
        [
            ("studio", "Studio", Some(true), "host", "macOS"),
            (
                "linux",
                "Linux laptop",
                Some(false),
                "host",
                "Ubuntu 24.04 · x86_64",
            ),
            ("phone", "iPhone", None, "client", "iOS"),
        ]
        .into_iter()
        .map(|(id, name, online, kind, platform)| Self {
            machine_id: Some(id.into()),
            label: Some(name.into()),
            online,
            kind: Some(kind.into()),
            platform: Some(platform.into()),
            ..Self::default()
        })
        .collect()
    }
}
pub fn device_symbol(name: Option<&str>, is_host: bool, platform: Option<&str>) -> &'static str {
    let lower = [name, platform]
        .into_iter()
        .flatten()
        .map(|s| s.trim_matches(|c: char| c.is_whitespace() || c == '\u{200b}'))
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    if ["ipad", "ipados"].iter().any(|s| lower.contains(s)) {
        return "ipad";
    }
    if ["iphone", "ipod"].iter().any(|s| lower.contains(s)) {
        return "iphone";
    }
    if !is_host {
        return if lower.contains("android") && (lower.contains("tablet") || lower.contains("tab "))
        {
            "ipad"
        } else {
            "iphone"
        };
    }
    if ["macbook", "laptop", "thinkpad"]
        .iter()
        .any(|s| lower.contains(s))
    {
        return "laptopcomputer";
    }
    if ["imac", "mac studio", "mac mini", "mac pro", "desktop"]
        .iter()
        .any(|s| lower.contains(s))
    {
        return "desktopcomputer";
    }
    if ["server", "linux", "ubuntu", "windows"]
        .iter()
        .any(|s| lower.contains(s))
    {
        return "server.rack";
    }
    "desktopcomputer"
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceKind {
    ThisMachine,
    Peer(String),
    Account(String),
}
#[derive(Clone, Debug, Default)]
pub struct Selection {
    pub kind: Option<DeviceKind>,
}
impl Selection {
    pub fn select_account(&mut self, machine: &Machine) {
        self.kind = Some(DeviceKind::Account(machine.id().into()));
    }
    pub fn account<'a>(&self, machines: &'a [Machine]) -> Option<&'a Machine> {
        let Some(DeviceKind::Account(id)) = &self.kind else {
            return None;
        };
        machines
            .iter()
            .find(|m| m.machine_id.as_deref() == Some(id.as_str()) || m.id() == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection_keeps_a_key_and_resolves_the_latest_record_or_absence() {
        let mut machines = Machine::fixture();
        let mut selection = Selection::default();
        selection.select_account(&machines[0]);
        machines[0].label = Some("Renamed".into());
        assert_eq!(
            selection.account(&machines).unwrap().home_label(),
            "Renamed"
        );
        machines.remove(0);
        assert!(selection.account(&machines).is_none());
        selection.kind = Some(DeviceKind::Peer("studio".into()));
        assert!(selection.account(&machines).is_none());
    }
    #[test]
    fn status_and_host_are_not_guessed_and_malformed_wire_values_fail() {
        let machine: Machine = serde_json::from_str("{}").unwrap();
        assert!(machine.online.is_none() && machine.is_host());
        assert_eq!(machine.id(), "unidentified");
        assert_ne!(machine.home_label(), machine.display_name());
        assert!(serde_json::from_str::<Machine>(r#"{"online":"true"}"#).is_err());
        assert!(serde_json::from_str::<Machine>(r#"{"id":3}"#).is_err());
    }
}
