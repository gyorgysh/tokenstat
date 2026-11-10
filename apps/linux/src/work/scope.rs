// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Scope origin handling retains URLComponents path semantics. A browser URL
//! parser would collapse dot segments and numeric hosts, changing store keys.

use super::{Scope, ScopeKind, text};

impl Scope {
    /// The claimed handle takes precedence over a server id, including before
    /// the account has chosen a human-readable handle.
    pub fn account_identity<'a>(handle: Option<&'a str>, id: Option<&'a str>) -> Option<&'a str> {
        [handle, id]
            .into_iter()
            .flatten()
            .map(text::trim)
            .find(|s| !s.is_empty())
    }
    /// Canonicalize the account origin without interpreting it as navigation.
    pub fn account(origin: &str, identity: &str) -> Option<Self> {
        if identity.is_empty() {
            return None;
        }
        Some(Self {
            kind: ScopeKind::Account,
            origin: canonical_origin(origin)?,
            identity: identity.into(),
        })
    }
    /// Signed-out work is filed under a device-local installation identifier.
    pub fn local(installation_id: impl Into<String>) -> Self {
        Self {
            kind: ScopeKind::Local,
            origin: String::new(),
            identity: installation_id.into(),
        }
    }
    /// Pin stores accept account scopes only in their canonical shape.
    pub fn valid_for_pins(&self) -> bool {
        match self.kind {
            ScopeKind::Local => !self.identity.is_empty(),
            ScopeKind::Account => Self::account(&self.origin, &self.identity)
                .is_some_and(|s| text::equal(&s.origin, &self.origin)),
        }
    }
    /// Keep the source's device-local preference key vocabulary.
    pub fn storage_key(&self) -> String {
        [
            match self.kind {
                ScopeKind::Account => "account",
                ScopeKind::Local => "local",
            },
            &self.origin,
            &self.identity,
        ]
        .map(text::encode)
        .join("|")
    }
}

fn canonical_origin(origin: &str) -> Option<String> {
    let (scheme, rest) = origin.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    if !matches!(scheme.as_str(), "http" | "https") {
        return None;
    }
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    if authority.is_empty() || authority.contains('@') {
        return None;
    }
    let (host, port) = if authority.starts_with('[') {
        let end = authority.find(']')?;
        let tail = &authority[end + 1..];
        (
            &authority[..=end],
            if tail.is_empty() {
                None
            } else {
                Some(tail.strip_prefix(':')?)
            },
        )
    } else {
        authority
            .rsplit_once(':')
            .map_or((authority, None), |(host, port)| (host, Some(port)))
    };
    let host = String::from_utf8(decode(host)?).ok()?.to_lowercase();
    if host.is_empty()
        || host.chars().any(|c| {
            c.is_whitespace() || c.is_control() || matches!(c, '/' | '\\' | '@' | '?' | '#')
        })
    {
        return None;
    }
    let host = if host.starts_with('[') && host.ends_with(']') {
        host.replace('%', "%25")
    } else {
        if host.contains([':', '%', '[', ']']) {
            return None;
        }
        idna::domain_to_ascii(&host).ok()?
    };
    if host.is_empty() {
        return None;
    }
    let port = match port {
        None | Some("") => String::new(),
        Some(value) => {
            if !value.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let number = value.trim_start_matches('0');
            let number = if number.is_empty() { "0" } else { number };
            if (scheme == "https" && number == "443") || (scheme == "http" && number == "80") {
                String::new()
            } else {
                format!(":{number}")
            }
        }
    };
    let path = rest[end..].split(['?', '#']).next().unwrap_or_default();
    let preserve = decode(path).is_some();
    let mut path = encode_path(path, preserve);
    // Invalid UTF-8 escapes leave URLComponents.path empty, so its suffix loop
    // never rewrites the original percent-encoded path.
    if let Some(decoded) = decode(&path).and_then(|v| String::from_utf8(v).ok())
        && decoded.ends_with('/')
    {
        path = encode_path(decoded.trim_end_matches('/'), false);
    }
    Some(format!("{scheme}://{host}{port}{path}"))
}

fn decode(value: &str) -> Option<Vec<u8>> {
    let bytes = value.as_bytes();
    let mut out = vec![];
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' {
            let a = (*bytes.get(at + 1)? as char).to_digit(16)?;
            let b = (*bytes.get(at + 2)? as char).to_digit(16)?;
            out.push((a * 16 + b) as u8);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    Some(out)
}
fn encode_path(value: &str, preserve_percent: bool) -> String {
    let mut result = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric()
            || b"-._~!$&'()*+,;=:@/".contains(&byte)
            || (preserve_percent && byte == b'%')
        {
            result.push(byte as char);
        } else {
            result.push_str(&format!("%{byte:02X}"));
        }
    }
    result
}
