//! Resolve the tokenstat.ai API origin (sandbox vs prod vs custom).

use thiserror::Error;

pub const PROD_HOST: &str = "https://tokenstat.ai";
pub const SANDBOX_HOST: &str = "http://localhost:8400";

#[derive(Debug, Error)]
pub enum HostError {
    #[error("host must be an absolute http(s) origin, or sandbox|prod (got {0})")]
    Invalid(String),
}

/// Resolve API base URL.
///
/// Order: `--host` flag → `TOKENSTAT_API_BASE` → config `sync.host` → prod.
pub fn resolve_host(
    flag: Option<&str>,
    env_base: Option<&str>,
    config_host: Option<&str>,
) -> Result<String, HostError> {
    if let Some(raw) = flag {
        return normalize(raw);
    }
    if let Some(raw) = env_base.filter(|s| !s.trim().is_empty()) {
        return normalize(raw);
    }
    if let Some(raw) = config_host.filter(|s| !s.trim().is_empty()) {
        return normalize(raw);
    }
    Ok(PROD_HOST.to_string())
}

pub fn normalize(raw: &str) -> Result<String, HostError> {
    let s = raw.trim().trim_end_matches('/');
    match s {
        "sandbox" => Ok(SANDBOX_HOST.to_string()),
        "prod" => Ok(PROD_HOST.to_string()),
        other if other.starts_with("http://") || other.starts_with("https://") => {
            // Reject path-bearing URLs: origin only.
            let rest = other.split_once("://").map(|(_, r)| r).unwrap_or(other);
            if rest.contains('/') {
                return Err(HostError::Invalid(raw.to_string()));
            }
            Ok(other.to_string())
        }
        _ => Err(HostError::Invalid(raw.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_and_default() {
        assert_eq!(normalize("sandbox").unwrap(), SANDBOX_HOST);
        assert_eq!(normalize("prod").unwrap(), PROD_HOST);
        assert_eq!(resolve_host(None, None, None).unwrap(), PROD_HOST);
        assert_eq!(
            resolve_host(Some("sandbox"), Some("https://tokenstat.ai"), None).unwrap(),
            SANDBOX_HOST
        );
        assert_eq!(
            resolve_host(None, Some("http://localhost:8400"), None).unwrap(),
            SANDBOX_HOST
        );
    }

    #[test]
    fn rejects_path() {
        assert!(normalize("https://tokenstat.ai/api").is_err());
        assert!(normalize("not-a-url").is_err());
    }
}
