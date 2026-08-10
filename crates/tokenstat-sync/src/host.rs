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
            let (scheme, hostport) = other
                .split_once("://")
                .ok_or_else(|| HostError::Invalid(raw.to_string()))?;
            // Strip optional userinfo and take host only for the loopback check.
            let hostport = hostport.rsplit('@').next().unwrap_or(hostport);
            let host = hostport
                .split('%')
                .next()
                .unwrap_or(hostport)
                .trim_start_matches('[')
                .split(']')
                .next()
                .unwrap_or(hostport)
                .split(':')
                .next()
                .unwrap_or(hostport);
            if scheme.eq_ignore_ascii_case("http") && !is_loopback_host(host) {
                return Err(HostError::Invalid(format!(
                    "{raw}: http is only allowed for localhost; use https for remote hosts"
                )));
            }
            Ok(other.to_string())
        }
        _ => Err(HostError::Invalid(raw.to_string())),
    }
}

/// True for names and addresses that only reach this machine.
pub fn is_loopback_host(host: &str) -> bool {
    let h = host
        .trim()
        .trim_matches(|c| c == '[' || c == ']')
        .to_ascii_lowercase();
    if h == "localhost" || h == "::1" || h == "0.0.0.0" {
        return true;
    }
    // IPv4 loopback 127.0.0.0/8 only when every label is numeric.
    let parts: Vec<&str> = h.split('.').collect();
    if parts.len() == 4
        && parts.iter().all(|p| p.chars().all(|c| c.is_ascii_digit()))
        && parts[0] == "127"
    {
        return true;
    }
    false
}

/// Whether a verification URL from a device-login response may be opened.
///
/// Scheme must be https, or http only on loopback. Host must match the API
/// origin host so a hostile server cannot open an arbitrary page.
pub fn assert_safe_verification_url(url: &str, api_origin: &str) -> Result<(), HostError> {
    let url = url.trim();
    let origin = normalize(api_origin)?;
    let (o_scheme, o_rest) = origin
        .split_once("://")
        .ok_or_else(|| HostError::Invalid(origin.clone()))?;
    let o_host = o_rest
        .split('/')
        .next()
        .unwrap_or(o_rest)
        .rsplit('@')
        .next()
        .unwrap_or(o_rest);
    let o_host = o_host
        .trim_start_matches('[')
        .split(']')
        .next()
        .unwrap_or(o_host)
        .split(':')
        .next()
        .unwrap_or(o_host)
        .to_ascii_lowercase();

    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| HostError::Invalid(format!("verification URL is not absolute: {url}")))?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "https" && scheme != "http" {
        return Err(HostError::Invalid(format!(
            "verification URL scheme must be https (got {scheme})"
        )));
    }
    let hostport = rest.split('/').next().unwrap_or(rest);
    let hostport = hostport.rsplit('@').next().unwrap_or(hostport);
    let host = hostport
        .trim_start_matches('[')
        .split(']')
        .next()
        .unwrap_or(hostport)
        .split(':')
        .next()
        .unwrap_or(hostport)
        .to_ascii_lowercase();
    if host.is_empty() {
        return Err(HostError::Invalid("verification URL has no host".into()));
    }
    if scheme == "http" && !is_loopback_host(&host) {
        return Err(HostError::Invalid(
            "verification URL may use http only on localhost".into(),
        ));
    }
    if host != o_host {
        return Err(HostError::Invalid(format!(
            "verification URL host {host} does not match API host {o_host}"
        )));
    }
    let _ = o_scheme;
    Ok(())
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

    #[test]
    fn rejects_cleartext_remote() {
        assert!(normalize("http://evil.example").is_err());
        assert!(normalize("http://tokenstat.ai").is_err());
        assert_eq!(
            normalize("http://localhost:8400").unwrap(),
            "http://localhost:8400"
        );
        assert_eq!(
            normalize("http://127.0.0.1:9").unwrap(),
            "http://127.0.0.1:9"
        );
    }

    #[test]
    fn loopback_host_check() {
        assert!(is_loopback_host("localhost"));
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("127.1.2.3"));
        assert!(!is_loopback_host("127.evil.com"));
        assert!(!is_loopback_host("example.com"));
    }

    #[test]
    fn verification_url_allowlist() {
        assert!(
            assert_safe_verification_url("https://tokenstat.ai/device", "https://tokenstat.ai")
                .is_ok()
        );
        assert!(
            assert_safe_verification_url("https://evil.example/phish", "https://tokenstat.ai")
                .is_err()
        );
        assert!(
            assert_safe_verification_url("http://localhost:8400/device", "http://localhost:8400")
                .is_ok()
        );
        assert!(
            assert_safe_verification_url("file:///etc/passwd", "https://tokenstat.ai").is_err()
        );
    }
}
