// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Work-search wire boundaries. Scope and authorization are server facts, not
//! request fields. Transcript search never uses the usage-counter archive.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

use crate::work_contracts::{WorkKind, WorkReference};

pub const MAX_QUERY_CHARACTERS: usize = 512;
pub const MAX_QUERY_BYTES: usize = 16 * 1024;
pub const MAX_REQUEST_BYTES: usize = 128 * 1024;
pub const MAX_PAGE_SIZE: u16 = 50;
pub const MAX_DISPLAYED: usize = 200;
pub const MAX_EXCERPT_CHARACTERS: usize = 240;

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub query: String,
    #[serde(default)]
    pub entity_kinds: Vec<WorkKind>,
    #[serde(default)]
    pub workspace_ids: Vec<String>,
    pub cursor: Option<String>,
    #[serde(default = "default_limit")]
    pub limit: u16,
}

fn default_limit() -> u16 {
    MAX_PAGE_SIZE
}

impl Request {
    /// Bound the encoded envelope before allocating its fields. Decoder errors
    /// are intentionally not forwarded: unknown keys may contain private text.
    pub fn parse(encoded: &str) -> Result<Self, &'static str> {
        if encoded.len() > MAX_REQUEST_BYTES {
            return Err("search request is too large");
        }
        let request: Self = serde_json::from_str(encoded).map_err(|_| "invalid search request")?;
        request.validate()?;
        Ok(request)
    }

    /// Reject, rather than silently truncate, an input that cannot be searched
    /// as entered. Grapheme counting agrees with the Apple client's String.
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.query.len() > MAX_QUERY_BYTES
            || self
                .query
                .graphemes(true)
                .take(MAX_QUERY_CHARACTERS + 1)
                .count()
                > MAX_QUERY_CHARACTERS
        {
            return Err("search query is too long");
        }
        if self.query.trim().is_empty() {
            return Err("enter words to search");
        }
        if !(1..=MAX_PAGE_SIZE).contains(&self.limit) {
            return Err("search page size must be between 1 and 50");
        }
        if self.entity_kinds.len() > 4
            || self.entity_kinds.contains(&WorkKind::Terminal)
            || self
                .entity_kinds
                .iter()
                .enumerate()
                .any(|(index, kind)| self.entity_kinds[..index].contains(kind))
        {
            return Err("invalid search entity kinds");
        }
        if self.workspace_ids.len() > 32
            || self.workspace_ids.iter().enumerate().any(|(index, id)| {
                id.is_empty()
                    || id.len() > 256
                    || id.chars().any(char::is_control)
                    || self.workspace_ids[..index].contains(id)
            })
        {
            return Err("invalid search workspace filter");
        }
        if self.cursor.as_ref().is_some_and(|cursor| {
            cursor.is_empty()
                || cursor.len() > 256
                || !cursor
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
        }) {
            return Err("invalid search cursor");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Hit {
    pub source: HitSource,
    pub reference: WorkReference,
    pub revision: String,
    pub title: String,
    pub folder_name: String,
    pub excerpt: String,
    pub highlights: Vec<Highlight>,
    pub score: u32,
    pub updated_at_ms: i64,
    pub partial: bool,
}

/// UTF-16 positions in the original excerpt, not in its normalized search key.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Highlight {
    pub location: usize,
    pub length: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Response {
    pub hits: Vec<Hit>,
    pub next_cursor: Option<String>,
    pub coverage: Coverage,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Coverage {
    /// Counts include only destinations permitted by the current host policy.
    pub searched: usize,
    pub unreadable: usize,
    pub partial: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(query: &str) -> Request {
        serde_json::from_value(serde_json::json!({"query": query})).unwrap()
    }

    #[test]
    fn parser_bounds_encoded_input_and_does_not_echo_private_fields() {
        let private = "private search words";
        for encoded in [
            format!(r#"{{"query":"work","{private}":true}}"#),
            format!(r#"{{"query":"work","entityKinds":["{private}"]}}"#),
            r#"{"query":"work","query":"second"}"#.to_string(),
            " ".repeat(MAX_REQUEST_BYTES + 1),
        ] {
            let error = Request::parse(&encoded).unwrap_err();
            assert!(!error.contains(private));
        }
        assert!(Request::parse(r#"{"query":"work","limit":51}"#).is_err());
        assert!(Request::parse(r#"{"query":"café 👩🏽‍💻","limit":50}"#).is_ok());
    }

    #[test]
    fn query_is_literal_and_bounds_use_visible_characters() {
        let literal = request(".* [x] OR café 👩🏽‍💻");
        assert!(literal.validate().is_ok());
        assert_eq!(literal.query, ".* [x] OR café 👩🏽‍💻");
        assert_eq!(literal.limit, 50);
        assert!(request(&"👩🏽‍💻".repeat(512)).validate().is_ok());
        assert!(request(&"e\u{301}".repeat(512)).validate().is_ok());
        assert!(request(&"a".repeat(513)).validate().is_err());
        assert!(
            request(&format!("a{}", "\u{301}".repeat(MAX_QUERY_BYTES)))
                .validate()
                .is_err()
        );
        assert!(request(" \n\t ").validate().is_err());
    }

    #[test]
    fn rejects_unsupported_filters_and_client_authority() {
        for value in [
            serde_json::json!({"query":"work", "scope":"another-account"}),
            serde_json::json!({"query":"work", "allowed":true}),
            serde_json::json!({"query":"work", "entityKinds":["execute"]}),
        ] {
            assert!(serde_json::from_value::<Request>(value).is_err());
        }
        for value in [
            serde_json::json!({"query":"work", "limit":0}),
            serde_json::json!({"query":"work", "limit":51}),
            serde_json::json!({"query":"work", "entityKinds":["terminal"]}),
            serde_json::json!({"query":"work", "entityKinds":["workspace","workspace"]}),
            serde_json::json!({"query":"work", "workspaceIds":["a","a"]}),
            serde_json::json!({"query":"work", "workspaceIds":[""]}),
            serde_json::json!({"query":"work", "cursor":"offset:50"}),
        ] {
            assert!(
                serde_json::from_value::<Request>(value)
                    .unwrap()
                    .validate()
                    .is_err()
            );
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HitSource {
    Live,
}
