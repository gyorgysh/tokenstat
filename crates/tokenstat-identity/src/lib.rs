// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Who this machine is to another machine, and which machines it trusts.
//!
//! # Why a keypair and not the account token
//!
//! A machine reaching another one carries terminal output, file contents and
//! diffs, which is the whole of somebody's work rather than the aggregate
//! counters sync moves. See `docs/remote-transport.md` for the reasoning; the
//! part that decides this crate's shape is that the account token is a bearer
//! credential the server issues, so a server able to issue tokens is a server
//! able to impersonate any machine to any other. A keypair generated here and
//! never sent anywhere cannot be forged by anyone, the hosted service included.
//!
//! # No network, on purpose
//!
//! This crate is on `scripts/check-no-network.sh`'s guarded list. It decides
//! who may connect; a crate that could also *make* a connection would be a
//! place for that decision to leak out.

use std::path::PathBuf;

use thiserror::Error;
use x25519_dalek::{PublicKey as X25519Public, StaticSecret};

pub mod peers;

pub use peers::{Peer, PeerStore, Trust};

/// Bytes of an X25519 public key. The thing that is actually pinned, and the
/// thing the Noise handshake authenticates. One key doing one job: a separate
/// signing key alongside it would be two keys to compare and a way for them to
/// disagree about who a machine is.
pub type PublicKey = [u8; 32];

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("no data directory on this platform")]
    NoDataDir,
    #[error("{path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("the identity file is {0} bytes, and an X25519 private key is 32")]
    Malformed(usize),
    #[error("{0}")]
    Random(String),
    #[error("not a public key: {0}")]
    BadKey(String),
}

/// This machine's identity to another machine.
///
/// Created on first use and then stable. Deleting the file makes the machine a
/// stranger to every peer that pinned it, which is the intended and only way
/// to start over.
pub struct MachineIdentity {
    secret: StaticSecret,
}

impl MachineIdentity {
    /// Load the identity, generating one the first time.
    ///
    /// The private key is a mode-0600 file in the data directory, matching how
    /// `tokenstat-sync` stores the account token. The macOS Keychain was the
    /// obvious alternative and is not used, for the reason already recorded
    /// there: the `security` command line takes the secret on argv, where it
    /// is visible in the process table to every process on the machine.
    pub fn load_or_create() -> Result<Self, IdentityError> {
        let path = key_path()?;
        if let Some(bytes) = read_key(&path)? {
            return Ok(Self::from_secret(bytes));
        }

        let mut seed = [0u8; 32];
        getrandom::fill(&mut seed).map_err(|e| IdentityError::Random(e.to_string()))?;
        write_key(&path, &seed)?;
        Ok(Self::from_secret(seed))
    }

    /// Build from raw private bytes. `StaticSecret` clamps them, so any 32
    /// bytes are a usable key and there is no "invalid seed" case to handle.
    pub fn from_secret(bytes: [u8; 32]) -> Self {
        Self {
            secret: StaticSecret::from(bytes),
        }
    }

    pub fn public_key(&self) -> PublicKey {
        X25519Public::from(&self.secret).to_bytes()
    }

    /// The private key, for the one caller that needs it: the handshake.
    ///
    /// Deliberately awkward to reach for and named for what it is. Nothing
    /// else in the tree has any business calling this, and a reviewer grepping
    /// for it should find exactly one use.
    pub fn secret_bytes(&self) -> [u8; 32] {
        self.secret.to_bytes()
    }

    /// The public key as lowercase hex. This is the machine's identity on the
    /// wire and in the account's machine record.
    pub fn public_key_hex(&self) -> String {
        hex(&self.public_key())
    }

    /// The short form a person compares out of band.
    pub fn fingerprint(&self) -> String {
        fingerprint(&self.public_key())
    }
}

/// The short form of a public key, for a person to read aloud.
///
/// Six groups of four hex characters, 96 bits. The full 32-byte key is what
/// gets pinned and compared by machines; this exists only so two people can
/// check they are looking at the same machine. 96 bits is far past what a
/// human will compare carefully and far past what an attacker can grind for a
/// collision that also has to be a usable key.
///
/// Hashed rather than truncated, so a fingerprint reveals nothing that would
/// help someone search for a key that displays the same.
pub fn fingerprint(public: &PublicKey) -> String {
    let mut hasher = blake3::Hasher::new();
    // Domain separation: this hash must never collide with any other use of
    // blake3 over the same bytes elsewhere in the tree.
    hasher.update(b"tokenstat machine fingerprint v1\0");
    hasher.update(public);
    let digest = hasher.finalize();
    let short = &digest.as_bytes()[..12];
    hex(short)
        .as_bytes()
        .chunks(4)
        .map(|c| String::from_utf8_lossy(c).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

/// Parse a public key written as hex.
pub fn public_key_from_hex(text: &str) -> Result<PublicKey, IdentityError> {
    let cleaned: String = text
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .collect();
    if cleaned.len() != 64 {
        return Err(IdentityError::BadKey(format!(
            "expected 64 hex characters, got {}",
            cleaned.len()
        )));
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        let pair = &cleaned[i * 2..i * 2 + 2];
        *byte = u8::from_str_radix(pair, 16)
            .map_err(|e| IdentityError::BadKey(format!("{pair}: {e}")))?;
    }
    // Every 32-byte string is a usable X25519 public key, so there is nothing
    // further to check. The length check above is the one that catches the
    // realistic mistake, which is pasting a fingerprint where a key goes.
    Ok(out)
}

/// What to call this machine when introducing it to a peer.
///
/// The name the user already gave the computer, so a peer list reads like the
/// machines on the desk rather than like a list of keys.
///
/// **Never eligible for sync.** A hostname is identifying, and `profile.rs`
/// states that project paths, sessions, prompts and hostnames do not enter that
/// path. This travels only to a machine the user explicitly paired with.
pub fn machine_label() -> String {
    #[cfg(target_os = "macos")]
    {
        // The name in Sharing preferences, which is what the user recognises.
        // `hostname` on a Mac often answers with a DHCP-assigned string that
        // means nothing to anyone.
        if let Ok(out) = std::process::Command::new("scutil")
            .args(["--get", "ComputerName"])
            .output()
        {
            let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !name.is_empty() {
                return name;
            }
        }
    }
    std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "this machine".into())
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Where the identity and the peer list live.
///
/// `TOKENSTAT_IDENTITY_DIR` overrides it. That is not a test hook bolted on: a
/// second daemon on one machine needs a second identity, which is how the
/// remote transport is exercised end to end without a second computer, and how
/// somebody can run a throwaway instance without disturbing the one their
/// peers have pinned.
pub fn identity_dir() -> Result<PathBuf, IdentityError> {
    let dir = match std::env::var_os("TOKENSTAT_IDENTITY_DIR") {
        Some(explicit) => PathBuf::from(explicit),
        None => directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
            .ok_or(IdentityError::NoDataDir)?
            .data_dir()
            .join("identity"),
    };
    std::fs::create_dir_all(&dir).map_err(|e| IdentityError::Io {
        path: dir.display().to_string(),
        source: e,
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(dir)
}

fn key_path() -> Result<PathBuf, IdentityError> {
    Ok(identity_dir()?.join("machine.key"))
}

fn read_key(path: &std::path::Path) -> Result<Option<[u8; 32]>, IdentityError> {
    if !path.exists() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|e| IdentityError::Io {
        path: path.display().to_string(),
        source: e,
    })?;
    let seed: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| IdentityError::Malformed(bytes.len()))?;
    Ok(Some(seed))
}

fn write_key(path: &std::path::Path, seed: &[u8; 32]) -> Result<(), IdentityError> {
    // Written before the permissions are set, so there is a window where the
    // file is readable by the user's own umask. Create it empty and restricted
    // first, then write, so the window holds no key.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| IdentityError::Io {
                path: path.display().to_string(),
                source: e,
            })?;
    }
    std::fs::write(path, seed).map_err(|e| IdentityError::Io {
        path: path.display().to_string(),
        source: e,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fingerprint_is_readable_and_stable() {
        let key = [7u8; 32];
        let fp = fingerprint(&key);
        assert_eq!(fp, fingerprint(&key), "the same key must print the same");
        assert_eq!(fp.len(), 29, "six groups of four plus five dashes: {fp}");
        assert_eq!(fp.matches('-').count(), 5);
        assert!(
            fp.chars().all(|c| c.is_ascii_hexdigit() || c == '-'),
            "{fp}"
        );
    }

    #[test]
    fn different_keys_do_not_share_a_fingerprint() {
        assert_ne!(fingerprint(&[1u8; 32]), fingerprint(&[2u8; 32]));
    }

    /// Truncating the key itself would let a fingerprint leak the first bytes
    /// of the thing it identifies, and would make searching for a lookalike a
    /// matter of matching a prefix rather than a hash.
    #[test]
    fn a_fingerprint_is_not_a_prefix_of_the_key() {
        let key = [0xabu8; 32];
        assert!(!fingerprint(&key).replace('-', "").starts_with("abab"));
    }

    /// Same private bytes, same public key, every time. A machine whose
    /// identity file survived a restart has to still be the machine its peers
    /// pinned, and this is the property that makes that true.
    #[test]
    fn a_secret_always_produces_the_same_public_key() {
        let a = MachineIdentity::from_secret([3u8; 32]);
        let b = MachineIdentity::from_secret([3u8; 32]);
        assert_eq!(a.public_key(), b.public_key());
        assert_ne!(
            a.public_key(),
            MachineIdentity::from_secret([4u8; 32]).public_key()
        );
    }

    #[test]
    fn hex_round_trips_through_the_parser() {
        let identity = MachineIdentity::from_secret([9u8; 32]);
        let parsed = public_key_from_hex(&identity.public_key_hex()).expect("parse");
        assert_eq!(parsed, identity.public_key());
    }

    /// Someone typing a fingerprint where a key belongs is the likeliest paste
    /// error there is, and it has to fail loudly rather than pin nothing.
    #[test]
    fn a_fingerprint_is_refused_where_a_key_is_expected() {
        let identity = MachineIdentity::from_secret([9u8; 32]);
        assert!(public_key_from_hex(&identity.fingerprint()).is_err());
    }

    #[test]
    fn hex_of_the_wrong_length_is_refused() {
        assert!(public_key_from_hex("abcd").is_err());
        assert!(public_key_from_hex(&"ab".repeat(33)).is_err());
    }
}
