//! Fixed GraphQL documents and their deliberately narrow decoders.

use serde::Deserialize;

use super::{
    CheckState, ForgeError, PullActor, PullCheck, PullDetail, PullFile, PullReview, PullSummary,
    Repo, Scope, State, TimelineEvent, TimelinePage,
};

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

pub(super) const DETAIL: &str = r#"
query PullRequestDetail($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      number title body url
      author { login avatarUrl }
      createdAt updatedAt headRefName baseRefName
      additions deletions changedFiles state isDraft reviewDecision
      mergeable mergeStateStatus
      labels(first: 20) { nodes { name } }
      assignees(first: 20) { nodes { login avatarUrl } }
      reviewRequests(first: 20) { nodes { requestedReviewer {
        ... on User { login avatarUrl }
        ... on Bot { login avatarUrl }
        ... on Mannequin { login avatarUrl }
        ... on Team { login: name avatarUrl }
      } } }
      reviews(last: 40) { nodes { author { login avatarUrl } state body submittedAt } }
      files(first: 100) { nodes { path additions deletions changeType } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 50) { nodes {
        ... on CheckRun {
          __typename name status conclusion detailsUrl startedAt completedAt
          checkSuite { workflowRun { workflow { name } } }
        }
        ... on StatusContext {
          __typename context state targetUrl createdAt
        }
      } } } } } }
    }
  }
}
"#;

pub(super) const TIMELINE: &str = r#"
query PullRequestTimeline($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      timelineItems(
        first: 40,
        after: $cursor,
        itemTypes: [
          PULL_REQUEST_COMMIT, ISSUE_COMMENT, PULL_REQUEST_REVIEW,
          LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT,
          REVIEW_REQUESTED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT,
          RENAMED_TITLE_EVENT, READY_FOR_REVIEW_EVENT, CLOSED_EVENT,
          REOPENED_EVENT, MERGED_EVENT
        ]
      ) {
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequestCommit {
            commit { oid messageHeadline committedDate author { name user { login avatarUrl } } }
          }
          ... on IssueComment { id author { login avatarUrl } createdAt body url }
          ... on PullRequestReview { id author { login avatarUrl } submittedAt body state url }
          ... on LabeledEvent { id actor { login avatarUrl } createdAt label { name } }
          ... on UnlabeledEvent { id actor { login avatarUrl } createdAt label { name } }
          ... on AssignedEvent { id actor { login avatarUrl } createdAt assignee {
            ... on User { login avatarUrl }
            ... on Bot { login avatarUrl }
            ... on Mannequin { login avatarUrl }
          } }
          ... on UnassignedEvent { id actor { login avatarUrl } createdAt assignee {
            ... on User { login avatarUrl }
            ... on Bot { login avatarUrl }
            ... on Mannequin { login avatarUrl }
          } }
          ... on ReviewRequestedEvent { id actor { login avatarUrl } createdAt requestedReviewer {
            ... on User { login avatarUrl }
            ... on Bot { login avatarUrl }
            ... on Mannequin { login avatarUrl }
            ... on Team { login: name avatarUrl }
          } }
          ... on HeadRefForcePushedEvent { id actor { login avatarUrl } createdAt beforeCommit { oid } afterCommit { oid } }
          ... on RenamedTitleEvent { id actor { login avatarUrl } createdAt previousTitle currentTitle }
          ... on ReadyForReviewEvent { id actor { login avatarUrl } createdAt }
          ... on ClosedEvent { id actor { login avatarUrl } createdAt }
          ... on ReopenedEvent { id actor { login avatarUrl } createdAt }
          ... on MergedEvent { id actor { login avatarUrl } createdAt mergeRefName }
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

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Actor {
    #[serde(default)]
    login: String,
    #[serde(default)]
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

pub(super) fn decode_detail(
    raw: &str,
    rate_limit_reset: Option<u64>,
) -> Result<PullDetail, ForgeError> {
    let body = graphql_body(raw, rate_limit_reset)?;
    let node = &body["data"]["repository"]["pullRequest"];
    if node.is_null() {
        return Err(ForgeError::Api("pull request was not found".into()));
    }

    let mut latest = std::collections::HashMap::<String, PullReview>::new();
    for review in array(&node["reviews"]["nodes"]) {
        let submitted_at = text(&review["submittedAt"]);
        if submitted_at.is_empty() {
            continue;
        }
        let author = pull_actor(&review["author"]);
        if author.login == "ghost" {
            continue;
        }
        let candidate = PullReview {
            author: author.clone(),
            state: text(&review["state"]).to_ascii_lowercase(),
            body: text(&review["body"]),
            submitted_at,
        };
        if latest
            .get(&author.login)
            .is_none_or(|current| current.submitted_at < candidate.submitted_at)
        {
            latest.insert(author.login.clone(), candidate);
        }
    }
    let mut reviews: Vec<_> = latest.into_values().collect();
    reviews.sort_by(|a, b| b.submitted_at.cmp(&a.submitted_at));

    let checks = array(&node["commits"]["nodes"])
        .last()
        .map(|commit| {
            array(&commit["commit"]["statusCheckRollup"]["contexts"]["nodes"])
                .into_iter()
                .filter_map(pull_check)
                .collect()
        })
        .unwrap_or_default();

    Ok(PullDetail {
        number: integer(&node["number"]),
        title: text(&node["title"]),
        body: text(&node["body"]),
        url: text(&node["url"]),
        author: pull_actor(&node["author"]),
        created_at: text(&node["createdAt"]),
        updated_at: text(&node["updatedAt"]),
        head_ref: text(&node["headRefName"]),
        base_ref: text(&node["baseRefName"]),
        additions: integer(&node["additions"]),
        deletions: integer(&node["deletions"]),
        changed_files: integer(&node["changedFiles"]),
        state: text(&node["state"]).to_ascii_lowercase(),
        draft: node["isDraft"].as_bool().unwrap_or(false),
        review_decision: optional_text(&node["reviewDecision"])
            .map(|value| value.to_ascii_lowercase()),
        mergeable: text(&node["mergeable"]).to_ascii_lowercase(),
        merge_state: text(&node["mergeStateStatus"]).to_ascii_lowercase(),
        labels: array(&node["labels"]["nodes"])
            .into_iter()
            .map(|label| text(&label["name"]))
            .collect(),
        assignees: array(&node["assignees"]["nodes"])
            .into_iter()
            .map(pull_actor)
            .filter(|actor| actor.login != "ghost")
            .collect(),
        review_requests: array(&node["reviewRequests"]["nodes"])
            .into_iter()
            .map(|request| pull_actor(&request["requestedReviewer"]))
            .filter(|actor| actor.login != "ghost")
            .collect(),
        reviews,
        files: array(&node["files"]["nodes"])
            .into_iter()
            .map(|file| PullFile {
                path: text(&file["path"]),
                additions: integer(&file["additions"]),
                deletions: integer(&file["deletions"]),
                change_type: text(&file["changeType"]).to_ascii_lowercase(),
            })
            .collect(),
        checks,
    })
}

pub(super) fn decode_timeline(
    raw: &str,
    rate_limit_reset: Option<u64>,
) -> Result<TimelinePage, ForgeError> {
    let body = graphql_body(raw, rate_limit_reset)?;
    let items = &body["data"]["repository"]["pullRequest"]["timelineItems"];
    if items.is_null() {
        return Err(ForgeError::Api(
            "pull request timeline was not found".into(),
        ));
    }
    let events = array(&items["nodes"])
        .into_iter()
        .filter_map(timeline_event)
        .collect();
    let next_cursor = items["pageInfo"]["hasNextPage"]
        .as_bool()
        .unwrap_or(false)
        .then(|| optional_text(&items["pageInfo"]["endCursor"]))
        .flatten();
    Ok(TimelinePage {
        events,
        next_cursor,
    })
}

fn pull_check(node: &serde_json::Value) -> Option<PullCheck> {
    match node["__typename"].as_str()? {
        "CheckRun" => {
            let status = node["status"].as_str().unwrap_or_default();
            let conclusion = node["conclusion"].as_str();
            let state = if status != "COMPLETED" {
                "pending"
            } else {
                match conclusion {
                    Some("SUCCESS" | "NEUTRAL" | "SKIPPED") => "passing",
                    Some(
                        "FAILURE" | "TIMED_OUT" | "ACTION_REQUIRED" | "STARTUP_FAILURE" | "STALE",
                    ) => "failing",
                    _ => "pending",
                }
            };
            Some(PullCheck {
                name: text(&node["name"]),
                workflow: optional_text(&node["checkSuite"]["workflowRun"]["workflow"]["name"]),
                state: state.into(),
                started_at: optional_text(&node["startedAt"]),
                completed_at: optional_text(&node["completedAt"]),
                url: optional_text(&node["detailsUrl"]),
            })
        }
        "StatusContext" => {
            let state = match node["state"].as_str().unwrap_or_default() {
                "SUCCESS" => "passing",
                "FAILURE" | "ERROR" => "failing",
                _ => "pending",
            };
            Some(PullCheck {
                name: text(&node["context"]),
                workflow: None,
                state: state.into(),
                started_at: optional_text(&node["createdAt"]),
                completed_at: None,
                url: optional_text(&node["targetUrl"]),
            })
        }
        _ => None,
    }
}

fn timeline_event(node: &serde_json::Value) -> Option<TimelineEvent> {
    let typename = node["__typename"].as_str()?;
    if typename == "PullRequestCommit" {
        let commit = &node["commit"];
        let mut actor = pull_actor(&commit["author"]["user"]);
        if actor.login == "ghost" {
            actor.login =
                optional_text(&commit["author"]["name"]).unwrap_or_else(|| "ghost".into());
        }
        let oid = text(&commit["oid"]);
        return Some(TimelineEvent {
            id: format!("commit:{oid}"),
            kind: "committed".into(),
            actor,
            created_at: text(&commit["committedDate"]),
            body: None,
            subject: optional_text(&commit["messageHeadline"]),
            state: Some(oid.chars().take(7).collect()),
            url: None,
        });
    }

    let id = text(&node["id"]);
    let actor = pull_actor(&node["actor"]);
    let created_at = text(&node["createdAt"]);
    let (kind, subject, state, body, url) = match typename {
        "IssueComment" => (
            "commented",
            None,
            None,
            optional_text(&node["body"]),
            optional_text(&node["url"]),
        ),
        "PullRequestReview" => (
            "reviewed",
            None,
            optional_text(&node["state"]).map(|value| value.to_ascii_lowercase()),
            optional_text(&node["body"]),
            optional_text(&node["url"]),
        ),
        "LabeledEvent" => (
            "labeled",
            optional_text(&node["label"]["name"]),
            None,
            None,
            None,
        ),
        "UnlabeledEvent" => (
            "unlabeled",
            optional_text(&node["label"]["name"]),
            None,
            None,
            None,
        ),
        "AssignedEvent" => (
            "assigned",
            optional_text(&node["assignee"]["login"]),
            None,
            None,
            None,
        ),
        "UnassignedEvent" => (
            "unassigned",
            optional_text(&node["assignee"]["login"]),
            None,
            None,
            None,
        ),
        "ReviewRequestedEvent" => (
            "reviewRequested",
            optional_text(&node["requestedReviewer"]["login"]),
            None,
            None,
            None,
        ),
        "HeadRefForcePushedEvent" => {
            let before = text(&node["beforeCommit"]["oid"])
                .chars()
                .take(7)
                .collect::<String>();
            let after = text(&node["afterCommit"]["oid"])
                .chars()
                .take(7)
                .collect::<String>();
            (
                "forcePushed",
                Some(format!("{before} → {after}")),
                None,
                None,
                None,
            )
        }
        "RenamedTitleEvent" => (
            "renamed",
            Some(format!(
                "{} → {}",
                text(&node["previousTitle"]),
                text(&node["currentTitle"])
            )),
            None,
            None,
            None,
        ),
        "ReadyForReviewEvent" => ("readyForReview", None, None, None, None),
        "ClosedEvent" => ("closed", None, None, None, None),
        "ReopenedEvent" => ("reopened", None, None, None, None),
        "MergedEvent" => (
            "merged",
            optional_text(&node["mergeRefName"]),
            None,
            None,
            None,
        ),
        _ => return None,
    };
    let actor = if matches!(typename, "IssueComment" | "PullRequestReview") {
        pull_actor(&node["author"])
    } else {
        actor
    };
    let created_at = if typename == "PullRequestReview" {
        optional_text(&node["submittedAt"])?
    } else {
        created_at
    };
    Some(TimelineEvent {
        id,
        kind: kind.into(),
        actor,
        created_at,
        body: body.filter(|body| !body.is_empty()),
        subject,
        state,
        url,
    })
}

fn graphql_body(raw: &str, reset: Option<u64>) -> Result<serde_json::Value, ForgeError> {
    let body: serde_json::Value = serde_json::from_str(raw)?;
    let errors = array(&body["errors"]);
    if errors.is_empty() {
        return Ok(body);
    }
    if errors.iter().any(|error| {
        error["extensions"]["code"]
            .as_str()
            .is_some_and(|code| code == "RATE_LIMITED")
    }) {
        return Err(ForgeError::RateLimited { reset });
    }
    Err(ForgeError::Api(
        errors
            .into_iter()
            .filter_map(|error| error["message"].as_str())
            .collect::<Vec<_>>()
            .join("; "),
    ))
}

fn pull_actor(value: &serde_json::Value) -> PullActor {
    PullActor {
        login: optional_text(&value["login"]).unwrap_or_else(|| "ghost".into()),
        avatar: optional_text(&value["avatarUrl"]),
    }
}

fn array(value: &serde_json::Value) -> Vec<&serde_json::Value> {
    value
        .as_array()
        .map(|values| values.iter().filter(|value| !value.is_null()).collect())
        .unwrap_or_default()
}

fn text(value: &serde_json::Value) -> String {
    value.as_str().unwrap_or_default().to_string()
}

fn optional_text(value: &serde_json::Value) -> Option<String> {
    value
        .as_str()
        .map(str::to_string)
        .filter(|value| !value.is_empty())
}

fn integer(value: &serde_json::Value) -> u32 {
    value
        .as_u64()
        .and_then(|value| value.try_into().ok())
        .unwrap_or(0)
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

    #[test]
    fn detail_keeps_latest_reviews_and_normalizes_checks() {
        let raw = r#"{"data":{"repository":{"pullRequest":{
          "number":42,"title":"A polished detail","body":"Hello **world**","url":"https://github.test/p/42",
          "author":{"login":"octo","avatarUrl":"https://avatars.test/octo"},
          "createdAt":"2026-08-20T01:00:00Z","updatedAt":"2026-08-29T01:00:00Z",
          "headRefName":"feature","baseRefName":"main","additions":9,"deletions":2,"changedFiles":1,
          "state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN",
          "labels":{"nodes":[{"name":"ui"}]},"assignees":{"nodes":[{"login":"sam","avatarUrl":null}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"design","avatarUrl":"https://avatars.test/design"}}]},
          "reviews":{"nodes":[
            {"author":{"login":"sam","avatarUrl":null},"state":"CHANGES_REQUESTED","body":"Earlier","submittedAt":"2026-08-27T01:00:00Z"},
            {"author":{"login":"sam","avatarUrl":null},"state":"APPROVED","body":"Lovely","submittedAt":"2026-08-28T01:00:00Z"}]},
          "files":{"nodes":[{"path":"Sources/App.swift","additions":9,"deletions":2,"changeType":"MODIFIED"}]},
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"UI tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-29T00:00:00Z","completedAt":"2026-08-29T00:02:00Z","detailsUrl":"https://checks.test/1","checkSuite":{"workflowRun":{"workflow":{"name":"Quality"}}}},
            {"__typename":"StatusContext","context":"preview","state":"PENDING","createdAt":"2026-08-29T00:00:00Z","targetUrl":null}
          ]}}}}]}
        }}}}"#;
        let detail = decode_detail(raw, None).unwrap();
        assert_eq!(detail.number, 42);
        assert_eq!(detail.review_decision.as_deref(), Some("approved"));
        assert_eq!(detail.reviews.len(), 1);
        assert_eq!(detail.reviews[0].body, "Lovely");
        assert_eq!(detail.files[0].change_type, "modified");
        assert_eq!(detail.checks[0].state, "passing");
        assert_eq!(detail.checks[0].workflow.as_deref(), Some("Quality"));
        assert_eq!(detail.checks[1].state, "pending");
    }

    #[test]
    fn timeline_pages_known_events_and_ignores_new_union_members() {
        let raw = r#"{"data":{"repository":{"pullRequest":{"timelineItems":{
          "nodes":[
            {"__typename":"IssueComment","id":"c1","author":{"login":"octo","avatarUrl":null},"createdAt":"2026-08-28T01:00:00Z","body":"Nice work","url":"https://github.test/c1"},
            {"__typename":"PullRequestReview","id":"r1","author":{"login":"sam","avatarUrl":null},"submittedAt":"2026-08-28T02:00:00Z","body":"Ship it","state":"APPROVED","url":"https://github.test/r1"},
            {"__typename":"PullRequestCommit","commit":{"oid":"1234567890","messageHeadline":"Polish detail","committedDate":"2026-08-28T03:00:00Z","author":{"name":"Taylor","user":null}}},
            {"__typename":"AddedToProjectEvent","id":"future"}
          ],"pageInfo":{"hasNextPage":true,"endCursor":"next-page"}
        }}}}}"#;
        let page = decode_timeline(raw, None).unwrap();
        assert_eq!(page.events.len(), 3);
        assert_eq!(page.events[0].kind, "commented");
        assert_eq!(page.events[1].state.as_deref(), Some("approved"));
        assert_eq!(page.events[2].actor.login, "Taylor");
        assert_eq!(page.events[2].state.as_deref(), Some("1234567"));
        assert_eq!(page.next_cursor.as_deref(), Some("next-page"));
    }
}
