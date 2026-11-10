// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Mounted chat read identities. Keys preserve raw parameter spellings, while
//! host/account domains and concurrent flight ownership live in flights.rs.

use super::{
    Conversation,
    wire::{EventChunk, EventPage},
};
use serde_json::{Value, json};
use std::sync::Arc;
#[cfg(test)]
mod tests;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Query {
    Directory {
        workspace: String,
    },
    Events {
        id: String,
        offset: u64,
        tail_cursor: Option<String>,
    },
    Page {
        id: String,
        cursor: Option<String>,
        limit: usize,
        include_usage: bool,
    },
}
#[derive(Clone, Debug)]
pub enum Reply {
    Directory(Arc<Vec<Conversation>>),
    Events(Arc<EventChunk>),
    Page(Arc<EventPage>),
}
impl Query {
    pub fn directory(folder: &str) -> Self {
        Self::Directory {
            workspace: crate::work::destination::route(folder, None).workspace_id,
        }
    }
    pub fn method(&self) -> &'static str {
        match self {
            Self::Directory { .. } => "chat.list",
            Self::Events { .. } => "chat.events",
            Self::Page { .. } => "chat.eventPage",
        }
    }
    pub fn parameters(&self) -> Value {
        match self {
            Self::Directory { workspace } => json!({"workspaceId":workspace}),
            Self::Events {
                id,
                offset,
                tail_cursor,
            } => {
                let mut v = json!({"id":id,"offset":offset,"stablePositions":true});
                if let Some(cursor) = tail_cursor {
                    v["tailCursor"] = json!(cursor);
                }
                v
            }
            Self::Page {
                id,
                cursor,
                limit,
                include_usage,
            } => {
                let mut v = json!({"id":id,"limit":limit,"stablePositions":true});
                if let Some(cursor) = cursor {
                    v["cursor"] = json!(cursor);
                }
                if !include_usage {
                    v["includeUsage"] = json!(false);
                }
                v
            }
        }
    }
    fn decode(&self, value: Value) -> anyhow::Result<Reply> {
        Ok(match self {
            Self::Directory { .. } => Reply::Directory(Arc::new(serde_json::from_value(value)?)),
            Self::Events { .. } => Reply::Events(Arc::new(serde_json::from_value(value)?)),
            Self::Page { .. } => Reply::Page(Arc::new(serde_json::from_value(value)?)),
        })
    }
}
impl super::paging::Read {
    pub fn query(&self) -> Query {
        match self.kind {
            super::paging::ReadKind::Newest | super::paging::ReadKind::Earlier => Query::Page {
                id: self.id.clone(),
                cursor: self.cursor.clone(),
                limit: if self.kind == super::paging::ReadKind::Newest {
                    super::wire::OPEN_PAGE_EVENTS
                } else {
                    super::wire::PAGE_EVENTS
                },
                include_usage: true,
            },
            super::paging::ReadKind::Whole | super::paging::ReadKind::Tail => Query::Events {
                id: self.id.clone(),
                offset: self.offset,
                tail_cursor: self.cursor.clone(),
            },
        }
    }
}
#[cfg(unix)]
impl crate::client::Client {
    pub fn chat_read_if_current(
        &self,
        folder: &str,
        query: &Query,
        current: impl Fn() -> bool,
    ) -> anyhow::Result<Reply> {
        anyhow::ensure!(current(), "Chat read was retired");
        self.prepare()?;
        anyhow::ensure!(current(), "Chat read was retired");
        let route = crate::work::destination::route(folder, None);
        let timeout = std::time::Duration::from_secs(super::DIRECTORY_TIMEOUT_SECS);
        let value = match route.peer {
            Some(peer) => self.call_with_timeout(
                "remote.call",
                json!({"peer":peer,"method":query.method(),"params":query.parameters()}),
                timeout,
            )?,
            None => self.call_with_timeout(query.method(), query.parameters(), timeout)?,
        };
        anyhow::ensure!(current(), "Chat read was retired");
        query.decode(value)
    }
}
impl super::paging::Failure {
    pub fn from_error(error: &anyhow::Error) -> Self {
        let remote = error.downcast_ref::<tokenstat_core::host_rpc::ExchangeError>();
        let (message, unknown_method) = match remote {
            Some(tokenstat_core::host_rpc::ExchangeError::Remote { code, message, .. }) => (
                message.clone(),
                code.as_deref() == Some("unknown_method") || message.starts_with("unknown "),
            ),
            _ => (format!("{error:#}"), false),
        };
        Self {
            message,
            unknown_method,
        }
    }
}
