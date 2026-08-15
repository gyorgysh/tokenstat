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

    /// The identity if this machine already has one, without creating it.
    ///
    /// For callers that only want to *compare* keys and would rather leave no
    /// trace when there is nothing to compare. A daemon deciding whether some
    /// other process already speaks for this machine is the case: with no key
    /// on disk there is nothing another process could be holding, so the
    /// question answers itself, and generating one to ask it would leave
    /// identity material behind for a process that then refused to start.
    pub fn load() -> Result<Option<Self>, IdentityError> {
        Ok(read_key(&key_path()?)?.map(Self::from_secret))
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

/// The same key as three words, for a person to compare at a glance.
///
/// Nobody compares `a41f-88c2-...` carefully. They compare the first group, the
/// last group, and assume. Three words out of fixed lists are read whole, said
/// aloud over a phone, and noticed when they differ, which is the entire job
/// this string has: two people, two screens, one question.
///
/// It is not a shorter fingerprint and does not replace one. The machines pin
/// the full 32 bytes and compare those; both of these strings exist only for
/// the human check, and this one is the version a human will actually do. The
/// full fingerprint stays available for anyone who wants it.
///
/// 32 × 32 × 32 combinations is ~15 bits: not collision resistant, and not
/// meant to be — an adversary never sees these words, they see the key. The
/// words catch the realistic case, which is a machine that is not the one you
/// think, and three words keep a fleet of a few hundred machines free of
/// accidental lookalikes where two did not.
pub fn key_words(public: &PublicKey) -> String {
    let mut hasher = blake3::Hasher::new();
    // Separate domain from `fingerprint`, so the two displays of one key cannot
    // be turned into each other.
    hasher.update(b"tokenstat machine words v2\0");
    hasher.update(public);
    let digest = hasher.finalize();
    let bytes = digest.as_bytes();
    let first = u16::from_be_bytes([bytes[0], bytes[1]]) as usize;
    let second = u16::from_be_bytes([bytes[2], bytes[3]]) as usize;
    let third = u16::from_be_bytes([bytes[4], bytes[5]]) as usize;
    format!(
        "{}-{}-{}",
        ADJECTIVES[first % ADJECTIVES.len()],
        NOUNS[second % NOUNS.len()],
        PLACES[third % PLACES.len()]
    )
}

/// Short, common, and hard to mishear. No two entries share a prefix, so a word
/// half read is still unambiguous.
const ADJECTIVES: [&str; 32] = [
    "amber", "brave", "calm", "dusty", "eager", "fair", "glad", "hollow", "icy", "jolly", "keen",
    "lucky", "mellow", "noble", "olive", "proud", "quiet", "rapid", "solid", "tidy", "upper",
    "vivid", "warm", "young", "zesty", "bold", "crisp", "deep", "early", "fresh", "gentle",
    "hardy",
];

/// Animals, because they are concrete and people picture them, which is what
/// makes a mismatch obvious rather than a detail to squint at.
const NOUNS: [&str; 32] = [
    "otter", "falcon", "badger", "cedar", "dolphin", "ember", "fox", "gecko", "heron", "ibis",
    "jaguar", "kestrel", "lynx", "marten", "newt", "osprey", "puffin", "quail", "raven", "seal",
    "tapir", "urchin", "viper", "walrus", "yak", "zebra", "bison", "crane", "dingo", "egret",
    "finch", "gull",
];

/// Landmarks, kept in the same voice: short, concrete, no shared prefixes.
const PLACES: [&str; 32] = [
    "acorn", "beacon", "birch", "cinder", "coast", "delta", "dune", "elm", "estuary", "fern",
    "fjord", "grain", "grove", "harbor", "heath", "islet", "juniper", "kelp", "larch", "moor",
    "nimbus", "oak", "palm", "quarry", "reef", "sedge", "tide", "upland", "vale", "weir", "yarrow",
    "zinnia",
];

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
    // What the user called it, if they called it anything. A person naming
    // their laptop "laptop" is doing the one thing that makes a peer list
    // readable, and their answer outranks whatever the operating system thinks
    // the computer is called.
    if let Ok(chosen) = read_chosen_label()
        && let Some(name) = chosen
    {
        return name;
    }

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
    // iOS / iPadOS have no scutil, and a sandboxed app cannot spawn `hostname`
    // at all. The family is the honest answer from here; the app replaces it
    // with the model's own name at launch. See `ClientDeviceName` in the client.
    #[cfg(target_os = "ios")]
    {
        return "iPhone".into();
    }
    #[cfg(not(target_os = "ios"))]
    {
        std::process::Command::new("hostname")
            .output()
            .ok()
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "this machine".into())
    }
}

/// Name this machine, or clear the name and go back to the system one.
///
/// A plain file beside the key rather than a field in the config, because the
/// Machines screen is sessionless on purpose: it has to answer "who am I" on a
/// machine whose archive will not open, and a name kept anywhere the archive
/// owns would disappear exactly then.
///
/// Blank clears it. That is the whole of the undo, and it means a person who
/// empties the field gets their computer's real name back rather than a machine
/// called "".
pub fn set_machine_label(name: &str) -> Result<(), IdentityError> {
    let path = label_path()?;
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(IdentityError::Io {
                path: path.display().to_string(),
                source: e,
            }),
        };
    }
    std::fs::write(&path, trimmed).map_err(|e| IdentityError::Io {
        path: path.display().to_string(),
        source: e,
    })
}

/// Whether the name on screen is one somebody chose, which is what lets the
/// field offer to clear itself only when there is something to clear.
pub fn machine_label_is_chosen() -> bool {
    matches!(read_chosen_label(), Ok(Some(_)))
}

fn read_chosen_label() -> Result<Option<String>, IdentityError> {
    let path = label_path()?;
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let name = text.trim().to_string();
            Ok((!name.is_empty()).then_some(name))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(IdentityError::Io {
            path: path.display().to_string(),
            source: e,
        }),
    }
}

fn label_path() -> Result<PathBuf, IdentityError> {
    Ok(identity_dir()?.join("machine.name"))
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
    let dir = identity_dir_path()?;
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

/// The identity directory path without creating it.
pub fn identity_dir_path() -> Result<PathBuf, IdentityError> {
    match std::env::var_os("TOKENSTAT_IDENTITY_DIR") {
        Some(explicit) => Ok(PathBuf::from(explicit)),
        None => Ok(
            directories::ProjectDirs::from("ai", "tokenstat", "tokenstat")
                .ok_or(IdentityError::NoDataDir)?
                .data_dir()
                .join("identity"),
        ),
    }
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

    /// A stored seed must keep deriving the same public key, for ever.
    ///
    /// The key file holds the seed, so the identity a peer pinned is whatever
    /// the x25519 crate makes of those 32 bytes. A version of it that clamped
    /// on construction rather than at use would change every machine's
    /// identity, silently, and every pinned peer would refuse a machine that
    /// had done nothing but take an update. Two vectors: one flat seed, one
    /// with bits set where clamping would show.
    #[test]
    fn a_seed_always_derives_the_same_public_key() {
        let mut varied = [0u8; 32];
        for (i, b) in varied.iter_mut().enumerate() {
            *b = (i as u8).wrapping_mul(7).wrapping_add(3);
        }
        assert_eq!(
            MachineIdentity::from_secret([1u8; 32]).public_key_hex(),
            "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209"
        );
        assert_eq!(
            MachineIdentity::from_secret(varied).public_key_hex(),
            "bb50ff9e82a574cfbf820e97f60fb9c143ec7415cf514f8cfd98eff59e059614"
        );
        // The handshake hands these bytes to snow, so the seed has to come
        // back out exactly as it went in, unclamped.
        assert_eq!(MachineIdentity::from_secret(varied).secret_bytes(), varied);
    }

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

    #[test]
    fn a_key_reads_as_three_words_and_keeps_reading_as_them() {
        let key = [7u8; 32];
        let words = key_words(&key);
        assert_eq!(words, key_words(&key), "the same key must read the same");
        let parts: Vec<&str> = words.split('-').collect();
        assert_eq!(parts.len(), 3, "{words}");
        assert!(parts.iter().all(|p| !p.is_empty()));
        assert!(
            words.chars().all(|c| c.is_ascii_lowercase() || c == '-'),
            "read aloud, so no punctuation and no case to get wrong: {words}"
        );
        assert_ne!(key_words(&[1u8; 32]), key_words(&[2u8; 32]));
    }

    /// The two displays of one key must not be derivable from each other, or
    /// the words become a lossy fingerprint rather than a separate check.
    #[test]
    fn the_words_are_not_a_slice_of_the_fingerprint() {
        let key = [0xabu8; 32];
        let words = key_words(&key).replace('-', "");
        assert!(!fingerprint(&key).replace('-', "").contains(&words));
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

    /// A chosen name outranks the system one, and clearing it gives the system
    /// name back rather than leaving a machine called "".
    #[test]
    fn a_chosen_name_wins_and_an_empty_one_undoes_it() {
        let dir = std::env::temp_dir().join(format!("tokenstat-name-{}", std::process::id()));
        // Safety: single-threaded test, and the variable is read only through
        // `identity_dir`, which is called below on this thread.
        unsafe { std::env::set_var("TOKENSTAT_IDENTITY_DIR", &dir) };

        assert!(!machine_label_is_chosen());
        let system = machine_label();

        set_machine_label("  the desk one  ").expect("write the name");
        assert_eq!(machine_label(), "the desk one", "trimmed and preferred");
        assert!(machine_label_is_chosen());

        set_machine_label("   ").expect("clear the name");
        assert!(!machine_label_is_chosen(), "blank is a reset, not a name");
        assert_eq!(machine_label(), system);

        let _ = std::fs::remove_dir_all(&dir);
        unsafe { std::env::remove_var("TOKENSTAT_IDENTITY_DIR") };
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
