//! Git forge access used by the pull-request screens.
//!
//! Requests go directly from the host machine to the forge. Credentials stay
//! in the private credential store and never enter the archive or account sync.

mod auth;
mod model;
mod query;

pub use auth::{
    APP_SLUG, Credential, CredentialSource, DeviceLogin, DeviceStatus, ForgeError, credential,
    device_poll, device_start, set_token, sign_out,
};
pub use model::{Availability, CheckState, PullSummary, Repo, Scope, State};

/// Public OAuth client identifier for tokenstat's GitHub App.
///
/// A device-flow client identifier names the app; it is not a secret and is
/// necessarily shipped in every installed client. No client secret or private
/// key is used by this flow.
pub const GITHUB_CLIENT_ID: &str = "Iv23lih7KyYQNkeyuak1";

use serde::de::DeserializeOwned;

/// Read one filtered page of pull requests in a single GraphQL request.
pub fn list(
    repo: &Repo,
    scope: Scope,
    state: State,
    limit: u32,
) -> Result<Vec<PullSummary>, ForgeError> {
    let Some(credential) = credential(&repo.host) else {
        return Err(ForgeError::NotSignedIn);
    };
    match list_once(repo, scope, state, limit, &credential) {
        Err(HttpFailure::Unauthorized) if credential.source() == CredentialSource::Tokenstat => {
            let refreshed = auth::refresh_stored(&repo.host)?;
            list_once(repo, scope, state, limit, &refreshed).map_err(Into::into)
        }
        result => result.map_err(Into::into),
    }
}

fn list_once(
    repo: &Repo,
    scope: Scope,
    state: State,
    limit: u32,
    credential: &Credential,
) -> Result<Vec<PullSummary>, HttpFailure> {
    let body = serde_json::json!({
        "query": query::LIST,
        "variables": {
            "query": query::search_query(repo, scope, state),
            "limit": limit.clamp(1, 40),
        }
    });
    let endpoint = if repo.host.eq_ignore_ascii_case("github.com") {
        "https://api.github.com/graphql".to_string()
    } else {
        format!("https://{}/api/graphql", repo.host)
    };
    let response = auth::http_client()?
        .post(endpoint)
        .header("accept", "application/vnd.github+json")
        .header("x-github-api-version", "2022-11-28")
        .bearer_auth(credential.bearer())
        .json(&body)
        .send()
        .map_err(ForgeError::from)?;
    let status = response.status();
    let reset = response
        .headers()
        .get("x-ratelimit-reset")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    let remaining = response
        .headers()
        .get("x-ratelimit-remaining")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());
    let text = response.text().map_err(ForgeError::from)?;
    match status.as_u16() {
        401 => Err(HttpFailure::Unauthorized),
        403 if remaining == Some(0) => Err(HttpFailure::Forge(ForgeError::RateLimited { reset })),
        403 => Err(HttpFailure::Forbidden),
        404 => Err(HttpFailure::NotFound),
        429 => Err(HttpFailure::Forge(ForgeError::RateLimited { reset })),
        _ if !status.is_success() => Err(HttpFailure::Forge(ForgeError::Api(format!(
            "HTTP {}: {}",
            status.as_u16(),
            text.trim()
        )))),
        _ => query::decode_list(&text, reset).map_err(HttpFailure::from),
    }
}

/// Resolve the signed-in account and whether it may access this repository.
/// No installation or permission change is made here; the returned URL is an
/// explicit action for the UI to offer.
pub fn availability(repo: &Repo) -> Result<Availability, ForgeError> {
    let Some(credential) = credential(&repo.host) else {
        return Ok(Availability::SignedOut);
    };
    match availability_once(repo, &credential) {
        Err(HttpFailure::Unauthorized) if credential.source() == CredentialSource::Tokenstat => {
            let refreshed = auth::refresh_stored(&repo.host)?;
            availability_once(repo, &refreshed).map_err(Into::into)
        }
        result => result.map_err(Into::into),
    }
}

fn availability_once(repo: &Repo, credential: &Credential) -> Result<Availability, HttpFailure> {
    #[derive(serde::Deserialize)]
    struct User {
        login: String,
    }
    let user: User = get_json(repo, "/user", credential)?;

    // Borrowed git/PAT credentials are not authorizations of tokenstat's
    // GitHub App. Probe the selected repository directly and use them in place;
    // never copy them into tokenstat's store.
    if credential.source() != CredentialSource::Tokenstat {
        let path = format!("/repos/{}/{}", repo.owner, repo.repo);
        return match get_json::<serde_json::Value>(repo, &path, credential) {
            Ok(_) => Ok(Availability::Ready {
                login: user.login,
                source: credential.source(),
                installation_id: None,
            }),
            Err(HttpFailure::Forbidden | HttpFailure::NotFound) => {
                Ok(Availability::NoRepositoryAccess {
                    login: user.login,
                    source: credential.source(),
                    install_url: install_url(&repo.host),
                })
            }
            Err(error) => Err(error),
        };
    }

    #[derive(serde::Deserialize)]
    struct Installations {
        installations: Vec<Installation>,
    }
    #[derive(serde::Deserialize)]
    struct Installation {
        id: u64,
    }
    #[derive(serde::Deserialize)]
    struct Repositories {
        repositories: Vec<Repository>,
    }
    #[derive(serde::Deserialize)]
    struct Repository {
        full_name: String,
    }

    let mut installations = Vec::new();
    for page in 1..=100 {
        let path = format!("/user/installations?per_page=100&page={page}");
        let batch: Installations = get_json(repo, &path, credential)?;
        let last_page = batch.installations.len() < 100;
        installations.extend(batch.installations);
        if last_page {
            break;
        }
    }
    if installations.is_empty() {
        return Ok(Availability::NeedsInstallation {
            login: user.login,
            install_url: install_url(&repo.host),
        });
    }
    let wanted = format!("{}/{}", repo.owner, repo.repo);
    for installation in installations {
        for page in 1..=100 {
            let path = format!(
                "/user/installations/{}/repositories?per_page=100&page={page}",
                installation.id
            );
            let repositories: Repositories = get_json(repo, &path, credential)?;
            if repositories
                .repositories
                .iter()
                .any(|candidate| candidate.full_name.eq_ignore_ascii_case(&wanted))
            {
                return Ok(Availability::Ready {
                    login: user.login,
                    source: credential.source(),
                    installation_id: Some(installation.id),
                });
            }
            if repositories.repositories.len() < 100 {
                break;
            }
        }
    }
    Ok(Availability::NoRepositoryAccess {
        login: user.login,
        source: credential.source(),
        install_url: install_url(&repo.host),
    })
}

fn install_url(host: &str) -> String {
    if host.eq_ignore_ascii_case("github.com") {
        format!("https://github.com/apps/{APP_SLUG}/installations/new")
    } else {
        format!("https://{host}/github-apps/{APP_SLUG}/installations/new")
    }
}

#[derive(Debug)]
enum HttpFailure {
    Unauthorized,
    Forbidden,
    NotFound,
    Forge(ForgeError),
}

impl From<ForgeError> for HttpFailure {
    fn from(value: ForgeError) -> Self {
        Self::Forge(value)
    }
}

impl From<HttpFailure> for ForgeError {
    fn from(value: HttpFailure) -> Self {
        match value {
            HttpFailure::Unauthorized => ForgeError::NotSignedIn,
            HttpFailure::Forbidden => ForgeError::Api("access was not granted".into()),
            HttpFailure::NotFound => ForgeError::Api("repository was not found".into()),
            HttpFailure::Forge(error) => error,
        }
    }
}

fn get_json<T: DeserializeOwned>(
    repo: &Repo,
    path: &str,
    credential: &Credential,
) -> Result<T, HttpFailure> {
    let base = if repo.host.eq_ignore_ascii_case("github.com") {
        "https://api.github.com".to_string()
    } else {
        format!("https://{}/api/v3", repo.host)
    };
    let response = auth::http_client()?
        .get(format!("{base}{path}"))
        .header("accept", "application/vnd.github+json")
        .header("x-github-api-version", "2022-11-28")
        .bearer_auth(credential.bearer())
        .send()
        .map_err(ForgeError::from)?;
    let status = response.status();
    let text = response.text().map_err(ForgeError::from)?;
    match status.as_u16() {
        401 => Err(HttpFailure::Unauthorized),
        403 => Err(HttpFailure::Forbidden),
        404 => Err(HttpFailure::NotFound),
        _ if !status.is_success() => Err(HttpFailure::Forge(ForgeError::Api(format!(
            "HTTP {}: {}",
            status.as_u16(),
            text.trim()
        )))),
        _ => serde_json::from_str(&text)
            .map_err(ForgeError::from)
            .map_err(HttpFailure::from),
    }
}
