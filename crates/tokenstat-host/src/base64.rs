//! Standard base64 for binary terminal output and attachment chunks.

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const DECODE: [u8; 256] = {
    let mut values = [u8::MAX; 256];
    let mut index = 0;
    while index < ALPHABET.len() {
        values[ALPHABET[index] as usize] = index as u8;
        index += 1;
    }
    values
};

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
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    // Most chunks contain only complete, unpadded quanta. Decode those
    // directly; the tail below retains whitespace and strict padding checks.
    let bytes = input.as_bytes();
    let mut offset = 0;
    while offset + 4 <= bytes.len() {
        let a = DECODE[bytes[offset] as usize];
        let b = DECODE[bytes[offset + 1] as usize];
        let c = DECODE[bytes[offset + 2] as usize];
        let d = DECODE[bytes[offset + 3] as usize];
        if (a | b | c | d) == u8::MAX {
            break;
        }
        out.extend_from_slice(&[(a << 2) | (b >> 4), (b << 4) | (c >> 2), (c << 6) | d]);
        offset += 4;
    }
    let mut quantum = [0u8; 4];
    let mut count = 0usize;
    let mut padding = 0usize;
    for &c in &bytes[offset..] {
        match c {
            b'\n' | b'\r' | b' ' => continue,
            b'=' => {
                if padding == 2 {
                    return Err("not base64: too much padding".into());
                }
                padding += 1;
                continue;
            }
            _ => {}
        }
        if padding > 0 {
            return Err(format!("not base64: {:?} after padding", c as char));
        }
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err(format!("not base64: {:?}", c as char)),
        };
        quantum[count] = value;
        count += 1;
        if count == 4 {
            out.extend_from_slice(&[
                (quantum[0] << 2) | (quantum[1] >> 4),
                (quantum[1] << 4) | (quantum[2] >> 2),
                (quantum[2] << 6) | quantum[3],
            ]);
            count = 0;
        }
    }
    // Padding must complete the last quantum; missing or extra marks fail.
    if count != (4 - padding) % 4 {
        return Err("truncated base64".into());
    }
    // Unused bits must be zero so distinct encodings cannot alias a byte.
    if count == 2 && quantum[1] & 0b0000_1111 != 0 || count == 3 && quantum[2] & 0b0000_0011 != 0 {
        return Err("not canonical base64: unused bits are set".into());
    }
    if count >= 2 {
        out.push((quantum[0] << 2) | (quantum[1] >> 4));
    }
    if count == 3 {
        out.push((quantum[1] << 4) | (quantum[2] >> 2));
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
    fn chunk_boundaries_whitespace_and_padding_preserve_bytes() {
        let mut state = 0x1234_5678u64;
        for length in 0..1024 {
            let bytes: Vec<u8> = (0..length)
                .map(|_| {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    state as u8
                })
                .collect();
            let encoded = encode(&bytes);
            assert_eq!(decode(&encoded).unwrap(), bytes);
            for split in [
                0,
                1,
                3,
                4,
                5,
                encoded.len().saturating_sub(1),
                encoded.len(),
            ] {
                if split <= encoded.len() {
                    let spaced = format!("{} \r\n{}", &encoded[..split], &encoded[split..]);
                    assert_eq!(
                        decode(&spaced).unwrap(),
                        bytes,
                        "length {length}, split {split}"
                    );
                }
            }
            assert!(decode(&(encoded.clone() + "!")).is_err());
            assert!(decode(&(encoded + "é")).is_err());
        }
        for prefix in ["", "AAAA", "AAAAAAAA"] {
            for &a in ALPHABET {
                for &b in ALPHABET {
                    let encoded = format!("{prefix}{}{}==", a as char, b as char);
                    let decoded = decode(&encoded);
                    let canonical = ALPHABET.iter().position(|&v| v == b).unwrap() % 16 == 0;
                    assert_eq!(decoded.is_ok(), canonical, "{encoded}");
                    if let Ok(bytes) = decoded {
                        assert_eq!(encode(&bytes), encoded);
                    }
                }
            }
            for suffix in ["=", "==", "===", "Zh==", "Zm9=", "Zg==A", "AA\tA", "AA_A"] {
                assert!(decode(&format!("{prefix}{suffix}")).is_err());
            }
        }
    }

    #[test]
    #[ignore = "attachment chunk decoding benchmark"]
    fn benchmark_attachment_chunk_decode() {
        let bytes: Vec<u8> = (0..512 * 1024)
            .map(|i| ((i * 197 + i / 13) % 256) as u8)
            .collect();
        let encoded = encode(&bytes);
        assert_eq!(decode(&encoded).unwrap(), bytes);
        let mut samples = Vec::new();
        for _ in 0..31 {
            let start = std::time::Instant::now();
            for _ in 0..10 {
                std::hint::black_box(decode(std::hint::black_box(&encoded)).unwrap());
            }
            samples.push(start.elapsed().as_secs_f64() * 100.0);
        }
        samples.sort_by(f64::total_cmp);
        println!("512 KiB decode median_ms={:.6}", samples[15]);
    }

    #[test]
    fn rubbish_is_refused_rather_than_guessed() {
        // A mangled keystroke would be typed into a live shell.
        assert!(decode("not base64!").is_err());
        assert!(decode("Z").is_err());
    }

    #[test]
    fn trailing_garbage_and_loose_padding_are_refused() {
        // Anything after the first padding mark is not part of the encoding.
        assert!(decode("Zg==garbage").is_err());
        // 'h' is index 33, whose low bits are not the zero a one-byte value
        // leaves spare: non-canonical, and refused rather than rounded.
        assert!(decode("Zh==").is_err());
        assert!(decode("Zm9vYg==x").is_err());
        // Padding is required, and only in the one shape that fits.
        assert!(decode("Zg").is_err());
        assert!(decode("Zg=").is_err());
        assert!(decode("Zm9vYg=").is_err());
        assert!(decode("Zg===").is_err());
        assert!(decode("=").is_err());
    }
}
