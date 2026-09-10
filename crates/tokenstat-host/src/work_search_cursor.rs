// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Bounded, process-local continuation state. Tokens contain no query text or
//! account identifiers. The host must recheck access before using an offset.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::work_contracts::WorkScope;
use crate::work_search::{MAX_DISPLAYED, Request};

const CAPACITY: usize = 128;
const LIFETIME: Duration = Duration::from_secs(5 * 60);

/// Created from the authenticated transport and current authorized index,
/// never decoded from a search request.
#[derive(Clone, PartialEq, Eq)]
pub struct Context {
    pub scope: WorkScope,
    pub requester: String,
    pub generation: u64,
}

struct Entry {
    token: String,
    request: Request,
    context: Context,
    offset: usize,
    created: Instant,
}

#[derive(Default)]
pub struct Cursors {
    entries: VecDeque<Entry>,
}

impl Cursors {
    pub fn issue(
        &mut self,
        request: &Request,
        context: &Context,
        offset: usize,
        now: Instant,
    ) -> Result<String, &'static str> {
        request.validate()?;
        if offset == 0 || offset >= MAX_DISPLAYED {
            return Err("invalid search continuation");
        }
        let mut random = [0_u8; 32];
        getrandom::fill(&mut random).map_err(|_| "search continuation is unavailable")?;
        let token: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        self.expire(now);
        while self.entries.len() >= CAPACITY {
            self.entries.pop_front();
        }
        let mut bound = request.clone();
        bound.cursor = None;
        self.entries.push_back(Entry {
            token: token.clone(),
            request: bound,
            context: context.clone(),
            offset,
            created: now,
        });
        Ok(token)
    }

    /// Retain valid entries for exact retries. A lost response should not
    /// consume the only way to continue the same authorized snapshot.
    pub fn resume(
        &mut self,
        request: &Request,
        context: &Context,
        now: Instant,
    ) -> Result<usize, &'static str> {
        request.validate()?;
        self.expire(now);
        let token = request
            .cursor
            .as_deref()
            .ok_or("missing search continuation")?;
        let mut bound = request.clone();
        bound.cursor = None;
        self.entries
            .iter()
            .find(|entry| {
                entry.token == token && entry.request == bound && entry.context == *context
            })
            .map(|entry| entry.offset)
            .ok_or("search continuation expired or changed")
    }

    pub fn revoke(&mut self, scope: &WorkScope, requester: &str) {
        self.entries
            .retain(|entry| entry.context.scope != *scope || entry.context.requester != requester);
    }

    fn expire(&mut self, now: Instant) {
        self.entries
            .retain(|entry| now.saturating_duration_since(entry.created) < LIFETIME);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::work_contracts::ScopeKind;

    fn context() -> Context {
        Context {
            scope: WorkScope {
                kind: ScopeKind::Account,
                origin: "https://example.invalid".into(),
                identity: "alice".into(),
            },
            requester: "peer-a".into(),
            generation: 4,
        }
    }

    #[test]
    fn continuation_is_bound_to_request_owner_and_generation() {
        let mut cursors = Cursors::default();
        let now = Instant::now();
        let context = context();
        let mut request = Request::parse(r#"{"query":"private words"}"#).unwrap();
        let token = cursors.issue(&request, &context, 50, now).unwrap();
        assert_eq!(token.len(), 64);
        assert!(!token.contains("private"));
        request.cursor = Some(token);
        assert_eq!(cursors.resume(&request, &context, now).unwrap(), 50);
        assert_eq!(cursors.resume(&request, &context, now).unwrap(), 50);
        let mut changed = request.clone();
        changed.query = "other words".into();
        assert!(cursors.resume(&changed, &context, now).is_err());
        changed = request.clone();
        changed.workspace_ids = vec!["folder".into()];
        assert!(cursors.resume(&changed, &context, now).is_err());
        for changed in [
            Context {
                requester: "peer-b".into(),
                ..context.clone()
            },
            Context {
                generation: 5,
                ..context.clone()
            },
            Context {
                scope: WorkScope {
                    identity: "bob".into(),
                    ..context.scope.clone()
                },
                ..context.clone()
            },
        ] {
            assert!(cursors.resume(&request, &changed, now).is_err());
        }
        cursors.revoke(&context.scope, &context.requester);
        assert!(cursors.resume(&request, &context, now).is_err());
    }

    #[test]
    fn expiry_capacity_and_display_limit_are_bounded() {
        let mut cursors = Cursors::default();
        let now = Instant::now();
        let context = context();
        let mut request = Request::parse(r#"{"query":"work"}"#).unwrap();
        request.cursor = Some(cursors.issue(&request, &context, 50, now).unwrap());
        assert!(cursors.resume(&request, &context, now + LIFETIME).is_err());
        assert!(cursors.issue(&request, &context, 0, now).is_err());
        assert!(cursors.issue(&request, &context, 200, now).is_err());
        let oldest = cursors.issue(&request, &context, 50, now).unwrap();
        for _ in 0..CAPACITY {
            cursors.issue(&request, &context, 50, now).unwrap();
        }
        assert_eq!(cursors.entries.len(), CAPACITY);
        request.cursor = Some(oldest);
        assert!(cursors.resume(&request, &context, now).is_err());
    }
}
