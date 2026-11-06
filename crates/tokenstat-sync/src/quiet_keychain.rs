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
    if std::env::args().nth(1).as_deref() != Some("--quiet-keychain") {
        return None;
    }
    Some(serve().unwrap_or(1))
}
fn serve() -> Option<u8> {
    use security_framework::{
        item::{ItemClass, ItemSearchOptions, ItemUpdateOptions, ItemUpdateValue, update_item},
        os::macos::keychain::SecKeychain,
        passwords::get_generic_password,
    };
    if std::env::args().count() != 2 {
        return None;
    }
    let _no_dialogs = SecKeychain::disable_user_interaction().ok()?;
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
        Ok(data) => Reply { status: 0, data },
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
        .arg("--quiet-keychain")
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
                Ok(None) if start.elapsed() < Duration::from_secs(3) => {
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
