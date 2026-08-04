//! Base64, because terminal output is not text.
//!
//! A pty emits bytes, and an escape sequence can be cut in half at any read
//! boundary, so the JSON transport cannot carry it as a string. Encoding is
//! twenty lines of a fully specified standard, which is cheaper than another
//! dependency in a link tree whose licences have to be argued about.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding (RFC 4648 section 4).
pub fn encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Decode, rejecting anything that is not valid rather than guessing.
///
/// A keystroke arriving mangled would be typed into a live shell, so a wrong
/// byte is worse than a refused write.
pub fn decode(input: &str) -> Result<Vec<u8>, String> {
    let mut bits = Vec::with_capacity(input.len());
    for c in input.bytes() {
        match c {
            b'\n' | b'\r' | b' ' => continue,
            b'=' => break,
            _ => {}
        }
        let v = ALPHABET
            .iter()
            .position(|&a| a == c)
            .ok_or_else(|| format!("not base64: {:?}", c as char))?;
        bits.push(v as u8);
    }

    let mut out = Vec::with_capacity(bits.len() * 3 / 4);
    for chunk in bits.chunks(4) {
        if chunk.len() < 2 {
            return Err("truncated base64".into());
        }
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, &v)| acc | ((v as u32) << (18 - 6 * i)));
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_rfc_vectors() {
        for (raw, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(encode(raw.as_bytes()), encoded, "encoding {raw:?}");
            assert_eq!(decode(encoded).unwrap(), raw.as_bytes(), "decoding {raw:?}");
        }
    }

    #[test]
    fn every_byte_survives_a_round_trip() {
        // Terminal output is arbitrary bytes, including invalid UTF-8 and a
        // half-finished escape sequence, so this has to be exact.
        let all: Vec<u8> = (0..=255u8).collect();
        assert_eq!(decode(&encode(&all)).unwrap(), all);

        for len in 0..8 {
            let bytes: Vec<u8> = (0..len).map(|i| i as u8 ^ 0xA5).collect();
            assert_eq!(decode(&encode(&bytes)).unwrap(), bytes, "length {len}");
        }
    }

    #[test]
    fn rubbish_is_refused_rather_than_guessed() {
        // A mangled keystroke would be typed into a live shell.
        assert!(decode("not base64!").is_err());
        assert!(decode("Z").is_err());
    }
}
