use serde::{Deserialize, Serialize};

use super::CredentialSource;

/// A repository address recovered from the local git remote.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
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

/// Which relationship to the signed-in account narrows the list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    All,
    Mine,
    Assigned,
    ReviewRequested,
}

/// The lifecycle slice shown by the pull-request list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Open,
    Merged,
    Closed,
    Draft,
}

/// The one checks answer useful in a compact list row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckState {
    Passing,
    Failing,
    Pending,
}

/// One pull request in the workspace list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullSummary {
    pub number: u32,
    pub title: String,
    pub author: String,
    pub author_avatar: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub head_ref: String,
    pub base_ref: String,
    pub additions: u32,
    pub deletions: u32,
    pub changed_files: u32,
    pub state: String,
    pub draft: bool,
    pub review_decision: Option<String>,
    pub labels: Vec<String>,
    pub comments: u32,
    pub checks: Option<CheckState>,
}
