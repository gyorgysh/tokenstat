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
    let raw = match raw.trim() {
        "sandbox" => SANDBOX_HOST,
        "prod" => PROD_HOST,
        other => other,
    };
    let url = reqwest::Url::parse(raw).map_err(|_| HostError::Invalid(raw.to_string()))?;
    let host = url
        .host_str()
        .ok_or_else(|| HostError::Invalid(raw.to_string()))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || (url.scheme() == "http" && !is_loopback_host(host))
    {
        return Err(HostError::Invalid(raw.to_string()));
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
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
    h.parse::<std::net::IpAddr>()
        .is_ok_and(|ip| ip.is_loopback())
}

/// Whether a verification URL from a device-login response may be opened.
///
/// Scheme must be https, or http only on loopback. Host must match the API
/// origin host so a hostile server cannot open an arbitrary page.
pub fn assert_safe_verification_url(url: &str, api_origin: &str) -> Result<(), HostError> {
    let origin = reqwest::Url::parse(&normalize(api_origin)?)
        .map_err(|_| HostError::Invalid(api_origin.to_string()))?;
    let parsed =
        reqwest::Url::parse(url.trim()).map_err(|_| HostError::Invalid(url.to_string()))?;
    let host = parsed
        .host_str()
        .ok_or_else(|| HostError::Invalid(url.to_string()))?;
    if !matches!(parsed.scheme(), "http" | "https")
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || (parsed.scheme() == "http" && !is_loopback_host(host))
        || parsed.host_str() != origin.host_str()
    {
        return Err(HostError::Invalid(url.to_string()));
    }
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
    #[test]
    fn origin_uses_url_parsing_and_supports_ipv6_loopback() {
        assert_eq!(
            normalize("http://[::1]:8400/").unwrap(),
            "http://[::1]:8400"
        );
        for bad in [
            "https://",
            "https://tokenstat.ai?other",
            "https://tokenstat.ai#other",
            "https://user@tokenstat.ai",
            "http://[::2]:8400",
            "http://127.999.0.1",
        ] {
            assert!(normalize(bad).is_err(), "{bad}");
        }
        assert!(
            assert_safe_verification_url("http://[::1]:8400/device", "http://[::1]:8400").is_ok()
        );
        assert!(
            assert_safe_verification_url(
                "https://user@tokenstat.ai/device",
                "https://tokenstat.ai"
            )
            .is_err()
        );
        assert!(!is_loopback_host("127.999.0.1"));
    }
}
