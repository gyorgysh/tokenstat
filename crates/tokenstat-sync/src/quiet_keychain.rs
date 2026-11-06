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
}
fn unavailable() -> Reply {
    Reply {
        status: -25291,
        data: None,
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
        Ok(data) => Reply {
            status: 0,
            data: if interactive { None } else { data },
        },
        Err(error) => Reply {
            status: error.code(),
            data: None,
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
    let mut readable = false;
    for service in services {
        if !authorization_target(&service, &account) {
            continue;
        }
        // Missing items need no dialog. An existing accessible item needs no grant.
        match request(&service, &account, None).status {
            -25300 => continue,
            0 => {
                readable = true;
                continue;
            }
            _ => {}
        }
        return authorization_result(request_mode(&service, &account, None, true).status);
    }
    if readable {
        Ok(())
    } else {
        Err("No saved login was found. Sign in with the provider first.".into())
    }
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
    fn cancellation_and_missing_items_fail_closed() {
        assert!(authorization_result(0).is_ok());
        for status in [-128, -25293, -25300, -25291, 1] {
            assert!(authorization_result(status).is_err());
        }
    }
}
