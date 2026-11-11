// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//! Decode `cursorAuth/accessToken` from Cursor's state database.
//!
//! Cursor 3.27+ stores the token as `cursor-safe-storage:v1:` plus base64
//! ciphertext. Chromium's macOS OSCrypt (`v10`) encrypts it with a key derived
//! from the `Cursor Safe Storage` Keychain item. Without decryption tokenstat
//! treated the ciphertext as a session cookie and Cursor rejected every limits
//! request, leaving the panel on a stale cache.
//!
//! Decryption is macOS only. Elsewhere the Keychain names and the decoder are
//! compiled but unused, because a plain token still passes through.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

#[cfg(target_os = "macos")]
use aes::cipher::KeyIvInit;
#[cfg(target_os = "macos")]
use cbc::cipher::block_padding::Pkcs7;
#[cfg(target_os = "macos")]
use cbc::{Decryptor, cipher::BlockDecryptMut};

const ENVELOPE_PREFIX: &str = "cursor-safe-storage:v1:";
const SAFE_STORAGE_SERVICE: &str = "Cursor Safe Storage";
const SAFE_STORAGE_ACCOUNTS: &[&str] = &["Cursor Key", "Cursor"];

/// Plain JWT, or a decrypted JWT when the stored value uses Cursor's envelope.
pub(crate) fn decode_stored_access_token(stored: &str) -> Option<String> {
    let stored = stored.trim().trim_matches('"');
    if stored.is_empty() {
        return None;
    }
    if !stored.starts_with("cursor-safe-storage:") {
        return Some(stored.to_string());
    }
    if !stored.starts_with(ENVELOPE_PREFIX) {
        return None;
    }
    #[cfg(target_os = "macos")]
    {
        decode_encrypted_macos(stored)
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn decode_encrypted_macos(stored: &str) -> Option<String> {
    let encoded = stored.strip_prefix(ENVELOPE_PREFIX)?;
    let encrypted = base64_decode(encoded)?;
    if encrypted.len() <= 3 || encrypted.get(..3) != Some(b"v10") {
        return None;
    }
    let payload_len = encrypted.len() - 3;
    if payload_len == 0 || !payload_len.is_multiple_of(16) {
        return None;
    }
    for account in SAFE_STORAGE_ACCOUNTS {
        let Some(password) = safe_storage_password(account) else {
            continue;
        };
        let key = derive_key(password.as_bytes());
        let Ok(plain) = decrypt_v10(&encrypted[3..], &key) else {
            continue;
        };
        let Ok(token) = String::from_utf8(plain) else {
            continue;
        };
        let token = token.trim();
        if !token.is_empty() {
            return Some(token.to_string());
        }
    }
    None
}

#[cfg(target_os = "macos")]
pub(crate) fn safe_storage_accounts() -> &'static [&'static str] {
    SAFE_STORAGE_ACCOUNTS
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn safe_storage_accounts() -> &'static [&'static str] {
    &[]
}

#[cfg(target_os = "macos")]
pub(crate) fn safe_storage_service() -> &'static str {
    SAFE_STORAGE_SERVICE
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn safe_storage_service() -> &'static str {
    SAFE_STORAGE_SERVICE
}

#[cfg(target_os = "macos")]
fn safe_storage_password(account: &str) -> Option<String> {
    match crate::discover::keychain_item(SAFE_STORAGE_SERVICE, account) {
        crate::discover::KeychainItem::Found(secret) => Some(secret),
        _ => None,
    }
}

#[cfg(target_os = "macos")]
fn derive_key(password: &[u8]) -> [u8; 16] {
    use pbkdf2::pbkdf2_hmac;
    use sha1::Sha1;
    let mut key = [0u8; 16];
    pbkdf2_hmac::<Sha1>(password, b"saltysalt", 1003, &mut key);
    key
}

#[cfg(target_os = "macos")]
fn decrypt_v10(payload: &[u8], key: &[u8; 16]) -> Result<Vec<u8>, ()> {
    type Aes128CbcDec = Decryptor<aes::Aes128>;
    let iv = [0x20u8; 16];
    let cipher = Aes128CbcDec::new_from_slices(key, &iv).map_err(|_| ())?;
    let mut buf = payload.to_vec();
    cipher
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| ())
        .map(|plain| plain.to_vec())
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .ok()
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn malformed_envelopes_never_decrypt() {
        assert!(decode_stored_access_token("cursor-safe-storage:v1:!").is_none());
        assert!(decode_stored_access_token("cursor-safe-storage:v2:AAAA").is_none());
    }

    #[test]
    fn plain_jwt_passes_through() {
        let jwt = "header.payload.signature";
        assert_eq!(decode_stored_access_token(jwt).as_deref(), Some(jwt));
    }

    #[test]
    fn v10_round_trip() {
        let jwt = "header.payload.signature";
        let password = b"synthetic-password";
        let encrypted = encrypt_v10(jwt.as_bytes(), password);
        let key = derive_key(password);
        let plain = decrypt_v10(&encrypted[3..], &key).unwrap();
        assert_eq!(String::from_utf8(plain).unwrap(), jwt);
    }

    fn encrypt_v10(plain: &[u8], password: &[u8]) -> Vec<u8> {
        use aes::cipher::{BlockEncryptMut, KeyIvInit};
        use cbc::Encryptor;
        use cbc::cipher::block_padding::Pkcs7;
        type Aes128CbcEnc = Encryptor<aes::Aes128>;
        let key = derive_key(password);
        let iv = [0x20u8; 16];
        let cipher = Aes128CbcEnc::new_from_slices(&key, &iv).unwrap();
        let mut buf = vec![0u8; plain.len() + 16];
        buf[..plain.len()].copy_from_slice(plain);
        let len = cipher
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
            .unwrap()
            .len();
        let mut out = b"v10".to_vec();
        out.extend_from_slice(&buf[..len]);
        out
    }
}
