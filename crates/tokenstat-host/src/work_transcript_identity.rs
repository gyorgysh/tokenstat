// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Preserve readable-row sequence identities when compacting a transcript.
//! Physical byte cursors still belong to the file reader. This transformation
//! materializes legacy positions before moving records; it never renumbers them.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::VecDeque;

fn object(line: &[u8]) -> Result<Map<String, Value>, &'static str> {
    match serde_json::from_slice(line) {
        Ok(Value::Object(object)) => Ok(object),
        _ => Err("conversation record could not be verified"),
    }
}

pub(crate) fn sequence(record: &Map<String, Value>, offset: u64) -> Result<u64, &'static str> {
    match record.get("seq") {
        Some(value) => value
            .as_u64()
            .ok_or("conversation record position is invalid"),
        None => Ok(offset),
    }
}

/// Put the identity first, so a small prefix identifies a retained generation
/// even when the first event contains a large tool result or prompt.
pub(crate) fn encoded(mut record: Map<String, Value>, seq: u64) -> Result<Vec<u8>, &'static str> {
    record.remove("seq");
    let mut bytes = format!("{{\"seq\":{seq}").into_bytes();
    if record.is_empty() {
        bytes.push(b'}');
    } else {
        bytes.push(b',');
        let rest =
            serde_json::to_vec(&record).map_err(|_| "conversation record could not be encoded")?;
        bytes.extend_from_slice(&rest[1..]);
    }
    bytes.push(b'\n');
    Ok(bytes)
}

/// Fixed reserve for the numeric summary carried across history compaction.
pub(crate) const SUMMARY_BYTES: usize = 512;

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct UsageTotals {
    turns: u64,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    cost: f64,
}

impl UsageTotals {
    pub(crate) fn from_record(record: &Map<String, Value>) -> Result<Self, &'static str> {
        let totals = if record.get("kind").and_then(Value::as_str) == Some("retainedUsage") {
            serde_json::from_value(
                record
                    .get("usage")
                    .cloned()
                    .ok_or("conversation usage summary is missing")?,
            )
            .map_err(|_| "conversation usage summary could not be verified")?
        } else if let Some(event) = record
            .get("event")
            .filter(|event| event.get("kind").and_then(Value::as_str) == Some("usage"))
        {
            let number = |key: &str, alias: &str| {
                event
                    .get(key)
                    .or_else(|| event.get(alias))
                    .and_then(Value::as_u64)
                    .unwrap_or(0)
            };
            Self {
                turns: 1,
                input: number("input", "input"),
                output: number("output", "output"),
                cache_read: number("cache_read", "cacheRead"),
                cache_write: number("cache_write", "cacheWrite"),
                cost: event
                    .get("cost_usd")
                    .or_else(|| event.get("costUsd"))
                    .and_then(Value::as_f64)
                    .unwrap_or(0.0),
            }
        } else {
            Self::default()
        };
        if !totals.cost.is_finite() || totals.cost < 0.0 {
            return Err("conversation usage cost is invalid");
        }
        Ok(totals)
    }

    pub(crate) fn add(&mut self, other: &Self) -> Result<(), &'static str> {
        let sum = |a: u64, b: u64| {
            a.checked_add(b)
                .ok_or("conversation usage count is exhausted")
        };
        let next = Self {
            turns: sum(self.turns, other.turns)?,
            input: sum(self.input, other.input)?,
            output: sum(self.output, other.output)?,
            cache_read: sum(self.cache_read, other.cache_read)?,
            cache_write: sum(self.cache_write, other.cache_write)?,
            cost: self.cost + other.cost,
        };
        if !next.cost.is_finite() {
            return Err("conversation usage cost is exhausted");
        }
        *self = next;
        Ok(())
    }

    fn is_empty(&self) -> bool {
        self.turns == 0
            && self.input == 0
            && self.output == 0
            && self.cache_read == 0
            && self.cache_write == 0
            && self.cost == 0.0
    }

    pub(crate) fn value(&self) -> Value {
        json!({"turns":self.turns,"input":self.input,"output":self.output,
            "cacheRead":self.cache_read,"cacheWrite":self.cache_write,"cost":self.cost})
    }

    fn marker(&self, seq: u64) -> Result<Vec<u8>, &'static str> {
        let Value::Object(record) = json!({"kind":"retainedUsage","usage":self.value()}) else {
            return Err("conversation usage summary could not be encoded");
        };
        let bytes = encoded(record, seq)?;
        if bytes.len() > SUMMARY_BYTES {
            return Err("conversation usage summary is too large");
        }
        Ok(bytes)
    }
}

/// Compute the next logical position from the last complete physical record.
/// The caller provides a bounded tail ending exactly at EOF under its writer
/// lock. A partial trailing write is an error, never an invitation to reuse IDs.
pub fn next_sequence(tail: &[u8], base: u64) -> Result<u64, &'static str> {
    if tail.is_empty() {
        return if base == 0 {
            Ok(0)
        } else {
            Err("conversation tail is unavailable")
        };
    }
    if tail.last() != Some(&b'\n') {
        return Err("conversation has an incomplete record");
    }
    let mut offset = base;
    let mut next = None;
    let mut previous = None;
    for line in tail.split_inclusive(|byte| *byte == b'\n') {
        let record = object(line)?;
        let start = sequence(&record, offset)?;
        if previous.is_some_and(|value| start <= value) {
            return Err("conversation record positions are not ordered");
        }
        previous = Some(start);
        next = Some(
            start
                .checked_add(line.len() as u64)
                .ok_or("conversation position is exhausted")?,
        );
        offset = offset
            .checked_add(line.len() as u64)
            .ok_or("conversation position is exhausted")?;
    }
    next.ok_or("conversation tail is unavailable")
}

/// Keep a bounded suffix of whole records, storing each original identity.
/// Invalid input refuses the rewrite, rather than silently losing history.
/// At least the newest record must fit; the writer must enforce the same cap.
pub fn retained(bytes: &[u8], cap: usize) -> Result<Vec<u8>, &'static str> {
    if bytes.is_empty() {
        return Ok(vec![]);
    }
    if bytes.last() != Some(&b'\n') {
        return Err("conversation has an incomplete record");
    }
    struct Entry {
        seq: u64,
        bytes: Vec<u8>,
        usage: UsageTotals,
    }
    let mut kept = VecDeque::new();
    let mut size = 0;
    let mut offset = 0u64;
    let mut previous = None;
    let mut discarded = UsageTotals::default();
    let mut discarded_seq = 0;
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        let record = object(line)?;
        let seq = sequence(&record, offset)?;
        if previous.is_some_and(|value| seq <= value) {
            return Err("conversation record positions are not ordered");
        }
        previous = Some(seq);
        let usage = UsageTotals::from_record(&record)?;
        let bytes = encoded(record, seq)?;
        size += bytes.len();
        kept.push_back(Entry { seq, bytes, usage });
        while size > cap {
            let Some(removed) = kept.pop_front() else {
                return Err("conversation retention size is invalid");
            };
            size -= removed.bytes.len();
            discarded.add(&removed.usage)?;
            discarded_seq = removed.seq;
        }
        offset = offset
            .checked_add(line.len() as u64)
            .ok_or("conversation position is exhausted")?;
    }
    loop {
        if kept.is_empty() {
            return Err("conversation record exceeds the retention limit");
        }
        let marker = if discarded.is_empty() {
            Vec::new()
        } else {
            discarded.marker(discarded_seq)?
        };
        if size + marker.len() <= cap {
            return Ok(marker
                .into_iter()
                .chain(kept.into_iter().flat_map(|entry| entry.bytes))
                .collect());
        }
        // Reserve the summary in the same atomic rewrite as the retained
        // rows. Its position advances with the evicted prefix even when that
        // prefix contained no new usage, so cursors still detect every trim.
        let Some(removed) = kept.pop_front() else {
            return Err("conversation retention size is invalid");
        };
        size -= removed.bytes.len();
        discarded.add(&removed.usage)?;
        discarded_seq = removed.seq;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn line(value: Value) -> Vec<u8> {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        bytes
    }
    #[test]
    fn legacy_positions_survive_repeated_trimming_and_new_appends() {
        let first = line(json!({"kind":"user","text":"first"}));
        let second = line(json!({"kind":"user","text":"second"}));
        let third = line(json!({"kind":"user","text":"third"}));
        let bytes = [first.clone(), second.clone(), third].concat();
        let kept = retained(&bytes, 100).unwrap();
        let rows: Vec<Value> = kept
            .split(|b| *b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect();
        assert_eq!(
            rows.last().unwrap()["seq"],
            (first.len() + second.len()) as u64
        );
        assert_eq!(retained(&kept, 100).unwrap(), kept);
        let seq = next_sequence(&kept, 0).unwrap();
        let appended = [kept, line(json!({"kind":"user","text":"fourth","seq":seq}))].concat();
        let again = retained(&appended, 100).unwrap();
        let last = again
            .split(|b| *b == b'\n')
            .rfind(|l| !l.is_empty())
            .unwrap();
        assert_eq!(object(last).unwrap()["seq"], seq);
        assert!(next_sequence(&again, 0).unwrap() > seq);
    }
    #[test]
    fn sequence_precedes_large_payloads_and_empty_records_are_valid_json() {
        let record = object(br#"{"event":{"kind":"text","delta":"content"}}"#).unwrap();
        let bytes = encoded(record, 123).unwrap();
        assert!(bytes.starts_with(b"{\"seq\":123,"));
        assert_eq!(object(&bytes).unwrap()["event"]["delta"], "content");
        assert_eq!(object(&encoded(Map::new(), 1).unwrap()).unwrap()["seq"], 1);
    }

    #[test]
    fn usage_summaries_are_bounded_idempotent_and_refuse_corruption() {
        let usage =
            line(json!({"kind":"agent","event":{"kind":"usage","input":100,"cost_usd":0.1}}));
        let message = line(json!({"kind":"user","text":"x".repeat(150)}));
        let bytes = [usage, message.clone(), message].concat();
        let kept = retained(&bytes, 400).unwrap();
        assert!(kept.len() <= 400);
        assert_eq!(retained(&kept, 400).unwrap(), kept);
        let mut totals = UsageTotals::default();
        for row in kept.split_inclusive(|b| *b == b'\n') {
            totals
                .add(&UsageTotals::from_record(&object(row).unwrap()).unwrap())
                .unwrap();
        }
        assert_eq!(totals.value()["input"], 100);
        assert_eq!(totals.value()["turns"], 1);
        assert!(retained(b"{\"kind\":\"retainedUsage\",\"usage\":{}}\n", 1000).is_err());
        let maximum = UsageTotals {
            input: u64::MAX,
            ..UsageTotals::default()
        };
        let mut total = maximum.clone();
        assert!(
            total
                .add(&UsageTotals {
                    input: 1,
                    ..UsageTotals::default()
                })
                .is_err()
        );
        assert_eq!(
            total.value(),
            maximum.value(),
            "a failed fold changes no counts"
        );
        assert!(maximum.marker(u64::MAX).unwrap().len() <= SUMMARY_BYTES);
    }

    #[test]
    fn corruption_partial_writes_and_oversize_records_refuse_rewrite() {
        for input in [
            b"broken\n".as_slice(),
            b"{}",
            b"{\"seq\":-1}\n",
            b"{\"seq\":2}\n{\"seq\":1}\n",
        ] {
            assert!(retained(input, 1024).is_err());
        }
        assert!(retained(&line(json!({"text":"private"})), 4).is_err());
        assert!(next_sequence(b"{}", 0).is_err());
        assert!(next_sequence(b"{\"seq\":2}\n{\"seq\":1}\n", 0).is_err());
        assert!(next_sequence(&[], 100).is_err());
        assert_eq!(next_sequence(&[], 0), Ok(0));
        assert!(next_sequence(&line(json!({"seq":u64::MAX})), 0).is_err());
    }
}
