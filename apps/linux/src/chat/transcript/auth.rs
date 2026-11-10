// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Original sign-in refusal presentation; persisted raw rows remain intact.

use super::{Kind, Row, has_prefix};
use crate::{drafts::Attachment, work::text};
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recovery {
    #[serde(rename = "failureID")]
    pub failure_id: String,
    pub text: String,
    pub attachments: Vec<Attachment>,
}
pub fn latest_recovery(items: &[Row], backend: &str) -> Option<Recovery> {
    let start = items
        .iter()
        .rposition(|r| matches!(r.kind, Kind::User { .. }))?;
    let turn = presented(&items[start..]);
    let Kind::User { text } = &turn[0].kind else {
        return None;
    };
    let failure = turn
        .iter()
        .skip(1)
        .rev()
        .find(|r| matches!(&r.kind,Kind::Failed{text} if needs_sign_in(text,backend)))?;
    let attachments = turn
        .iter()
        .skip(1)
        .map_while(|r| match &r.kind {
            Kind::Attachment { file } => Some(file.clone()),
            _ => None,
        })
        .collect();
    Some(Recovery {
        failure_id: failure.id.clone(),
        text: text.clone(),
        attachments,
    })
}
pub fn needs_sign_in(text: &str, backend: &str) -> bool {
    match backend {
        "claude" | "claude_code" => is_claude_refusal(text),
        "cursor" | "cursor_agent" => {
            let lower = text::trim(text).to_lowercase();
            if has_prefix(&lower, "cursor is not signed in on this machine.") {
                return true;
            }
            let lower = if has_prefix(&lower, "error:") {
                text::trim(&lower[6..])
            } else {
                &lower
            };
            has_prefix(lower, "authentication required.")
                && lower.contains("cursor_api_key")
                && [
                    "'agent login'",
                    "'cursor-agent login'",
                    "'cursor agent login'",
                ]
                .iter()
                .any(|v| lower.contains(v))
        }
        "muse" => has_prefix(
            &text.to_lowercase(),
            "muse is not signed in on this machine.",
        ),
        _ => false,
    }
}
pub fn is_claude_refusal(text: &str) -> bool {
    let lower = text.to_lowercase();
    has_prefix(&lower, "claude code is not signed in")
        || has_prefix(&lower, "claude code's sign-in on this computer has expired")
}
const MUSE_REFUSAL: &str =
    "Muse is not signed in on this machine. Open a terminal and run muse login.";
fn legacy_muse_challenge(text: &str, backend: Option<&str>) -> bool {
    if backend != Some("muse") {
        return false;
    }
    let text = text::trim(text);
    let heading = "Open this page to sign in:";
    if !has_prefix(text, heading) || !text.ends_with("Press Enter to open it in your browser:") {
        return false;
    }
    let Some(confirm) = text
        .find("confirm this code matches:")
        .or_else(|| text.find("Confirm this code matches:"))
    else {
        return false;
    };
    if confirm < heading.len() {
        return false;
    }
    let url = text::trim(&text[heading.len()..confirm]);
    foundation_auth_url(url)
}
/// This presentation guard needs only the original exact https scheme/host.
/// Percent-encoded host characters are decoded like URLComponents.host. No URL
/// is opened and this is never used to authorize transport or a sign-in flow.
fn foundation_auth_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host_port = authority.rsplit('@').next().unwrap_or_default();
    let mut parts = host_port.split(':');
    let host = parts.next().unwrap_or_default();
    if let Some(port) = parts.next()
        && (!port.is_empty() && !port.bytes().all(|b| b.is_ascii_digit()) || parts.next().is_some())
    {
        return false;
    }
    let mut decoded = vec![];
    let mut bytes = host.as_bytes().iter().copied();
    while let Some(b) = bytes.next() {
        if b == b'%' {
            let Some(a) = bytes.next().and_then(|c| (c as char).to_digit(16)) else {
                return false;
            };
            let Some(b) = bytes.next().and_then(|c| (c as char).to_digit(16)) else {
                return false;
            };
            decoded.push((a * 16 + b) as u8);
        } else {
            decoded.push(b);
        }
    }
    decoded == b"auth.meta.com"
}
pub fn presented(items: &[Row]) -> Vec<Row> {
    let mut output = vec![];
    let mut turn = vec![];
    let flush = |turn: &mut Vec<Row>, output: &mut Vec<Row>| {
        for item in turn.iter_mut() {
            if let Kind::Assistant { text, backend } = &item.kind
                && legacy_muse_challenge(text, backend.as_deref())
            {
                let mut next = Row::new(
                    &item.id,
                    Kind::Failed {
                        text: MUSE_REFUSAL.into(),
                    },
                );
                next.last_sequence = item.last_sequence;
                next.group_id = item.group_id.clone();
                next.plain_step = item.plain_step;
                *item = next;
            }
        }
        let refused = turn
            .iter()
            .any(|r| matches!(&r.kind,Kind::Failed{text} if is_claude_refusal(text)));
        output.extend(turn.drain(..).filter(|r| {
            if !refused {
                return true;
            }
            match &r.kind {
                Kind::Assistant { text, backend } => {
                    !(matches!(backend.as_deref(), None | Some("claude" | "claude_code"))
                        && matches!(
                            text::trim(text).to_lowercase().as_str(),
                            "not logged in · please run /login"
                                | "not logged in. please run /login"
                                | "not logged in · please run /login."
                        ))
                }
                Kind::Usage {
                    input,
                    output,
                    cost,
                } => *input != 0 || *output != 0 || cost.unwrap_or_default() != 0.,
                _ => true,
            }
        }));
    };
    for item in items {
        if matches!(item.kind, Kind::User { .. }) {
            flush(&mut turn, &mut output);
        }
        turn.push(item.clone());
    }
    flush(&mut turn, &mut output);
    output
}
