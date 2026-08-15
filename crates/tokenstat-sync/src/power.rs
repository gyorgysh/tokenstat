// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted.

//! Small power-state checks for work that a scheduler may defer.

/// Whether the machine is fully awake right now.
///
/// macOS can launch `launchd` jobs during DarkWake. `IOPMUserIsActive` is the
/// system's current full-wake signal. Other platforms do not have this
/// macOS-specific state and keep their existing behavior.
#[cfg(target_os = "macos")]
fn system_is_awake() -> bool {
    let output = std::process::Command::new("/usr/sbin/ioreg")
        .args(["-rd1", "-c", "IOPMrootDomain"])
        .output();
    output.is_ok_and(|output| output.status.success() && ioreg_user_is_active(&output.stdout))
}

/// Whether scheduled network work may run now.
///
/// Battery Macs with Always-on host disabled avoid network work during sleep
/// and DarkWake. A non-battery Mac, or a user who explicitly enabled
/// Always-on host, keeps its existing always-available behavior.
pub fn scheduled_network_allowed() -> bool {
    platform_scheduled_network_allowed()
}

#[cfg(target_os = "macos")]
fn platform_scheduled_network_allowed() -> bool {
    schedule_allowed(
        has_internal_battery(),
        always_on_host_enabled(),
        system_is_awake(),
    )
}

#[cfg(not(target_os = "macos"))]
fn platform_scheduled_network_allowed() -> bool {
    true
}

#[cfg(target_os = "macos")]
fn schedule_allowed(has_battery: bool, always_on: bool, awake: bool) -> bool {
    !has_battery || always_on || awake
}

#[cfg(target_os = "macos")]
fn has_internal_battery() -> bool {
    std::process::Command::new("/usr/sbin/ioreg")
        .args(["-rd1", "-c", "AppleSmartBattery"])
        .output()
        .is_ok_and(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("AppleSmartBattery")
        })
}

#[cfg(target_os = "macos")]
fn always_on_host_enabled() -> bool {
    let Ok(dir) = tokenstat_identity::identity_dir_path() else {
        return false;
    };
    let Ok(text) = std::fs::read_to_string(dir.join("host.json")) else {
        return false;
    };
    serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|value| value.get("alwaysOn").and_then(serde_json::Value::as_bool))
        .unwrap_or(false)
}

#[cfg(target_os = "macos")]
fn ioreg_user_is_active(output: &[u8]) -> bool {
    String::from_utf8_lossy(output)
        .lines()
        .any(|line| line.trim() == r#""IOPMUserIsActive" = Yes"#)
}

#[cfg(test)]
mod tests {
    #[cfg(target_os = "macos")]
    use super::{ioreg_user_is_active, schedule_allowed};

    #[cfg(target_os = "macos")]
    #[test]
    fn accepts_the_full_wake_signal() {
        assert!(ioreg_user_is_active(
            br#"+-o IOPMrootDomain
    {
      "IOPMUserIsActive" = Yes
    }"#
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn rejects_darkwake_and_missing_signals() {
        assert!(!ioreg_user_is_active(
            br#"    "IOPMUserIsActive" = No
    "IOPMUserTriggeredFullWake" = No"#
        ));
        assert!(!ioreg_user_is_active(b"ioreg failed"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn always_on_and_non_battery_macs_bypass_the_awake_gate() {
        assert!(!schedule_allowed(true, false, false));
        assert!(schedule_allowed(true, false, true));
        assert!(schedule_allowed(true, true, false));
        assert!(schedule_allowed(false, false, false));
    }
}
