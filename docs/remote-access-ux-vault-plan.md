# Remote access, SSH vault, and UX release plan

Status: implementation in progress. This document is the release contract for the coordinated Apple, Android, Rust host, and tokenstat.ai work.

## Release gates

- [ ] macOS full-screen, zoom, split-view, display-change, and resize stress tests do not crash or mutate AppKit-owned view hierarchies.
- [ ] Screen access uses one wire spelling (`peerId`) and presents a readiness checklist plus a content-free access request flow.
- [ ] SSH has reliable back/close navigation, clear empty states, and guided Hosts, Keys, and Snippets creation.
- [ ] Host setup includes authentication choice, trust confirmation, and starting directory (default `~`).
- [ ] Incoming files default to `~/Downloads/tokenstat` on macOS, the Files-visible tokenstat folder on iOS, and `Downloads/tokenstat` on Android.
- [ ] Vault v2 syncs end-to-end encrypted SSH data across enrolled devices; tokenstat servers never receive plaintext, the master key, or the recovery phrase.
- [ ] New vaults use a random 256-bit master key and a 24-word checksummed BIP-39 recovery phrase. There is no operator reset or recovery.
- [ ] Existing local vaults use a guided, resumable migration and are not deleted until remote verification succeeds.
- [ ] Apple and Android support create, recover, enroll, revoke, sync, conflict merge, and export.
- [ ] tokenstat.ai exposes the ciphertext-only API, documents recovery honestly, and identifies Vault sync as Supporter+ and Screen as Legend.
- [ ] Existing-vault retrieval, export, and recovery remain available after a subscription downgrade.

## Vault v2 security and data model

1. Generate a random 32-byte vault master key (VMK).
2. Generate 256 bits of entropy and encode it as 24 standard BIP-39 English words with checksum.
3. Derive a recovery wrapping key with HKDF-SHA-256, a random salt, and versioned domain separation. Never store the phrase.
4. Encrypt snapshots and key wraps with XChaCha20-Poly1305. Bind account, vault, revision, schema, and recipient machine identifiers as associated data.
5. Wrap the VMK separately for recovery and for each enrolled device's existing X25519 identity. Keep the unwrapped VMK in Apple Keychain or an Android Keystore-wrapped local secret.
6. Store an encrypted item map containing hosts, portable credentials, snippets, settings, HLC/device identifiers, and tombstones. Agent references remain device-local.
7. Update snapshots with compare-and-swap revisions. On conflict, decrypt both versions, deterministically merge by HLC then device ID, re-encrypt, and retry.
8. Revoking a device rotates the VMK, re-encrypts the snapshot, and rewraps the new VMK for remaining devices and recovery.

Losing every enrolled device and the recovery phrase permanently loses the vault. A signed-in operator, support agent, or database administrator cannot recover it.

## Enrollment and migration

- A new device creates a 15-minute enrollment request tied to its account machine identity.
- An unlocked device approves the request and uploads only the target-device VMK wrap. Recovery can enroll a device without another device.
- Existing `ssh-vault.json`, host metadata, and Keychain credentials are detected before v2 creation. The migration preview identifies portable, device-local, and missing items.
- Migration uploads and reads back the encrypted snapshot before switching the local active-vault marker. The old vault is retained as a rollback backup until explicit cleanup.

## UX contract

- Every modal or separate viewer has an explicit styled close button and a bounded adaptive size.
- Hosts, Keys, and Snippets each have an explanatory empty state and one primary action.
- Add Host is a short wizard: Connection, Authentication, Verify host, Save. Passwords are never silently persisted.
- Vault setup offers Create new vault and Restore with recovery words. Recovery words are shown once, copy/print are explicit, screenshots are discouraged, and confirmation samples several word positions.
- Screen readiness lists plan, sign-in, pairing, online state, per-device grant, OS permissions, and destination. View-only does not request Accessibility.
- Remote requests contain no screen content. They open the host's permission card, where the user may allow once or remember view/control access.

## Validation matrix

- Rust: crypto vectors, malformed/corrupt payloads, migration, merge/tombstones, and zeroization-sensitive paths.
- Web: authentication, ownership, Supporter write entitlement, downgrade retrieval, CAS conflicts, enrollment expiry/replay, 4 MiB limit, rate limiting, export/delete cascade, and log redaction.
- Apple: unit/UI tests on smallest supported iPhone, iPad split view, compact and large macOS windows, VoiceOver labels, keyboard navigation, and repeated green-button/full-screen transitions.
- Android: equivalent vault/SSH/screen workflows, Keystore lifecycle, process death, rotation, TalkBack, MediaCodec/AudioTrack, and Storage Access Framework destinations.
- End to end: create on device A, enroll B, edit concurrently, recover C, revoke B, rotate recovery, downgrade, export, and account deletion.
