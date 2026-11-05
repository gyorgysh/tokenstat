// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Hook previews retain the first 360 characters of serde_json's output.
//! Large tool arguments and image results need no full serialized copy.

use serde::{
    Serialize, Serializer,
    ser::{SerializeMap, SerializeSeq},
};
use serde_json::Value;
use std::io::{self, Write};

const CHARACTERS: usize = 360;

fn text_prefix(text: &str) -> &str {
    let end = text
        .char_indices()
        .nth(CHARACTERS)
        .map_or(text.len(), |(at, _)| at);
    &text[..end]
}

struct Preview<'a>(&'a Value);

impl Serialize for Preview<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Value::Null => serializer.serialize_unit(),
            Value::Bool(value) => serializer.serialize_bool(*value),
            Value::Number(value) => value.serialize(serializer),
            // Escaping never shortens a string. Any omitted characters, and
            // the closing quote we introduce, lie beyond the preview boundary.
            Value::String(value) => serializer.serialize_str(text_prefix(value)),
            Value::Array(values) => {
                let mut sequence = serializer.serialize_seq(Some(values.len()))?;
                for value in values {
                    sequence.serialize_element(&Preview(value))?;
                }
                sequence.end()
            }
            Value::Object(values) => {
                let mut map = serializer.serialize_map(Some(values.len()))?;
                for (key, value) in values {
                    map.serialize_entry(text_prefix(key), &Preview(value))?;
                }
                map.end()
            }
        }
    }
}

struct Prefix {
    bytes: [u8; CHARACTERS * 4],
    length: usize,
}

impl Write for Prefix {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        let count = bytes.len().min(self.bytes.len() - self.length);
        if count == 0 {
            return Err(io::Error::other("preview complete"));
        }
        self.bytes[self.length..self.length + count].copy_from_slice(&bytes[..count]);
        self.length += count;
        Ok(count)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) fn json_prefix(value: &Value) -> String {
    let mut prefix = Prefix {
        bytes: [0; CHARACTERS * 4],
        length: 0,
    };
    // The bounded writer deliberately stops serialization once it has enough
    // bytes for 360 Unicode scalar values, even for an array of tiny values.
    let _ = serde_json::to_writer(&mut prefix, &Preview(value));
    let bytes = &prefix.bytes[..prefix.length];
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text,
        Err(error) => std::str::from_utf8(&bytes[..error.valid_up_to()]).unwrap_or_default(),
    };
    text.chars().take(CHARACTERS).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn prefixes_match_full_serialization_across_nested_values_and_boundaries() {
        let strings = ["a", "é", "🦀", "\"\\\n\r\t\0", "aé🦀\t"];
        for size in [0, 1, 89, 90, 359, 360, 361, 1439, 1440, 1441] {
            for text in strings {
                let text = text.repeat(size);
                let values = [
                    json!(text),
                    json!({text.clone(): [null, true, 1.25, -5]}),
                    json!(["prefix", {"data": text}]),
                    json!((0..size).collect::<Vec<_>>()),
                ];
                for value in values {
                    let expected: String = serde_json::to_string(&value)
                        .unwrap()
                        .chars()
                        .take(CHARACTERS)
                        .collect();
                    assert_eq!(json_prefix(&value), expected);
                }
            }
        }
    }
}
