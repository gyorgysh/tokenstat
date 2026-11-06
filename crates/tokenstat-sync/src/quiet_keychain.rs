// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Legacy Keychain interaction is process-wide. Keep it disabled in a child,
//! rather than changing the authentication policy of an embedding app.
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const LIMIT: u64 = 256 * 1024;
#[derive(Serialize, Deserialize)]
struct Request {
    service: String,
    account: String,
    replacement: Option<Vec<u8>>,
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Reply {
    pub status: i32,
    pub data: Option<Vec<u8>>,
    #[serde(default)]
    pub has_login: bool,
}
fn unavailable() -> Reply {
    Reply {
        status: -25291,
        data: None,
        has_login: false,
    }
}

/// Called before argument parsing, threads, logging or app startup.
pub fn serve_if_requested() -> Option<u8> {
    let interactive = match std::env::args().nth(1).as_deref() {
        Some("--quiet-keychain") => false,
        Some("--authorize-usage-keychain") => true,
        _ => return None,
    };
    Some(serve(interactive).unwrap_or(1))
}
fn serve(interactive: bool) -> Option<u8> {
    use security_framework::{
        item::{ItemClass, ItemSearchOptions, ItemUpdateOptions, ItemUpdateValue, update_item},
        os::macos::keychain::SecKeychain,
        passwords::get_generic_password,
    };
    if std::env::args().count() != 2 {
        return None;
    }
    let no_dialogs = SecKeychain::disable_user_interaction().ok()?;
    let mut input = Vec::new();
    std::io::stdin()
        .take(LIMIT + 1)
        .read_to_end(&mut input)
        .ok()?;
    if input.len() as u64 > LIMIT {
        return None;
    }
    let request: Request = serde_json::from_slice(&input).ok()?;
    if request.service.is_empty() || request.service.len() > 1024 || request.account.len() > 4096 {
        return None;
    }
    if interactive {
        // No creation or reset. A missing default Keychain fails silently.
        SecKeychain::default().ok()?;
        if request.replacement.is_some()
            || !authorization_target(&request.service, &request.account)
        {
            return None;
        }
        drop(no_dialogs);
    }
    let result = if let Some(bytes) = request.replacement {
        let mut query = ItemSearchOptions::new();
        query
            .class(ItemClass::generic_password())
            .service(&request.service)
            .account(&request.account);
        let mut change = ItemUpdateOptions::new();
        change.set_value(ItemUpdateValue::Data(
            core_foundation::data::CFData::from_buffer(&bytes),
        ));
        update_item(&query, &change).map(|()| None)
    } else {
        get_generic_password(&request.service, &request.account).map(Some)
    };
    let reply = match result {
        Ok(data) => successful_reply(&request.service, data, interactive),
        Err(error) => Reply {
            status: error.code(),
            data: None,
            has_login: false,
        },
    };
    let output = serde_json::to_vec(&reply).ok()?;
    if output.len() as u64 > LIMIT {
        return None;
    }
    std::io::stdout().write_all(&output).ok()?;
    Some(0)
}

pub(crate) fn request(service: &str, account: &str, replacement: Option<&[u8]>) -> Reply {
    request_mode(service, account, replacement, false)
}

fn request_mode(
    service: &str,
    account: &str,
    replacement: Option<&[u8]>,
    interactive: bool,
) -> Reply {
    let Ok(executable) = std::env::current_exe() else {
        return unavailable();
    };
    // Never relaunch an arbitrary GUI app embedding the FFI. Shipping macOS
    // usage reads run in hostd; the CLI supports the same private entry point.
    if !matches!(
        executable.file_name().and_then(|s| s.to_str()),
        Some("tokenstat" | "tokenstat-hostd")
    ) {
        return unavailable();
    }
    let Ok(input) = serde_json::to_vec(&Request {
        service: service.into(),
        account: account.into(),
        replacement: replacement.map(<[u8]>::to_vec),
    }) else {
        return unavailable();
    };
    if input.len() as u64 > LIMIT {
        return unavailable();
    }
    let Ok(mut child) = Command::new(executable)
        .arg(if interactive {
            "--authorize-usage-keychain"
        } else {
            "--quiet-keychain"
        })
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return unavailable();
    };
    std::thread::scope(|scope| {
        let mut stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let writer = scope.spawn(move || stdin.write_all(&input));
        let reader = scope.spawn(move || {
            let mut output = Vec::new();
            stdout
                .take(LIMIT + 1)
                .read_to_end(&mut output)
                .map(|_| output)
        });
        let start = Instant::now();
        let success = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status.success(),
                Ok(None)
                    if start.elapsed() < Duration::from_secs(if interactive { 120 } else { 3 }) =>
                {
                    std::thread::sleep(Duration::from_millis(10))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break false;
                }
            }
        };
        if !success || !matches!(writer.join(), Ok(Ok(()))) {
            return unavailable();
        }
        match reader.join() {
            Ok(Ok(output)) if output.len() as u64 <= LIMIT => {
                serde_json::from_slice(&output).unwrap_or_else(|_| unavailable())
            }
            _ => unavailable(),
        }
    })
}

fn authorization_target(service: &str, account: &str) -> bool {
    (service == "ai.meta.dev.credentials" && account == "meta")
        || ((service == "Claude Code-credentials"
            || service.starts_with("Claude Code-credentials-"))
            && !account.is_empty()
            && std::env::var("USER").ok().as_deref() == Some(account))
}

/// Only called by an explicit local settings action, never by usage polling.
pub fn authorize_usage(source: &str) -> Result<(), String> {
    static AUTHORIZATION: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = AUTHORIZATION
        .try_lock()
        .map_err(|_| "A Keychain authorization is already open.".to_string())?;
    let (services, account) = match source {
        "claude_code" => (
            crate::claude_limits::keychain_services(),
            std::env::var("USER").unwrap_or_default(),
        ),
        "muse" => (vec!["ai.meta.dev.credentials".into()], "meta".into()),
        _ => return Err("This provider does not support Keychain authorization.".into()),
    };
    authorize_items(&services, &account, |service, interactive| {
        request_mode(service, &account, None, interactive)
    })
}

fn successful_reply(service: &str, data: Option<Vec<u8>>, interactive: bool) -> Reply {
    let has_login = data
        .as_deref()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(bytes).ok())
        .is_some_and(|value| {
            let token = if service.starts_with("Claude Code-credentials") {
                value.pointer("/claudeAiOauth/accessToken")
            } else if service == "ai.meta.dev.credentials" {
                value.get("access_token")
            } else {
                None
            };
            token
                .and_then(|v| v.as_str())
                .is_some_and(|s| !s.trim().is_empty())
        });
    Reply {
        status: 0,
        data: if interactive { None } else { data },
        has_login,
    }
}

fn authorize_items(
    services: &[String],
    account: &str,
    mut read: impl FnMut(&str, bool) -> Reply,
) -> Result<(), String> {
    let mut denied = Vec::new();
    for service in services {
        if !authorization_target(service, account) {
            continue;
        }
        let reply = read(service, false);
        match reply.status {
            0 if reply.has_login => return Ok(()),
            0 | -25300 => {}
            _ => denied.push(service),
        }
    }
    // One explicit action may open at most one system prompt. Old Claude
    // profiles can leave many items behind; never walk their permission dialogs.
    if let Some(service) = denied.first() {
        let reply = read(service, true);
        authorization_result(reply.status)?;
        if !reply.has_login {
            return Err("Access was granted, but this saved item contains no provider login. No other Keychain prompts will be opened. Sign in with the provider, then refresh usage.".into());
        }
        // Allow Once only grants this short-lived child access. Verify a new
        // silent reader can use the login before claiming authorization stuck.
        let remembered = read(service, false);
        if remembered.status == 0 && remembered.has_login {
            return Ok(());
        }
        return Err("Background access is still unavailable. If you chose Allow Once, choose Always Allow on the next attempt. You can retry later in Account → Plan limits.".into());
    }
    Err("The saved items contain no usable login. Sign in with the provider, then try again in Account → Plan limits.".into())
}

fn authorization_result(status: i32) -> Result<(), String> {
    match status {
        0 => Ok(()),
        -128 | -25293 => {
            Err("Keychain access was not allowed. Background checks will stay silent.".into())
        }
        -25300 => Err("No saved login was found. Sign in with the provider first.".into()),
        _ => Err(
            "Keychain access is unavailable. Check your login Keychain in Keychain Access.".into(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authorization_only_accepts_provider_items() {
        assert!(authorization_target("ai.meta.dev.credentials", "meta"));
        assert!(!authorization_target("ai.meta.dev.credentials", "other"));
        assert!(!authorization_target("unrelated", "meta"));
        assert!(!authorization_target("Claude Code-credentials", ""));
        assert!(authorize_usage("codex").is_err());
    }
    #[test]
    fn plugin_credentials_never_count_as_authorized_login() {
        let reply = successful_reply(
            "Claude Code-credentials",
            Some(br#"{"mcpOAuth":{"plugin":"fixture"}}"#.to_vec()),
            true,
        );
        assert!(!reply.has_login);
        assert!(reply.data.is_none());
        let reply = successful_reply(
            "Claude Code-credentials",
            Some(br#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.to_vec()),
            true,
        );
        assert!(reply.has_login);
        assert!(
            reply.data.is_none(),
            "interactive authorization must not return credentials"
        );
    }

    #[test]
    fn authorization_requires_a_usable_login_in_a_fresh_silent_child() {
        let services = vec!["ai.meta.dev.credentials".into()];
        let mut calls = Vec::new();
        let result = authorize_items(&services, "meta", |_, interactive| {
            calls.push(interactive);
            if calls.len() == 1 {
                return unavailable();
            }
            successful_reply(
                "ai.meta.dev.credentials",
                Some(br#"{"access_token":"fixture"}"#.to_vec()),
                interactive,
            )
        });
        assert!(result.is_ok());
        assert_eq!(calls, vec![false, true, false]);
        let once = authorize_items(&services, "meta", |_, interactive| {
            if interactive {
                successful_reply(
                    "ai.meta.dev.credentials",
                    Some(br#"{"access_token":"fixture"}"#.to_vec()),
                    true,
                )
            } else {
                unavailable()
            }
        });
        assert!(once.unwrap_err().contains("Always Allow"));
        let plugins = authorize_items(&services, "meta", |_, interactive| {
            successful_reply("ai.meta.dev.credentials", Some(b"{}".to_vec()), interactive)
        });
        assert!(plugins.is_err());
    }

    #[test]
    fn one_action_never_walks_multiple_permission_dialogs() {
        let services = vec!["ai.meta.dev.credentials".to_string(); 10];
        let mut prompts = 0;
        let result = authorize_items(&services, "meta", |_, interactive| {
            if interactive {
                prompts += 1;
                successful_reply("ai.meta.dev.credentials", Some(b"{}".to_vec()), true)
            } else {
                unavailable()
            }
        });
        assert!(result.is_err());
        assert_eq!(
            prompts, 1,
            "a plugin-only item must not trigger a permission sweep"
        );
    }

    #[test]
    fn cancellation_and_missing_items_fail_closed() {
        assert!(authorization_result(0).is_ok());
        for status in [-128, -25293, -25300, -25291, 1] {
            assert!(authorization_result(status).is_err());
        }
    }
}
