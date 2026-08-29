//! Pull-request requests that change something other people can see.
//!
//! Nothing in this module may run from a watcher, refresh path, or timer.
//! Every caller arrives here from one explicit press in a client. Keep writes
//! separate from the read module so an innocent list refresh cannot acquire a
//! side effect later.

use reqwest::Method;
use serde_json::{Value, json};

use super::{
    Credential, CredentialSource, ForgeError, HttpFailure, MergeMethod, Repo, Verdict, auth,
    graphql_endpoint, response_text, rest_base,
};

/// Add one issue comment to the pull request's conversation.
pub fn comment(repo: &Repo, number: u32, body: &str) -> Result<(), ForgeError> {
    let body = required_body(body, "a comment")?;
    with_credential(repo, |credential| {
        rest(
            repo,
            credential,
            Method::POST,
            &format!(
                "/repos/{}/{}/issues/{number}/comments",
                repo.owner, repo.repo
            ),
            json!({"body": body}),
        )?;
        Ok(())
    })
}

/// Close a pull request. This is called only after the client's confirmation.
pub fn close(repo: &Repo, number: u32) -> Result<(), ForgeError> {
    set_state(repo, number, "closed")
}

/// Reopen a pull request after one explicit press.
pub fn reopen(repo: &Repo, number: u32) -> Result<(), ForgeError> {
    set_state(repo, number, "open")
}

fn set_state(repo: &Repo, number: u32, state: &str) -> Result<(), ForgeError> {
    with_credential(repo, |credential| {
        rest(
            repo,
            credential,
            Method::PATCH,
            &format!("/repos/{}/{}/pulls/{number}", repo.owner, repo.repo),
            json!({"state": state}),
        )?;
        Ok(())
    })
}

/// Submit an approval, change request, or review comment.
pub fn review(
    repo: &Repo,
    number: u32,
    verdict: Verdict,
    body: Option<&str>,
) -> Result<(), ForgeError> {
    let body = body.map(str::trim).filter(|body| !body.is_empty());
    if matches!(verdict, Verdict::RequestChanges | Verdict::Comment) && body.is_none() {
        return Err(ForgeError::Api(
            "this review needs a message before it can be sent".into(),
        ));
    }
    let event = match verdict {
        Verdict::Approve => "APPROVE",
        Verdict::RequestChanges => "REQUEST_CHANGES",
        Verdict::Comment => "COMMENT",
    };
    with_credential(repo, |credential| {
        rest(
            repo,
            credential,
            Method::POST,
            &format!("/repos/{}/{}/pulls/{number}/reviews", repo.owner, repo.repo),
            json!({"event": event, "body": body.unwrap_or_default()}),
        )?;
        Ok(())
    })
}

/// Mark a draft pull request ready for review.
pub fn ready(repo: &Repo, number: u32) -> Result<(), ForgeError> {
    with_credential(repo, |credential| {
        let pull = rest(
            repo,
            credential,
            Method::GET,
            &format!("/repos/{}/{}/pulls/{number}", repo.owner, repo.repo),
            Value::Null,
        )?;
        let node_id = pull["node_id"]
            .as_str()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ForgeError::Api("GitHub did not return the pull request id".into()))?;
        let response = auth::http_client()?
            .post(graphql_endpoint(repo))
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28")
            .bearer_auth(credential.bearer())
            .json(&json!({
                "query": "mutation Ready($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }",
                "variables": {"id": node_id},
            }))
            .send()
            .map_err(ForgeError::from)?;
        let raw = response_text(response)?;
        graphql_success(&raw)?;
        Ok(())
    })
}

/// Merge with the explicitly selected history method.
pub fn merge(repo: &Repo, number: u32, method: MergeMethod) -> Result<(), ForgeError> {
    let method = match method {
        MergeMethod::Merge => "merge",
        MergeMethod::Squash => "squash",
        MergeMethod::Rebase => "rebase",
    };
    with_credential(repo, |credential| {
        let result = rest(
            repo,
            credential,
            Method::PUT,
            &format!("/repos/{}/{}/pulls/{number}/merge", repo.owner, repo.repo),
            json!({"merge_method": method}),
        )?;
        if result["merged"].as_bool() == Some(false) {
            return Err(HttpFailure::Forge(ForgeError::Api(
                result["message"]
                    .as_str()
                    .unwrap_or("GitHub did not merge this pull request")
                    .into(),
            )));
        }
        Ok(())
    })
}

fn required_body<'a>(body: &'a str, noun: &str) -> Result<&'a str, ForgeError> {
    let body = body.trim();
    if body.is_empty() {
        return Err(ForgeError::Api(format!("{noun} cannot be empty")));
    }
    Ok(body)
}

fn with_credential<T>(
    repo: &Repo,
    operation: impl Fn(&Credential) -> Result<T, HttpFailure>,
) -> Result<T, ForgeError> {
    let Some(credential) = super::credential(&repo.host) else {
        return Err(ForgeError::NotSignedIn);
    };
    match operation(&credential) {
        Err(HttpFailure::Unauthorized) if credential.source() == CredentialSource::Tokenstat => {
            let refreshed = auth::refresh_stored(&repo.host)?;
            operation(&refreshed).map_err(Into::into)
        }
        result => result.map_err(Into::into),
    }
}

fn rest(
    repo: &Repo,
    credential: &Credential,
    method: Method,
    path: &str,
    body: Value,
) -> Result<Value, HttpFailure> {
    let mut request = auth::http_client()?
        .request(method.clone(), format!("{}{}", rest_base(repo), path))
        .header("accept", "application/vnd.github+json")
        .header("x-github-api-version", "2022-11-28")
        .bearer_auth(credential.bearer());
    if method != Method::GET {
        request = request.json(&body);
    }
    let raw = response_text(request.send().map_err(ForgeError::from)?)?;
    if raw.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&raw)
        .map_err(ForgeError::from)
        .map_err(HttpFailure::from)
}

fn graphql_success(raw: &str) -> Result<(), HttpFailure> {
    let value: Value = serde_json::from_str(raw).map_err(ForgeError::from)?;
    let messages = value["errors"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|error| error["message"].as_str())
        .collect::<Vec<_>>();
    if messages.is_empty() {
        Ok(())
    } else {
        Err(HttpFailure::Forge(ForgeError::Api(messages.join("; "))))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bodies_are_trimmed_and_empty_messages_are_refused() {
        assert_eq!(required_body("  hello  ", "a comment").unwrap(), "hello");
        assert!(required_body(" \n ", "a comment").is_err());
    }

    #[test]
    fn graphql_write_errors_keep_their_useful_message() {
        let error = graphql_success(r#"{"errors":[{"message":"Already ready"}]}"#).unwrap_err();
        assert!(
            ForgeError::from(error)
                .to_string()
                .contains("Already ready")
        );
    }
}
