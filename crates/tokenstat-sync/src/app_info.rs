// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! The local front end identifies itself without changing the core version.
//! Kept in memory and sent only with existing account requests.
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppInfo {
    pub version: String,
    pub build: Option<String>,
}

static APP: OnceLock<RwLock<Option<AppInfo>>> = OnceLock::new();

fn valid(value: &str, limit: usize) -> bool {
    !value.is_empty()
        && value.len() <= limit
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-+_".contains(&c))
}

impl AppInfo {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !valid(&self.version, 64) || self.build.as_deref().is_some_and(|b| !valid(b, 32)) {
            return Err("invalid app version or build");
        }
        Ok(())
    }
}

pub fn identify(info: AppInfo) -> Result<(), &'static str> {
    info.validate()?;
    *APP.get_or_init(|| RwLock::new(None))
        .write()
        .unwrap_or_else(|e| e.into_inner()) = Some(info);
    Ok(())
}

pub fn current() -> Option<AppInfo> {
    APP.get_or_init(|| RwLock::new(None))
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_is_bounded_and_cannot_inject_headers() {
        for (version, build) in [("1.13.0-dev+abc", Some("224")), ("1.13.0", None)] {
            assert!(
                AppInfo {
                    version: version.into(),
                    build: build.map(str::to_owned)
                }
                .validate()
                .is_ok()
            );
        }
        for value in ["", "1.13.0\r\nX-Test: bad", "<script>", &"a".repeat(65)] {
            assert!(
                AppInfo {
                    version: value.into(),
                    build: None
                }
                .validate()
                .is_err()
            );
        }
        assert!(
            AppInfo {
                version: "1.13.0".into(),
                build: Some("a".repeat(33))
            }
            .validate()
            .is_err()
        );
        assert!(
            serde_json::from_str::<AppInfo>(r#"{"version":"1","build":"2","peer":"other"}"#)
                .is_err()
        );
    }
}
