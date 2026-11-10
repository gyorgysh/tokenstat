// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Complete Swift reader wire records. Unknown event kinds are retained; an
//! unreadable individual event is skipped without emptying the rest of a page.

use serde::{Deserialize, Deserializer, Serialize, de::DeserializeOwned};
use serde_json::Value;
#[cfg(test)]
mod tests;

pub const OPEN_PAGE_EVENTS: usize = 1500;
pub const PAGE_EVENTS: usize = 1200;
pub const PREVIEW_PAGE_EVENTS: usize = 500;
pub const HOST_PAGE_EVENTS_MAX: usize = 2000;

pub(super) fn tolerant<'de, D: Deserializer<'de>, T: DeserializeOwned>(
    d: D,
) -> Result<Option<T>, D::Error> {
    Ok(serde_json::from_value(Value::deserialize(d)?).ok())
}

/// JSONDecoder accepts integral floating-point spellings for integer fields.
/// Usage counters alone also accept positive fractional values by truncating.
pub(crate) mod number {
    use super::*;
    fn unsigned(v: &Value) -> Option<u64> {
        v.as_u64().or_else(|| {
            v.as_f64()
                .filter(|f| {
                    f.is_finite() && *f >= 0. && *f < 18446744073709551616. && f.fract() == 0.
                })
                .map(|f| f as u64)
        })
    }
    fn signed(v: &Value) -> Option<i64> {
        v.as_i64().or_else(|| {
            v.as_f64()
                .filter(|f| {
                    f.is_finite()
                        && *f >= -9223372036854775808.
                        && *f < 9223372036854775808.
                        && f.fract() == 0.
                })
                .map(|f| f as i64)
        })
    }
    pub fn u64_optional<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
        let v = Value::deserialize(d)?;
        if v.is_null() {
            return Ok(None);
        }
        unsigned(&v)
            .map(Some)
            .ok_or_else(|| serde::de::Error::custom("expected an unsigned 64-bit integer"))
    }
    pub fn i64_optional<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
        let v = Value::deserialize(d)?;
        if v.is_null() {
            return Ok(None);
        }
        signed(&v)
            .map(Some)
            .ok_or_else(|| serde::de::Error::custom("expected a signed 64-bit integer"))
    }
    pub fn u64_required<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
        u64_optional(d)?.ok_or_else(|| serde::de::Error::custom("missing unsigned integer"))
    }
    pub fn i64_required<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
        i64_optional(d)?.ok_or_else(|| serde::de::Error::custom("missing signed integer"))
    }
    pub fn u32_optional<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u32>, D::Error> {
        u64_optional(d)?
            .map(|v| u32::try_from(v).map_err(serde::de::Error::custom))
            .transpose()
    }
    pub fn u32_required<'de, D: Deserializer<'de>>(d: D) -> Result<u32, D::Error> {
        u32_optional(d)?.ok_or_else(|| serde::de::Error::custom("missing unsigned integer"))
    }
    pub fn i32_optional<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i32>, D::Error> {
        i64_optional(d)?
            .map(|v| i32::try_from(v).map_err(serde::de::Error::custom))
            .transpose()
    }
    pub fn u64_default<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
        Ok(u64_optional(d)?.unwrap_or_default())
    }
    pub fn i64_default<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
        Ok(i64_optional(d)?.unwrap_or_default())
    }
    pub fn count<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
        let v = Value::deserialize(d)?;
        Ok(unsigned(&v).or_else(|| {
            v.as_f64()
                .filter(|f| f.is_finite() && *f >= 0. && *f < 18446744073709551616.)
                .map(|f| f as u64)
        }))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RouteDestination {
    pub backend: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RoutingPolicy {
    #[serde(default, deserialize_with = "super::null_default")]
    pub enabled: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub routes: Vec<RouteDestination>,
    #[serde(default, deserialize_with = "super::null_default")]
    pub wait_for_reset: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub return_preferred: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub use_as_default: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub failover_on_throttle: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub failover_on_errors: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub failover_on_auth: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub failover_on_failures: bool,
    pub notify: Option<bool>,
    pub preferred: Option<RouteDestination>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderLimit {
    pub provider: String,
    pub kind: String,
    pub reason: String,
    #[serde(default, deserialize_with = "number::i64_optional")]
    pub resets_at_ms: Option<i64>,
    #[serde(deserialize_with = "number::i64_required")]
    pub observed_at_ms: i64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingActivity {
    pub id: Option<String>,
    #[serde(deserialize_with = "number::i64_required")]
    pub at_ms: i64,
    pub kind: String,
    pub source: Option<RouteDestination>,
    pub target: Option<RouteDestination>,
    pub reason: String,
    #[serde(default, deserialize_with = "number::i64_optional")]
    pub resets_at_ms: Option<i64>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingReset {
    pub destination: RouteDestination,
    #[serde(deserialize_with = "number::i64_required")]
    pub at_ms: i64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RoutingState {
    pub policy: RoutingPolicy,
    pub limit: Option<ProviderLimit>,
    pub waiting: bool,
    pub needs_delivery_check: bool,
    pub note: Option<String>,
    pub tried: Vec<RouteDestination>,
    pub preferred: Option<RouteDestination>,
    pub activity: Option<Vec<RoutingActivity>>,
    pub next_reset: Option<RoutingReset>,
}

/// A shared transcript approval deliberately ignores private conversationId.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Approval {
    pub id: String,
    #[serde(rename = "conversationId")]
    pub conversation_id: String,
    pub verb: String,
    pub preview: String,
    pub shell_prefix: Option<String>,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub decision: Option<String>,
    pub read_only: bool,
}
impl<'de> Deserialize<'de> for Approval {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            id: String,
            #[serde(rename = "conversationId")]
            conversation_id: Option<Value>,
            verb: String,
            preview: String,
            shell_prefix: Option<String>,
            #[serde(deserialize_with = "number::i64_required")]
            created_at_ms: i64,
            #[serde(deserialize_with = "number::i64_required")]
            expires_at_ms: i64,
            decision: Option<String>,
            #[serde(default, deserialize_with = "super::null_default")]
            read_only: bool,
        }
        let f = Fields::deserialize(d)?;
        let conversation_id = if f.read_only {
            String::new()
        } else {
            f.conversation_id
                .and_then(|v| v.as_str().map(str::to_owned))
                .ok_or_else(|| {
                    serde::de::Error::custom("missing private approval conversationId")
                })?
        };
        Ok(Self {
            id: f.id,
            conversation_id,
            verb: f.verb,
            preview: f.preview,
            shell_prefix: f.shell_prefix,
            created_at_ms: f.created_at_ms,
            expires_at_ms: f.expires_at_ms,
            decision: f.decision,
            read_only: f.read_only,
        })
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentEvent {
    pub kind: String,
    pub delta: Option<String>,
    pub verb: Option<String>,
    pub target: Option<String>,
    pub path: Option<String>,
    pub added: Option<u32>,
    pub removed: Option<u32>,
    pub patch: Option<String>,
    pub status: Option<String>,
    pub text: Option<String>,
    pub input: Option<u64>,
    pub output: Option<u64>,
    pub cost_usd: Option<f64>,
    pub call_id: Option<String>,
    pub ok: Option<bool>,
    pub detail: Option<String>,
    pub cache_read: Option<u64>,
    pub cache_write: Option<u64>,
    pub exit_code: Option<i32>,
    pub id: Option<String>,
    pub name: Option<String>,
    pub media_type: Option<String>,
    pub size: Option<u64>,
}
impl<'de> Deserialize<'de> for AgentEvent {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            kind: String,
            delta: Option<String>,
            verb: Option<String>,
            target: Option<String>,
            path: Option<String>,
            #[serde(default, deserialize_with = "number::u32_optional")]
            added: Option<u32>,
            #[serde(default, deserialize_with = "number::u32_optional")]
            removed: Option<u32>,
            patch: Option<String>,
            status: Option<String>,
            text: Option<String>,
            #[serde(default, deserialize_with = "number::count")]
            input: Option<u64>,
            #[serde(default, deserialize_with = "number::count")]
            output: Option<u64>,
            cost_usd: Option<f64>,
            call_id: Option<String>,
            ok: Option<bool>,
            detail: Option<String>,
            #[serde(default, deserialize_with = "number::count")]
            cache_read: Option<u64>,
            #[serde(default, deserialize_with = "number::count")]
            cache_write: Option<u64>,
            #[serde(default, deserialize_with = "number::i32_optional")]
            exit_code: Option<i32>,
            id: Option<String>,
            name: Option<String>,
            media_type: Option<String>,
            #[serde(default, deserialize_with = "number::count")]
            size: Option<u64>,
            #[serde(rename = "cost_usd")]
            cost_legacy: Option<f64>,
            #[serde(rename = "call_id")]
            call_legacy: Option<String>,
            #[serde(default, rename = "cache_read", deserialize_with = "number::count")]
            read_legacy: Option<u64>,
            #[serde(default, rename = "cache_write", deserialize_with = "number::count")]
            write_legacy: Option<u64>,
            #[serde(
                default,
                rename = "exit_code",
                deserialize_with = "number::i32_optional"
            )]
            exit_legacy: Option<i32>,
        }
        // Legacy values are decoded lazily in Swift's ?? expressions. Remove
        // them only when a non-null primary value decoded successfully (counts
        // have their deliberately tolerant, independent fallback).
        let mut v = Value::deserialize(d)?;
        for (primary, legacy) in [
            ("costUsd", "cost_usd"),
            ("callId", "call_id"),
            ("exitCode", "exit_code"),
        ] {
            if v.get(primary).is_some_and(|x| !x.is_null())
                && let Some(object) = v.as_object_mut()
            {
                object.remove(legacy);
            }
        }
        let f: Fields = serde_json::from_value(v).map_err(serde::de::Error::custom)?;
        Ok(Self {
            kind: f.kind,
            delta: f.delta,
            verb: f.verb,
            target: f.target,
            path: f.path,
            added: f.added,
            removed: f.removed,
            patch: f.patch,
            status: f.status,
            text: f.text,
            input: f.input,
            output: f.output,
            cost_usd: f.cost_usd.or(f.cost_legacy),
            call_id: f.call_id.or(f.call_legacy),
            ok: f.ok,
            detail: f.detail,
            cache_read: f.cache_read.or(f.read_legacy),
            cache_write: f.cache_write.or(f.write_legacy),
            exit_code: f.exit_code.or(f.exit_legacy),
            id: f.id,
            name: f.name,
            media_type: f.media_type,
            size: f.size,
        })
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TimelineEvent {
    pub kind: String,
    pub text: Option<String>,
    pub steer: Option<bool>,
    pub seq: Option<u64>,
    pub at_ms: Option<i64>,
    pub backend: Option<String>,
    pub event: Option<AgentEvent>,
    pub approval: Option<Approval>,
    pub to: Option<String>,
    pub brief: Option<String>,
    #[serde(rename = "id")]
    pub record_id: Option<String>,
    pub question: Option<String>,
    pub options: Option<Vec<String>>,
    pub multiple: Option<bool>,
    #[serde(rename = "default")]
    pub default_answer: Option<String>,
    pub blocking: Option<bool>,
    #[serde(rename = "questionId")]
    pub question_id: Option<String>,
    pub delivery: Option<String>,
}
impl<'de> Deserialize<'de> for TimelineEvent {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            kind: String,
            text: Option<String>,
            steer: Option<bool>,
            #[serde(default, deserialize_with = "number::u64_optional")]
            seq: Option<u64>,
            #[serde(default, deserialize_with = "number::i64_optional")]
            at_ms: Option<i64>,
            #[serde(default, rename = "at_ms", deserialize_with = "number::i64_optional")]
            at_legacy: Option<i64>,
            backend: Option<String>,
            event: Option<AgentEvent>,
            approval: Option<Approval>,
            to: Option<String>,
            brief: Option<String>,
            #[serde(rename = "id")]
            record_id: Option<String>,
            question: Option<String>,
            options: Option<Vec<String>>,
            multiple: Option<bool>,
            #[serde(rename = "default")]
            default_answer: Option<String>,
            blocking: Option<bool>,
            #[serde(rename = "questionId")]
            question_id: Option<String>,
            delivery: Option<String>,
        }
        let mut v = Value::deserialize(d)?;
        if v.get("atMs").is_some_and(|x| !x.is_null())
            && let Some(object) = v.as_object_mut()
        {
            object.remove("at_ms");
        }
        let f: Fields = serde_json::from_value(v).map_err(serde::de::Error::custom)?;
        Ok(Self {
            kind: f.kind,
            text: f.text,
            steer: f.steer,
            seq: f.seq,
            at_ms: f.at_ms.or(f.at_legacy),
            backend: f.backend,
            event: f.event,
            approval: f.approval,
            to: f.to,
            brief: f.brief,
            record_id: f.record_id,
            question: f.question,
            options: f.options,
            multiple: f.multiple,
            default_answer: f.default_answer,
            blocking: f.blocking,
            question_id: f.question_id,
            delivery: f.delivery,
        })
    }
}
fn events<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<TimelineEvent>, D::Error> {
    Ok(Option::<Vec<Value>>::deserialize(d)?
        .unwrap_or_default()
        .into_iter()
        .filter_map(|v| serde_json::from_value(v).ok())
        .collect())
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct UsageTotals {
    #[serde(deserialize_with = "number::u64_required")]
    pub input: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub output: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub cache_read: u64,
    #[serde(deserialize_with = "number::u64_required")]
    pub cache_write: u64,
    pub cost: f64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct EventPage {
    #[serde(default, deserialize_with = "events")]
    pub events: Vec<TimelineEvent>,
    #[serde(default, deserialize_with = "number::u64_default")]
    pub next_offset: u64,
    pub tail_cursor: Option<String>,
    pub cursor: Option<String>,
    #[serde(default, deserialize_with = "super::null_default")]
    pub has_earlier: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub history_trimmed: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub reset: bool,
    pub usage: Option<UsageTotals>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct EventChunk {
    #[serde(default, deserialize_with = "events")]
    pub events: Vec<TimelineEvent>,
    #[serde(default, deserialize_with = "number::u64_default")]
    pub next_offset: u64,
    pub tail_cursor: Option<String>,
    #[serde(default, deserialize_with = "super::null_default")]
    pub reset: bool,
    #[serde(default, deserialize_with = "super::null_default")]
    pub has_more: bool,
}
