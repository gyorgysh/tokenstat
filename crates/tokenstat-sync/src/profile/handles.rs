// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
//! Claiming a handle and publishing the profile page it names.
//!
//! The account service decides everything: which names are allowed, which are
//! taken, and how soon one may change. This file carries the question and hands
//! back the answer with its machine-readable reason intact, so a front end can
//! say it in its own words.

use serde_json::Value;

use super::{
    NOT_LOGGED_IN, ProfileError, TOKEN_REVOKED, http_client, limited_text, refusal_error,
    resolve_api_host,
};
use crate::keychain;

/// Whether a handle may be claimed right now, and why not when it may not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandleCheck {
    pub handle: String,
    pub available: bool,
    pub reason: Option<String>,
    pub message: String,
}

/// Ask whether this account could claim `handle`. Advice for a form, never the
/// decision: somebody else can take the name between the check and the claim.
pub fn check_handle(host_flag: Option<&str>, handle: &str) -> Result<HandleCheck, ProfileError> {
    let handle = handle.trim().to_lowercase();
    if handle.is_empty() {
        return Ok(HandleCheck {
            handle,
            available: false,
            reason: Some("too_short".into()),
            message: String::new(),
        });
    }
    let raw = request(host_flag, reqwest::Method::GET, &["handle", &handle], None)?;
    Ok(check_from_value(handle, &raw))
}

/// Claim `handle`, or change to it. The account's other devices see it on
/// their next status read.
pub fn claim_handle(host_flag: Option<&str>, handle: &str) -> Result<(), ProfileError> {
    request(
        host_flag,
        reqwest::Method::PUT,
        &["handle"],
        Some(serde_json::json!({ "handle": handle.trim() })),
    )
    .map(drop)
}

/// Answer the one-time offer with "not now", for every device on the account.
pub fn skip_handle_offer(host_flag: Option<&str>) -> Result<(), ProfileError> {
    request(
        host_flag,
        reqwest::Method::POST,
        &["handle", "skip"],
        Some(serde_json::json!({})),
    )
    .map(drop)
}

/// Publish or unpublish the profile page, and whether search engines may list
/// it. `None` leaves that setting alone.
pub fn set_profile_visibility(
    host_flag: Option<&str>,
    public: Option<bool>,
    indexable: Option<bool>,
) -> Result<(), ProfileError> {
    let mut body = serde_json::Map::new();
    if let Some(public) = public {
        body.insert("public".into(), public.into());
    }
    if let Some(indexable) = indexable {
        body.insert("indexable".into(), indexable.into());
    }
    request(
        host_flag,
        reqwest::Method::PUT,
        &["visibility"],
        Some(Value::Object(body)),
    )
    .map(drop)
}

fn request(
    host_flag: Option<&str>,
    method: reqwest::Method,
    path: &[&str],
    body: Option<Value>,
) -> Result<Value, ProfileError> {
    let host = resolve_api_host(host_flag)?;
    let token =
        keychain::load_token(&host)?.ok_or_else(|| ProfileError::Message(NOT_LOGGED_IN.into()))?;
    let client = http_client()?;
    let mut req = client
        .request(method, route(&host, path)?)
        .header("authorization", format!("Bearer {token}"));
    if let Some(body) = body {
        req = req.json(&body);
    }
    let resp = req.send()?;
    let status = resp.status();
    let text = limited_text(resp)?;
    decode(status, &text)
}

/// The path is built from segments so a handle somebody is still typing can
/// hold a slash or a question mark without reaching another route.
fn route(host: &str, path: &[&str]) -> Result<reqwest::Url, ProfileError> {
    let invalid = || ProfileError::Message("the account host is not a valid address".into());
    let mut url = reqwest::Url::parse(host).map_err(|_| invalid())?;
    url.path_segments_mut()
        .map_err(|()| invalid())?
        .pop_if_empty()
        .extend(["api", "v1", "account"])
        .extend(path);
    Ok(url)
}

fn decode(status: reqwest::StatusCode, text: &str) -> Result<Value, ProfileError> {
    if status.is_success() {
        return Ok(serde_json::from_str(text)?);
    }
    let body: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let field = |name: &str| {
        body.get(name)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    match status.as_u16() {
        401 => Err(ProfileError::Message(TOKEN_REVOKED.into())),
        404 | 405 => Err(ProfileError::Unsupported(
            "this account service does not support handles in the app yet".into(),
        )),
        403 if field("error").is_none_or(|code| code == "forbidden") => {
            Err(refusal_error(text, 403))
        }
        code => match field("error") {
            Some(reason) => Err(ProfileError::ProfileRefused {
                code: reason.to_string(),
                message: field("message").unwrap_or(reason).to_string(),
            }),
            None => Err(ProfileError::Message(format!(
                "the account service could not do that ({code})"
            ))),
        },
    }
}

fn check_from_value(asked: String, raw: &Value) -> HandleCheck {
    let text = |name: &str| raw.get(name).and_then(Value::as_str).map(str::to_string);
    HandleCheck {
        handle: text("handle").unwrap_or(asked),
        available: raw
            .get("available")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        reason: text("reason"),
        message: text("message").unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::StatusCode;

    #[test]
    fn a_handle_being_typed_cannot_reach_another_route() {
        for (typed, expected) in [
            ("gyorgy", "/api/v1/account/handle/gyorgy"),
            ("a/../skip", "/api/v1/account/handle/a%2F..%2Fskip"),
            ("a?b#c", "/api/v1/account/handle/a%3Fb%23c"),
        ] {
            let url = route("https://example.invalid", &["handle", typed]).unwrap();
            assert_eq!(url.path(), expected);
            assert_eq!((url.query(), url.fragment()), (None, None));
        }
        let nested = route("https://example.invalid/service/", &["visibility"]).unwrap();
        assert_eq!(nested.path(), "/service/api/v1/account/visibility");
    }

    #[test]
    fn a_refusal_keeps_its_reason_and_a_server_without_the_route_says_so() {
        let refused = decode(
            StatusCode::CONFLICT,
            r#"{"error":"taken","message":"Already taken."}"#,
        );
        assert!(matches!(
            refused,
            Err(ProfileError::ProfileRefused { code, message })
                if code == "taken" && message == "Already taken."
        ));
        let cooloff = decode(
            StatusCode::FORBIDDEN,
            r#"{"error":"cooloff","message":"You can change your handle again in 3 days."}"#,
        );
        assert!(
            matches!(cooloff, Err(ProfileError::ProfileRefused { code, .. }) if code == "cooloff")
        );
        let scope = decode(
            StatusCode::FORBIDDEN,
            r#"{"error":"forbidden","message":"Token lacks sync:write."}"#,
        );
        assert!(matches!(scope, Err(ProfileError::Message(m)) if m.contains("sync:write")));
        assert!(matches!(
            decode(StatusCode::NOT_FOUND, "<html>"),
            Err(ProfileError::Unsupported(_))
        ));
        assert!(
            decode(StatusCode::UNAUTHORIZED, "")
                .unwrap_err()
                .is_unauthenticated()
        );
    }

    #[test]
    fn an_answer_that_does_not_say_available_is_not_a_yes() {
        let missing = check_from_value("name".into(), &serde_json::json!({}));
        assert_eq!(
            (missing.available, missing.handle.as_str()),
            (false, "name")
        );
        let free = check_from_value(
            "name".into(),
            &serde_json::json!({"handle":"name","available":true,"reason":null,"message":"Available."}),
        );
        assert!(free.available && free.reason.is_none());
    }

    #[test]
    fn an_empty_handle_never_leaves_the_device() {
        let check = check_handle(Some("https://example.invalid"), "  ").unwrap();
        assert_eq!(check.reason.as_deref(), Some("too_short"));
    }
}
