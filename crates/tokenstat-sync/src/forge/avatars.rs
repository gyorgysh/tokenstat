// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

//! Public profile pictures for the people who wrote a repository's commits.
//!
//! A history row knows an author's name and email, which say nothing about
//! their picture. The forge does: it links each pushed commit to an account.
//! One REST page of the branch's history answers a whole screen of rows, and
//! the email it pairs with each picture lets the same author's unpushed
//! commits share it.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::{CredentialSource, ForgeError, HttpFailure, Repo, auth, credential, response_text, rest_base};

/// Pictures by commit id and by author email, lowercased.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CommitAvatars {
    pub by_commit: HashMap<String, String>,
    pub by_email: HashMap<String, String>,
}

#[derive(Deserialize)]
struct RestCommit {
    sha: String,
    commit: RestCommitBody,
    author: Option<RestUser>,
}

#[derive(Deserialize)]
struct RestCommitBody {
    author: Option<RestSignature>,
}

#[derive(Deserialize)]
struct RestSignature {
    email: Option<String>,
}

#[derive(Deserialize)]
struct RestUser {
    avatar_url: Option<String>,
}

/// The newest 100 commits reachable from `from`, or from the default branch
/// when `from` is absent or the forge does not have it (a local commit that
/// was never pushed). Works without a sign-in for public repositories; a
/// stored credential is used when there is one.
pub fn commit_avatars(repo: &Repo, from: Option<&str>) -> Result<CommitAvatars, ForgeError> {
    let from = from.filter(|oid| is_commit_id(oid));
    match page(repo, from) {
        // Unknown to the forge: start from its default branch instead.
        Err(HttpFailure::NotFound) | Err(HttpFailure::Forge(ForgeError::Api(_))) if from.is_some() => {
            page(repo, None).map_err(Into::into)
        }
        result => result.map_err(Into::into),
    }
}

fn page(repo: &Repo, from: Option<&str>) -> Result<CommitAvatars, HttpFailure> {
    let mut url = format!(
        "{}/repos/{}/{}/commits?per_page=100",
        rest_base(repo),
        repo.owner,
        repo.repo
    );
    if let Some(oid) = from {
        url.push_str("&sha=");
        url.push_str(oid);
    }
    let stored = credential(&repo.host);
    let send = |bearer: Option<&str>| -> Result<String, HttpFailure> {
        let mut request = auth::http_client()?
            .get(&url)
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28");
        if let Some(bearer) = bearer {
            request = request.bearer_auth(bearer);
        }
        response_text(request.send().map_err(ForgeError::from)?)
    };
    let text = match stored.as_ref().map(|credential| send(Some(credential.bearer()))) {
        None => send(None)?,
        Some(Ok(text)) => text,
        Some(Err(HttpFailure::Unauthorized)) => match stored.as_ref().map(|c| c.source()) {
            // A stale app token: refresh once, as every other forge read does.
            Some(CredentialSource::Tokenstat) => {
                let bearer = stored.as_ref().map(|c| c.bearer().to_string()).unwrap_or_default();
                let refreshed = auth::refresh_stored(&repo.host, &bearer)?;
                send(Some(refreshed.bearer()))?
            }
            // Someone else's token that no longer works must not hide a
            // public repository's pictures.
            _ => send(None)?,
        },
        Some(Err(other)) => return Err(other),
    };
    decode(&text).map_err(HttpFailure::from)
}

fn decode(raw: &str) -> Result<CommitAvatars, ForgeError> {
    let commits: Vec<RestCommit> = serde_json::from_str(raw)?;
    let mut avatars = CommitAvatars::default();
    for commit in commits {
        let Some(url) = commit
            .author
            .and_then(|user| user.avatar_url)
            .filter(|url| url.starts_with("https://"))
        else {
            continue;
        };
        if let Some(email) = commit
            .commit
            .author
            .and_then(|signature| signature.email)
            .map(|email| email.trim().to_ascii_lowercase())
            .filter(|email| !email.is_empty())
        {
            avatars.by_email.entry(email).or_insert_with(|| url.clone());
        }
        avatars.by_commit.insert(commit.sha.to_ascii_lowercase(), url);
    }
    Ok(avatars)
}

/// Full SHA-1 or SHA-256 object ids only, so a caller cannot steer the URL.
fn is_commit_id(oid: &str) -> bool {
    matches!(oid.len(), 40 | 64) && oid.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pictures_are_keyed_by_commit_and_by_email() {
        let raw = r#"[
          {"sha":"AAAA","commit":{"author":{"email":"Ada@Example.com"}},"author":{"avatar_url":"https://avatars.example/u/1"}},
          {"sha":"bbbb","commit":{"author":{"email":"ada@example.com"}},"author":{"avatar_url":"https://avatars.example/u/1?v=2"}},
          {"sha":"cccc","commit":{"author":{"email":"ghost@example.com"}},"author":null},
          {"sha":"dddd","commit":{"author":{"email":"x@example.com"}},"author":{"avatar_url":"javascript:alert(1)"}}
        ]"#;
        let avatars = decode(raw).unwrap();
        assert_eq!(avatars.by_commit.get("aaaa").map(String::as_str), Some("https://avatars.example/u/1"));
        assert_eq!(avatars.by_commit.len(), 2);
        // The newest picture for an email wins.
        assert_eq!(avatars.by_email.get("ada@example.com").map(String::as_str), Some("https://avatars.example/u/1"));
        assert!(!avatars.by_email.contains_key("ghost@example.com"));
        assert!(!avatars.by_email.contains_key("x@example.com"));
    }

    #[test]
    fn only_full_object_ids_reach_the_url() {
        assert!(is_commit_id(&"a".repeat(40)));
        assert!(!is_commit_id("main"));
        assert!(!is_commit_id(&format!("{}&per_page=1", "a".repeat(40))));
    }
}
