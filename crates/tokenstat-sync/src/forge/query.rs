//! Fixed GraphQL documents and their deliberately narrow decoders.

use serde::Deserialize;

use super::{CheckState, ForgeError, PullSummary, Repo, Scope, State};

pub(super) const LIST: &str = r#"
query PullRequestList($query: String!, $limit: Int!) {
  search(type: ISSUE, query: $query, first: $limit) {
    nodes {
      ... on PullRequest {
        number
        title
        author { login avatarUrl }
        createdAt
        updatedAt
        headRefName
        baseRefName
        additions
        deletions
        changedFiles
        state
        isDraft
        reviewDecision
        labels(first: 20) { nodes { name } }
        comments { totalCount }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state } } }
        }
      }
    }
  }
}
"#;

pub(super) fn search_query(repo: &Repo, scope: Scope, state: State) -> String {
    let lifecycle = match state {
        State::Open => "is:open is:unmerged",
        State::Merged => "is:merged",
        State::Closed => "is:closed is:unmerged",
        State::Draft => "is:open is:draft",
    };
    let relationship = match scope {
        Scope::All => "",
        Scope::Mine => " author:@me",
        Scope::Assigned => " assignee:@me",
        Scope::ReviewRequested => " review-requested:@me",
    };
    format!(
        "repo:{}/{} is:pr {lifecycle}{relationship} sort:updated-desc",
        repo.owner, repo.repo
    )
}

#[derive(Deserialize)]
struct Envelope {
    data: Option<Data>,
    #[serde(default)]
    errors: Vec<GraphError>,
}

#[derive(Deserialize)]
struct GraphError {
    message: String,
    extensions: Option<GraphErrorExtensions>,
}

#[derive(Deserialize)]
struct GraphErrorExtensions {
    #[serde(default)]
    code: String,
}

#[derive(Deserialize)]
struct Data {
    search: Search,
}

#[derive(Deserialize)]
struct Search {
    nodes: Vec<Option<Node>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Node {
    number: u32,
    title: String,
    author: Option<Actor>,
    created_at: String,
    updated_at: String,
    head_ref_name: String,
    base_ref_name: String,
    additions: u32,
    deletions: u32,
    changed_files: u32,
    state: String,
    is_draft: bool,
    review_decision: Option<String>,
    labels: Labels,
    comments: Count,
    commits: Commits,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Actor {
    login: String,
    avatar_url: Option<String>,
}

#[derive(Deserialize)]
struct Labels {
    nodes: Vec<Label>,
}

#[derive(Deserialize)]
struct Label {
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Count {
    total_count: u32,
}

#[derive(Deserialize)]
struct Commits {
    nodes: Vec<CommitNode>,
}

#[derive(Deserialize)]
struct CommitNode {
    commit: Commit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Commit {
    status_check_rollup: Option<Rollup>,
}

#[derive(Deserialize)]
struct Rollup {
    state: String,
}

pub(super) fn decode_list(
    raw: &str,
    rate_limit_reset: Option<u64>,
) -> Result<Vec<PullSummary>, ForgeError> {
    let body: Envelope = serde_json::from_str(raw)?;
    if !body.errors.is_empty() {
        if body.errors.iter().any(|error| {
            error
                .extensions
                .as_ref()
                .is_some_and(|extensions| extensions.code == "RATE_LIMITED")
        }) {
            return Err(ForgeError::RateLimited {
                reset: rate_limit_reset,
            });
        }
        let message = body
            .errors
            .into_iter()
            .map(|error| error.message)
            .collect::<Vec<_>>()
            .join("; ");
        return Err(ForgeError::Api(message));
    }
    let data = body
        .data
        .ok_or_else(|| ForgeError::Api("GitHub returned no pull-request data".into()))?;
    Ok(data
        .search
        .nodes
        .into_iter()
        .flatten()
        .map(|node| {
            let actor = node.author.unwrap_or(Actor {
                login: "ghost".into(),
                avatar_url: None,
            });
            let checks = node
                .commits
                .nodes
                .last()
                .and_then(|commit| commit.commit.status_check_rollup.as_ref())
                .and_then(|rollup| match rollup.state.as_str() {
                    "SUCCESS" => Some(CheckState::Passing),
                    "FAILURE" | "ERROR" => Some(CheckState::Failing),
                    "PENDING" | "EXPECTED" => Some(CheckState::Pending),
                    _ => None,
                });
            PullSummary {
                number: node.number,
                title: node.title,
                author: actor.login,
                author_avatar: actor.avatar_url,
                created_at: node.created_at,
                updated_at: node.updated_at,
                head_ref: node.head_ref_name,
                base_ref: node.base_ref_name,
                additions: node.additions,
                deletions: node.deletions,
                changed_files: node.changed_files,
                state: node.state.to_ascii_lowercase(),
                draft: node.is_draft,
                review_decision: node.review_decision.map(|value| value.to_ascii_lowercase()),
                labels: node
                    .labels
                    .nodes
                    .into_iter()
                    .map(|label| label.name)
                    .collect(),
                comments: node.comments.total_count,
                checks,
            }
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_are_composed_as_two_axes() {
        let repo = Repo {
            host: "github.com".into(),
            owner: "pueev".into(),
            repo: "tokenstat".into(),
        };
        assert_eq!(
            search_query(&repo, Scope::ReviewRequested, State::Draft),
            "repo:pueev/tokenstat is:pr is:open is:draft review-requested:@me sort:updated-desc"
        );
        assert!(search_query(&repo, Scope::All, State::Closed).contains("is:closed is:unmerged"));
    }

    #[test]
    fn list_decodes_absent_checks_and_bot_or_deleted_authors() {
        let raw = r#"{
          "data":{"search":{"nodes":[
            {"number":12,"title":"Ready","author":{"login":"renovate[bot]","avatarUrl":"https://avatars.test/1"},
             "createdAt":"2026-08-27T01:02:03Z","updatedAt":"2026-08-28T04:05:06Z",
             "headRefName":"deps","baseRefName":"main","additions":3,"deletions":1,"changedFiles":2,
             "state":"OPEN","isDraft":false,"reviewDecision":null,
             "labels":{"nodes":[{"name":"dependencies"}]},"comments":{"totalCount":4},
             "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},
            {"number":11,"title":"Old","author":null,
             "createdAt":"2026-08-20T01:02:03Z","updatedAt":"2026-08-21T04:05:06Z",
             "headRefName":"old","baseRefName":"main","additions":0,"deletions":0,"changedFiles":0,
             "state":"CLOSED","isDraft":false,"reviewDecision":"CHANGES_REQUESTED",
             "labels":{"nodes":[]},"comments":{"totalCount":0},"commits":{"nodes":[]}}
          ]}}}
        "#;
        let rows = decode_list(raw, None).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].checks, Some(CheckState::Passing));
        assert_eq!(rows[0].author, "renovate[bot]");
        assert_eq!(rows[1].author, "ghost");
        assert_eq!(rows[1].checks, None);
        assert_eq!(
            rows[1].review_decision.as_deref(),
            Some("changes_requested")
        );
    }

    #[test]
    fn graphql_errors_are_not_misreported_as_empty_lists() {
        let error = decode_list(
            r#"{"data":null,"errors":[{"message":"repository unavailable"}]}"#,
            None,
        )
        .unwrap_err();
        assert!(error.to_string().contains("repository unavailable"));
    }

    #[test]
    fn graphql_rate_limit_keeps_the_reset_time() {
        let error = decode_list(
            r#"{"data":null,"errors":[{"message":"rate limit","extensions":{"code":"RATE_LIMITED"}}]}"#,
            Some(1_800_000_000),
        )
        .unwrap_err();
        assert!(error.to_string().contains("2027-01"));
    }
}
