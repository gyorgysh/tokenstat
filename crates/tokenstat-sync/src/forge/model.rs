use serde::Serialize;

use super::CredentialSource;

/// A repository address recovered from the local git remote.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    pub host: String,
    pub owner: String,
    pub repo: String,
}

/// Whether pull requests can be read for one repository.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum Availability {
    SignedOut,
    NeedsInstallation {
        login: String,
        install_url: String,
    },
    NoRepositoryAccess {
        login: String,
        source: CredentialSource,
        install_url: String,
    },
    Ready {
        login: String,
        source: CredentialSource,
        installation_id: Option<u64>,
    },
}
