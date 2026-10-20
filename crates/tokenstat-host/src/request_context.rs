// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Identity attached to the request currently entering dispatch.
//!
//! Unix-socket and in-process calls have no remote peer. The encrypted remote
//! transport installs its authenticated static key for exactly the duration of
//! one dispatch call, so authorization code never trusts a peer id from JSON.

use std::cell::RefCell;
use std::sync::Arc;

thread_local! {
    static RELAY: RefCell<bool> = const { RefCell::new(false) };
    static REMOTE_PEER: RefCell<Option<String>> = const { RefCell::new(None) };
    static TEAM_PRINCIPAL: RefCell<Option<Arc<crate::teams::AuthorizedTeamPrincipal>>> = const { RefCell::new(None) };
}

/// Transport-derived authority. A Team member remains scoped even if the
/// same physical device also has an ordinary personal pairing.
pub(crate) enum RequestPrincipal {
    LocalOwner,
    PersonalDevice { key: String },
    TeamMember(Arc<crate::teams::AuthorizedTeamPrincipal>),
}
pub(crate) fn principal() -> RequestPrincipal {
    if let Some(member) = team_principal() {
        return RequestPrincipal::TeamMember(member);
    }
    match REMOTE_PEER.with(|peer| peer.borrow().clone()) {
        Some(key) => RequestPrincipal::PersonalDevice { key },
        None => RequestPrincipal::LocalOwner,
    }
}

pub(crate) fn team_principal() -> Option<Arc<crate::teams::AuthorizedTeamPrincipal>> {
    TEAM_PRINCIPAL.with(|slot| slot.borrow().clone())
}
pub(crate) fn with_team_principal<T>(
    principal: crate::teams::AuthorizedTeamPrincipal,
    work: impl FnOnce() -> T,
) -> T {
    struct Restore(Option<Arc<crate::teams::AuthorizedTeamPrincipal>>);
    impl Drop for Restore {
        fn drop(&mut self) {
            TEAM_PRINCIPAL.with(|slot| *slot.borrow_mut() = self.0.take());
        }
    }
    let peer = principal.value().device_key.clone();
    let previous = TEAM_PRINCIPAL.with(|slot| slot.replace(Some(Arc::new(principal))));
    let _restore = Restore(previous);
    with_remote_peer(&peer, work)
}

pub(crate) fn remote_peer() -> Option<String> {
    match principal() {
        RequestPrincipal::LocalOwner => None,
        RequestPrincipal::PersonalDevice { key } => Some(key),
        RequestPrincipal::TeamMember(member) => Some(member.value().device_key.clone()),
    }
}

/// Methods that decrypt vault material, open SSH sessions, or change this
/// machine's serving policy belong to the local owner. An approved peer is
/// not that owner.
pub(crate) fn refuse_remote(what: &str) -> Result<(), String> {
    match principal() {
        RequestPrincipal::LocalOwner => Ok(()),
        _ => Err(format!("{what} are local-only")),
    }
}

pub(crate) fn with_remote_peer<T>(peer: &str, work: impl FnOnce() -> T) -> T {
    struct Restore(Option<String>);
    impl Drop for Restore {
        fn drop(&mut self) {
            REMOTE_PEER.with(|peer| *peer.borrow_mut() = self.0.take());
        }
    }

    let previous = REMOTE_PEER.with(|slot| slot.borrow_mut().replace(peer.to_string()));
    let _restore = Restore(previous);
    work()
}

#[cfg(feature = "local-host")]
pub(crate) fn is_relay() -> bool {
    RELAY.with(|slot| *slot.borrow())
}
pub(crate) fn with_relay<T>(relay: bool, work: impl FnOnce() -> T) -> T {
    struct Restore(bool);
    impl Drop for Restore {
        fn drop(&mut self) {
            RELAY.with(|slot| *slot.borrow_mut() = self.0);
        }
    }
    let _restore = Restore(RELAY.with(|slot| slot.replace(relay)));
    work()
}

#[cfg(all(target_os = "macos", feature = "local-host"))]
thread_local! {
    static DESKTOP_APP: RefCell<Option<String>> = const { RefCell::new(None) };
}

#[cfg(all(target_os = "macos", feature = "local-host"))]
pub(crate) fn desktop_app() -> Option<String> {
    DESKTOP_APP.with(|app| app.borrow().clone())
}

/// Request-scoped, local-only application identity. Never serialized into a
/// conversation or accepted from an authenticated remote peer.
#[cfg(all(target_os = "macos", feature = "local-host"))]
pub(crate) struct DesktopAppScope(Option<String>);

#[cfg(all(target_os = "macos", feature = "local-host"))]
impl Drop for DesktopAppScope {
    fn drop(&mut self) {
        DESKTOP_APP.with(|app| *app.borrow_mut() = self.0.take());
    }
}

#[cfg(all(target_os = "macos", feature = "local-host"))]
pub(crate) fn enter_desktop_app(app: Option<&str>) -> Result<DesktopAppScope, String> {
    let app = app.map(validate_desktop_app).transpose()?;
    Ok(DesktopAppScope(DESKTOP_APP.with(|slot| slot.replace(app))))
}

#[cfg(all(target_os = "macos", feature = "local-host"))]
fn validate_desktop_app(value: &str) -> Result<String, String> {
    refuse_remote("desktop application targeting")?;
    let invalid = || "The desktop application bundle is not usable".to_string();
    let path = std::path::Path::new(value);
    if value.len() > 4096
        || value.chars().any(char::is_control)
        || !path.is_absolute()
        || !path.extension().is_some_and(|ext| {
            ext.to_str()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("app"))
        })
    {
        return Err(invalid());
    }
    let path = path.canonicalize().map_err(|_| invalid())?;
    if !path.join("Contents/MacOS/Tokenstat").is_file() {
        return Err(invalid());
    }
    // Read both XML and binary bundle plists with the system reader. This is
    // an argv-only call to a fixed system executable, never a shell command.
    let identity = std::process::Command::new("/usr/libexec/PlistBuddy")
        .args(["-c", "Print:CFBundleIdentifier"])
        .arg(path.join("Contents/Info.plist"))
        .output()
        .map_err(|_| invalid())?;
    if !identity.status.success()
        || String::from_utf8_lossy(&identity.stdout).trim() != "ai.tokenstat.tokenstat"
    {
        return Err(invalid());
    }
    path.to_str().map(str::to_owned).ok_or_else(invalid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_is_scoped_and_restored_when_nested() {
        assert_eq!(remote_peer(), None);
        with_remote_peer("a", || {
            assert_eq!(remote_peer().as_deref(), Some("a"));
            with_remote_peer("b", || assert_eq!(remote_peer().as_deref(), Some("b")));
            assert_eq!(remote_peer().as_deref(), Some("a"));
        });
        assert_eq!(remote_peer(), None);
    }
    #[cfg(all(target_os = "macos", feature = "local-host"))]
    #[test]
    fn desktop_origin_is_local_validated_scoped_and_shell_safe() {
        use std::fs;
        let root = tempfile::tempdir().unwrap();
        let app = root.path().join("QA space ü $(touch marker).app");
        fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        fs::write(app.join("Contents/MacOS/Tokenstat"), b"fixture").unwrap();
        let plist = app.join("Contents/Info.plist");
        fs::write(&plist, br#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tokenstat.tokenstat</string></dict></plist>"#).unwrap();
        assert!(desktop_app().is_none());
        {
            let _origin = enter_desktop_app(Some(app.to_str().unwrap())).unwrap();
            assert_eq!(
                desktop_app(),
                Some(app.canonicalize().unwrap().display().to_string())
            );
            {
                let _nested = enter_desktop_app(None).unwrap();
                assert!(desktop_app().is_none());
            }
            assert!(desktop_app().is_some());
            assert!(enter_desktop_app(Some("relative.app")).is_err());
            assert!(
                desktop_app().is_some(),
                "Rejected input replaced the outer scope"
            );
        }
        assert!(desktop_app().is_none());
        assert!(!root.path().join("marker").exists());
        with_remote_peer("fixture-peer", || {
            assert!(enter_desktop_app(Some(app.to_str().unwrap())).is_err());
        });
        fs::write(&plist, br#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.other</string></dict></plist>"#).unwrap();
        assert!(enter_desktop_app(Some(app.to_str().unwrap())).is_err());
        assert!(enter_desktop_app(Some("/missing-test-desktop.app")).is_err());
    }
}
