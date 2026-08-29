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

/// The history shape GitHub should create when a pull request is merged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum MergeMethod {
    Merge,
    Squash,
    Rebase,
}

/// A submitted pull-request review. Each variant is an explicit user action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Verdict {
    Approve,
    RequestChanges,
    Comment,
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

/// A forge account or team shown around a pull request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullActor {
    pub login: String,
    pub avatar: Option<String>,
}

/// One reviewer's latest submitted verdict.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullReview {
    pub author: PullActor,
    pub state: String,
    pub body: String,
    pub submitted_at: String,
}

/// One changed file, used by the inspector before its diff is requested.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullFile {
    pub path: String,
    pub additions: u32,
    pub deletions: u32,
    pub change_type: String,
}

/// One check run or legacy commit status on the pull request's head commit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullCheck {
    pub name: String,
    pub workflow: Option<String>,
    pub state: String,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
    pub url: Option<String>,
}

/// Full read-only metadata for a pull request. Conversation events and the
/// unified diff are paged separately so opening one tab does not over-fetch
/// another.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullDetail {
    pub number: u32,
    pub title: String,
    pub body: String,
    pub url: String,
    pub author: PullActor,
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
    pub mergeable: String,
    pub merge_state: String,
    pub labels: Vec<String>,
    pub assignees: Vec<PullActor>,
    pub review_requests: Vec<PullActor>,
    pub reviews: Vec<PullReview>,
    pub files: Vec<PullFile>,
    pub checks: Vec<PullCheck>,
}

/// One supported item in the pull-request conversation. Unknown GraphQL union
/// members are deliberately dropped by the decoder rather than aborting the
/// page when GitHub adds a new event type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineEvent {
    pub id: String,
    pub kind: String,
    pub actor: PullActor,
    pub created_at: String,
    pub body: Option<String>,
    pub subject: Option<String>,
    pub state: Option<String>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelinePage {
    pub events: Vec<TimelineEvent>,
    pub next_cursor: Option<String>,
}
