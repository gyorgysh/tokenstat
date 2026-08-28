//! GitHub App authorization and local credential discovery.

use std::fmt;
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::GITHUB_CLIENT_ID;
use crate::keychain;

pub const APP_SLUG: &str = "tokenstat";
const GITHUB_HOST: &str = "github.com";
const DEVICE_CODE_URL: &str = "https://github.com/login/device/code";
const TOKEN_URL: &str = "https://github.com/login/oauth/access_token";

#[derive(Debug, thiserror::Error)]
pub enum ForgeError {
    #[error("pull requests are not connected")]
    NotSignedIn,
    #[error("GitHub Enterprise device authorization needs an app registered on {0}")]
    EnterpriseAppRequired(String),
    #[error("GitHub authorization was declined")]
    AccessDenied,
    #[error("the GitHub authorization code expired; start again")]
    DeviceExpired,
    #[error("the GitHub authorization expired and could not be refreshed")]
    RefreshFailed,
    #[error("GitHub rejected the request: {0}")]
    Api(String),
    #[error("GitHub's request limit is exhausted{reset}", reset = reset_suffix(*.reset))]
    RateLimited { reset: Option<u64> },
    #[error("network: {0}")]
    Network(#[from] reqwest::Error),
    #[error("credential storage: {0}")]
    Storage(#[from] keychain::KeychainError),
    #[error("credential data is invalid: {0}")]
    CredentialData(#[from] serde_json::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CredentialSource {
    Tokenstat,
    GitCredential,
    Environment,
    Pasted,
}

/// A usable bearer and where it came from.
///
/// Debug output is intentionally redacted. This type may cross internal layers,
/// but the token itself must never cross the host bridge.
#[derive(Clone)]
pub struct Credential {
    source: CredentialSource,
    token: String,
}

impl Credential {
    pub fn source(&self) -> CredentialSource {
        self.source
    }

    pub(crate) fn bearer(&self) -> &str {
        &self.token
    }
}

impl fmt::Debug for Credential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credential")
            .field("source", &self.source)
            .field("token", &"[redacted]")
            .finish()
    }
}

#[derive(Clone, Serialize, Deserialize)]
struct StoredGrant {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_at: Option<u64>,
    #[serde(default)]
    refresh_token_expires_at: Option<u64>,
    source: CredentialSource,
}

/// A device authorization in progress. Its secret half never leaves Rust.
#[derive(Clone)]
pub struct DeviceLogin {
    pub host: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    pub interval: u64,
    device_code: String,
}

impl fmt::Debug for DeviceLogin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeviceLogin")
            .field("host", &self.host)
            .field("user_code", &self.user_code)
            .field("verification_uri", &self.verification_uri)
            .field("expires_in", &self.expires_in)
            .field("interval", &self.interval)
            .field("device_code", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Clone)]
pub enum DeviceStatus {
    Pending { interval: u64 },
    Confirmed(Credential),
}

#[derive(Deserialize)]
struct DeviceCodeResponse {
    device_code: String,
    user_code: String,
    verification_uri: String,
    expires_in: u64,
    interval: u64,
}

#[derive(Deserialize)]
struct TokenResponse {
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    refresh_token_expires_in: Option<u64>,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    error_description: Option<String>,
}

pub(super) fn http_client() -> Result<reqwest::blocking::Client, ForgeError> {
    Ok(reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(10))
        .user_agent(format!("tokenstat/{}", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::none())
        .build()?)
}

fn normalized_host(host: &str) -> Option<String> {
    let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
    (!host.is_empty()
        && !host.contains(['/', '\\', '\n', '\r', ':'])
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.')))
    .then_some(host)
}

fn storage_key(host: &str) -> String {
    format!("forge:https://{host}")
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn load_grant(host: &str) -> Result<Option<StoredGrant>, ForgeError> {
    let Some(raw) = keychain::load_token(&storage_key(host))? else {
        return Ok(None);
    };
    Ok(Some(serde_json::from_str(&raw)?))
}

fn store_grant(host: &str, grant: &StoredGrant) -> Result<(), ForgeError> {
    let raw = serde_json::to_string(grant)?;
    keychain::store_token(&storage_key(host), &raw)?;
    Ok(())
}

/// Find a credential without opening a browser or changing another tool's
/// credential store. The first usable rung wins.
pub fn credential(host: &str) -> Option<Credential> {
    let host = normalized_host(host)?;
    if let Ok(Some(grant)) = load_grant(&host) {
        let expired = grant
            .expires_at
            .is_some_and(|expires_at| expires_at <= now_secs().saturating_add(30));
        if expired {
            if let Ok(refreshed) = refresh(&host, &grant) {
                return Some(Credential {
                    source: refreshed.source,
                    token: refreshed.access_token,
                });
            }
        } else {
            return Some(Credential {
                source: grant.source,
                token: grant.access_token,
            });
        }
    }
    if let Some(token) = git_credential(&host).filter(|token| borrowed_token_works(&host, token)) {
        return Some(Credential {
            source: CredentialSource::GitCredential,
            token,
        });
    }
    ["GH_TOKEN", "GITHUB_TOKEN"]
        .into_iter()
        .filter_map(|name| std::env::var(name).ok())
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
        .find(|token| borrowed_token_works(&host, token))
        .map(|token| Credential {
            source: CredentialSource::Environment,
            token,
        })
}

/// A helper or environment token belongs to another tool. Probe it without
/// storing it so a stale or under-scoped credential falls through to the next
/// rung instead of turning the connection screen into a 401/403 dead end.
fn borrowed_token_works(host: &str, token: &str) -> bool {
    let base = if host == GITHUB_HOST {
        "https://api.github.com".to_string()
    } else {
        format!("https://{host}/api/v3")
    };
    http_client()
        .and_then(|client| {
            client
                .get(format!("{base}/user"))
                .header("accept", "application/vnd.github+json")
                .header("x-github-api-version", "2022-11-28")
                .bearer_auth(token)
                .send()
                .map_err(ForgeError::from)
        })
        .is_ok_and(|response| response.status().is_success())
}

fn git_credential(host: &str) -> Option<String> {
    let mut child = Command::new("git")
        .args(["-c", "credential.interactive=false", "credential", "fill"])
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    child
        .stdin
        .take()?
        .write_all(format!("protocol=https\nhost={host}\n\n").as_bytes())
        .ok()?;
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8(out.stdout).ok()?;
    stdout
        .lines()
        .find_map(|line| line.strip_prefix("password="))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

pub fn device_start(host: &str) -> Result<DeviceLogin, ForgeError> {
    let host = normalized_host(host).ok_or_else(|| ForgeError::Api("invalid host".into()))?;
    if host != GITHUB_HOST {
        return Err(ForgeError::EnterpriseAppRequired(host));
    }
    let resp = http_client()?
        .post(DEVICE_CODE_URL)
        .header("accept", "application/json")
        .form(&[("client_id", GITHUB_CLIENT_ID)])
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if !status.is_success() {
        return Err(ForgeError::Api(api_message(&text, status.as_u16())));
    }
    let body: DeviceCodeResponse = serde_json::from_str(&text)?;
    crate::host::assert_safe_verification_url(&body.verification_uri, "https://github.com")
        .map_err(|error| ForgeError::Api(error.to_string()))?;
    Ok(DeviceLogin {
        host,
        user_code: body.user_code,
        verification_uri: body.verification_uri,
        expires_in: body.expires_in.max(1),
        interval: body.interval.max(1),
        device_code: body.device_code,
    })
}

/// Poll GitHub exactly once. The UI owns the wait and cancellation.
pub fn device_poll(login: &DeviceLogin) -> Result<DeviceStatus, ForgeError> {
    let resp = http_client()?
        .post(TOKEN_URL)
        .header("accept", "application/json")
        .form(&[
            ("client_id", GITHUB_CLIENT_ID),
            ("device_code", login.device_code.as_str()),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if !status.is_success() {
        return Err(ForgeError::Api(api_message(&text, status.as_u16())));
    }
    let body: TokenResponse = serde_json::from_str(&text)?;
    match body.error.as_deref() {
        Some("authorization_pending") => Ok(DeviceStatus::Pending {
            interval: login.interval,
        }),
        Some("slow_down") => Ok(DeviceStatus::Pending {
            interval: login.interval.saturating_add(5),
        }),
        Some("expired_token") => Err(ForgeError::DeviceExpired),
        Some("access_denied") => Err(ForgeError::AccessDenied),
        Some(error) => Err(ForgeError::Api(
            body.error_description.unwrap_or_else(|| error.to_string()),
        )),
        None => {
            let grant = grant_from_token(body, CredentialSource::Tokenstat)?;
            store_grant(&login.host, &grant)?;
            Ok(DeviceStatus::Confirmed(Credential {
                source: grant.source,
                token: grant.access_token,
            }))
        }
    }
}

/// Store a token the person explicitly pasted. It has no refresh token and is
/// retained until GitHub rejects it or the person signs out.
pub fn set_token(host: &str, token: &str) -> Result<(), ForgeError> {
    let host = normalized_host(host).ok_or_else(|| ForgeError::Api("invalid host".into()))?;
    let token = token.trim();
    if token.is_empty() {
        return Err(ForgeError::NotSignedIn);
    }
    store_grant(
        &host,
        &StoredGrant {
            access_token: token.into(),
            refresh_token: None,
            expires_at: None,
            refresh_token_expires_at: None,
            source: CredentialSource::Pasted,
        },
    )
}

pub fn sign_out(host: &str) -> Result<(), ForgeError> {
    let host = normalized_host(host).ok_or_else(|| ForgeError::Api("invalid host".into()))?;
    keychain::delete_token(&storage_key(&host))?;
    Ok(())
}

fn refresh(host: &str, old: &StoredGrant) -> Result<StoredGrant, ForgeError> {
    let refresh_token = old
        .refresh_token
        .as_deref()
        .ok_or(ForgeError::RefreshFailed)?;
    if old
        .refresh_token_expires_at
        .is_some_and(|expires| expires <= now_secs().saturating_add(30))
    {
        return Err(ForgeError::RefreshFailed);
    }
    if host != GITHUB_HOST {
        return Err(ForgeError::EnterpriseAppRequired(host.into()));
    }
    let resp = http_client()?
        .post(TOKEN_URL)
        .header("accept", "application/json")
        .form(&[
            ("client_id", GITHUB_CLIENT_ID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
        ])
        .send()?;
    let status = resp.status();
    let text = resp.text()?;
    if !status.is_success() {
        return Err(ForgeError::RefreshFailed);
    }
    let body: TokenResponse = serde_json::from_str(&text)?;
    if body.error.is_some() {
        return Err(ForgeError::RefreshFailed);
    }
    let grant = grant_from_token(body, old.source).map_err(|_| ForgeError::RefreshFailed)?;
    store_grant(host, &grant)?;
    Ok(grant)
}

pub(super) fn refresh_stored(host: &str) -> Result<Credential, ForgeError> {
    let host = normalized_host(host).ok_or_else(|| ForgeError::Api("invalid host".into()))?;
    let old = load_grant(&host)?.ok_or(ForgeError::NotSignedIn)?;
    let refreshed = refresh(&host, &old)?;
    Ok(Credential {
        source: refreshed.source,
        token: refreshed.access_token,
    })
}

fn grant_from_token(
    body: TokenResponse,
    source: CredentialSource,
) -> Result<StoredGrant, ForgeError> {
    let now = now_secs();
    let access_token = body
        .access_token
        .filter(|token| !token.trim().is_empty())
        .ok_or_else(|| ForgeError::Api("GitHub returned no access token".into()))?;
    Ok(StoredGrant {
        access_token,
        refresh_token: body.refresh_token,
        expires_at: body.expires_in.map(|seconds| now.saturating_add(seconds)),
        refresh_token_expires_at: body
            .refresh_token_expires_in
            .map(|seconds| now.saturating_add(seconds)),
        source,
    })
}

fn api_message(text: &str, status: u16) -> String {
    #[derive(Deserialize)]
    struct ErrorBody {
        message: Option<String>,
        error_description: Option<String>,
        error: Option<String>,
    }
    let parsed: Option<ErrorBody> = serde_json::from_str(text).ok();
    let detail = parsed
        .and_then(|body| body.message.or(body.error_description).or(body.error))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| text.trim().to_string());
    if detail.is_empty() {
        format!("HTTP {status}")
    } else {
        format!("HTTP {status}: {detail}")
    }
}

fn reset_suffix(reset: Option<u64>) -> String {
    reset
        .and_then(|at| i64::try_from(at).ok())
        .and_then(|at| jiff::Timestamp::from_second(at).ok())
        .map_or_else(String::new, |at| format!(" until {at}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_validation_rejects_urls_and_protocol_injection() {
        assert_eq!(normalized_host("GitHub.COM."), Some("github.com".into()));
        assert_eq!(normalized_host("https://github.com"), None);
        assert_eq!(normalized_host("github.com\nprotocol=http"), None);
        assert_eq!(normalized_host("github.com:443"), None);
    }

    #[test]
    fn debug_never_prints_bearers_or_device_secrets() {
        let credential = Credential {
            source: CredentialSource::Tokenstat,
            token: "ghu_super-secret".into(),
        };
        let rendered = format!("{credential:?}");
        assert!(!rendered.contains("ghu_super-secret"));

        let login = DeviceLogin {
            host: GITHUB_HOST.into(),
            user_code: "ABCD-1234".into(),
            verification_uri: "https://github.com/login/device".into(),
            expires_in: 900,
            interval: 5,
            device_code: "secret-device-code".into(),
        };
        assert!(!format!("{login:?}").contains("secret-device-code"));
    }

    #[test]
    fn token_errors_prefer_githubs_explanation() {
        assert_eq!(
            api_message(r#"{"message":"Bad credentials"}"#, 401),
            "HTTP 401: Bad credentials"
        );
        assert_eq!(api_message("", 503), "HTTP 503");
    }
}
