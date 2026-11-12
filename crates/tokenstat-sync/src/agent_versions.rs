// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! The newest published version of an agent CLI.
//!
//! Each vendor already publishes this for its own installer, and these are
//! the same addresses those installers read: a plain version file, a release
//! record, the npm registry, or the version baked into the install script.
//! It runs only when somebody presses Check for updates, and each request
//! names the agent and nothing about the person or their machine beyond its
//! platform.

use std::time::Duration;

/// Where an agent's latest version is published.
#[derive(Clone, Debug, PartialEq)]
pub enum LatestSource {
    /// A package on the npm registry.
    Npm(&'static str),
    /// A URL whose whole body is the version.
    Text(&'static str),
    /// A JSON document, and the pointer to the version inside it.
    Json(String, &'static str),
    /// A GitHub repository's latest release tag.
    GitHubRelease(&'static str),
    /// An install script that names the version in its download URL, after
    /// this marker.
    ScriptMarker(&'static str, &'static str),
}

/// npm's own rule for a package name, scoped or not: lowercase letters,
/// digits and `-._~`, with at most one `@scope/` in front. Anything else is
/// refused before a URL is built from it.
fn valid_package(name: &str) -> bool {
    let bare = |part: &str| {
        !part.is_empty()
            && part.len() <= 214
            && part
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "-._~".contains(c))
    };
    match name.strip_prefix('@') {
        Some(scoped) => scoped
            .split_once('/')
            .is_some_and(|(scope, package)| bare(scope) && bare(package)),
        None => bare(name),
    }
}

fn client() -> Result<reqwest::blocking::Client, String> {
    crate::http::client_builder()
        .timeout(Duration::from_secs(10))
        .user_agent("tokenstat")
        .build()
        .map_err(|error| error.to_string())
}

fn get(client: &reqwest::blocking::Client, url: &str) -> Result<String, String> {
    client
        .get(url)
        .send()
        .and_then(|response| response.error_for_status())
        .and_then(|response| response.text())
        .map_err(|error| error.to_string())
}

fn json_version(body: &str, pointer: &str) -> Result<String, String> {
    let value: serde_json::Value = serde_json::from_str(body).map_err(|error| error.to_string())?;
    value
        .pointer(pointer)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "the answer had no version".into())
}

/// The first `a.b[.c...][-suffix]` in a script after `marker`.
fn version_after(script: &str, marker: &str) -> Option<String> {
    let start = script.find(marker)? + marker.len();
    let version: String = script[start..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
        .collect();
    version
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_digit())
        .then_some(version)
}

/// Strip what vendors put around a version: whitespace, a leading `v`, and
/// a tag prefix such as `rust-v`.
pub fn clean(version: &str) -> String {
    let trimmed = version.trim();
    let start = trimmed
        .find(|c: char| c.is_ascii_digit())
        .unwrap_or(trimmed.len());
    trimmed[start..].to_owned()
}

/// The latest published version from one source.
pub fn latest(source: &LatestSource) -> Result<String, String> {
    let client = client()?;
    let raw = match source {
        LatestSource::Npm(package) => {
            if !valid_package(package) {
                return Err(format!("not an npm package name: {package}"));
            }
            json_version(
                &get(
                    &client,
                    &format!("https://registry.npmjs.org/{package}/latest"),
                )?,
                "/version",
            )?
        }
        LatestSource::Text(url) => get(&client, url)?,
        LatestSource::Json(url, pointer) => json_version(&get(&client, url)?, pointer)?,
        LatestSource::GitHubRelease(repository) => json_version(
            &get(
                &client,
                &format!("https://api.github.com/repos/{repository}/releases/latest"),
            )?,
            "/tag_name",
        )?,
        LatestSource::ScriptMarker(url, marker) => version_after(&get(&client, url)?, marker)
            .ok_or("the install script names no version")?,
    };
    let version = clean(&raw);
    if version.is_empty() || version.len() > 64 {
        return Err("the answer had no version".into());
    }
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_names_are_checked_before_a_request() {
        assert!(valid_package("cline"));
        assert!(valid_package("@kilocode/cli"));
        assert!(valid_package("@earendil-works/pi-coding-agent"));
        for bad in ["", "@scope", "@a/b/c", "../x", "Cline", "a b", "@x/", "x?y"] {
            assert!(!valid_package(bad), "{bad}");
        }
    }

    #[test]
    fn vendor_answers_become_plain_versions() {
        assert_eq!(clean("2.1.322\n"), "2.1.322");
        assert_eq!(clean("rust-v0.167.2"), "0.167.2");
        assert_eq!(clean("v0.23.1"), "0.23.1");
        assert_eq!(
            json_version(r#"{"tag_name":"rust-v0.167.2"}"#, "/tag_name").unwrap(),
            "rust-v0.167.2"
        );
        let script =
            r#"DOWNLOAD_URL="https://downloads.cursor.com/lab/2026.11.11-b912975/${OS}/x""#;
        assert_eq!(
            version_after(script, "downloads.cursor.com/lab/").as_deref(),
            Some("2026.11.11-b912975")
        );
        assert_eq!(version_after("lab/${V}", "lab/"), None);
    }
}
