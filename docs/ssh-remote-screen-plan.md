# SSH, remote hosts, and Legend screen control

## Goal

Make tokenstat useful for managing servers and remote workspaces without
requiring users to understand SSH plumbing. The experience should follow the
existing tokenstat navigation and visual language on Mac, iPhone, and iPad.

The expansion has three connected parts:

1. A Termius-style SSH library for saved hosts, keys, and reusable snippets.
2. A CLI-installable host backend so a VPS or another computer can expose
   tokenstat workspaces without installing the desktop application.
3. Legend-only remote screen viewing and control, with no media encoding or
   decoding on tokenstat servers.

## Product boundaries

- Local SSH connections and device-local host metadata remain free.
- Encrypted credential synchronization and cloud inventory import require a
  paid plan.
- Existing remote host/workspace management remains Patron or higher.
- Screen viewing and control require Legend.
- Every host fingerprint must be shown and explicitly trusted before any
  credential is sent. A changed pinned fingerprint is a hard failure.
- Passwords and private keys never enter the plain host metadata file.
- Cloud integrations are read-only. Provider credentials are not retained in
  the host records.
- Screen access is disabled until the host grants the requesting device an
  explicit view or control permission.

## SSH library

The SSH screen uses three simple sections:

- **Hosts:** a friendly name, address, port, username, optional credential,
  jump host, tags, provider reference, and pinned host fingerprints.
- **Keys:** generated or imported private keys stored in the platform vault,
  plus ssh-agent, Touch ID/Secure Enclave, and FIDO-backed references where the
  platform supports them. Metadata contains public details and an opaque secret
  reference only. GPG management can extend this section later without mixing
  GPG secret material into SSH records.
- **Snippets:** named commands that can be inserted into a terminal and run
  only through an explicit action.

The shared Rust SSH engine uses `russh` rather than shelling out to
`/usr/bin/ssh`, so host verification, authentication, PTY resize, bounded
output, and mobile behavior share one implementation. Apple clients present
the live session with SwiftTerm.

## Credential vault

The synchronized vault is end-to-end encrypted. The client creates a
high-entropy 24-word recovery phrase and uses authenticated encryption for
vault records. tokenstat has no recovery endpoint or escrow key: losing every
enrolled device and the recovery phrase permanently loses vault access.

The storage/sync contract deals in versioned opaque encrypted records. Plain
passwords and private keys may exist only at an authorized endpoint while that
endpoint is using them. Device-local secrets use Keychain with
`WhenUnlockedThisDeviceOnly`; later platform signers can require user presence
for Touch ID, Secure Enclave, or FIDO credentials.

## Remote host installation

`tokenstat host` is the headless entry point. Preview mode explains what would
be installed; `tokenstat host --install` validates `tokenstat-hostd`, writes an
atomic per-user launchd or systemd service, activates it, optionally names the
device, and prints enrollment material.

This makes a small VPS usable without a GUI: install the CLI/daemon, enroll the
machine, register workspaces, then manage them from another computer or phone
through the existing authenticated and encrypted remote transport.

## Cloud inventory

Provider imports normalize servers into ordinary SSH host records so imported
and manually added servers behave identically afterward.

- DigitalOcean calls the read-only Droplets list with a token used for that
  request only. It records the Droplet id and region as provenance.
- AWS calls read-only `describe-instances` through an existing AWS CLI profile,
  so tokenstat does not collect AWS access keys. Terminated instances are
  ignored; the Name tag becomes the friendly label when present.
- DigitalOcean ships before AWS. Additional providers should use the same
  normalized host contract rather than creating provider-specific navigation.

## Legend screen architecture

Screen access uses two gates:

1. A persistent host policy explicitly grants a paired device view-only or
   view-and-control access. Control cannot be granted without view access.
2. A peer-bound, privilege-bound, short-lived capability token authorizes each
   session. Capability issuance also verifies the Legend entitlement.

The host endpoint captures with ScreenCaptureKit and encodes with
VideoToolbox. The viewing endpoint decodes locally. Video and input travel over
the existing encrypted direct transport when possible and fall back to the
encrypted relay path when direct connectivity fails. Relays only move bounded
encrypted packets; tokenstat servers do not encode, decode, or inspect media.

The first complete screen session includes adaptive bitrate/resolution,
backpressure that drops stale video frames instead of growing memory, pointer
and keyboard input, disconnect/reconnect behavior, visible session state, and
macOS Screen Recording/Accessibility permission guidance. Every device remains
independently revocable.

Conveniences follow only after the core screen path is safe and usable:

- display selection and switching;
- optional endpoint-encoded audio;
- automatic text-only clipboard synchronization (no automatic files/images);
- resumable, integrity-checked file transfer;
- direct/P2P preference with relay fallback and clear connection status.

## Delivery and verification

Each slice lands as a separate commit after focused tests, formatting, strict
clippy, privacy/action-icon checks, and the relevant client build. Generated
project files and notices are not committed. The final review covers the whole
`v0.6.8..HEAD` range, not only the last slice.

One known verification issue remains: Xcode builds succeed, but the notices
generator reports a non-fatal offline miss for the target-only `windows 0.62.2`
crate. Slice 11 must fetch/resolve it and verify the resulting licence notices
instead of suppressing the diagnostic.

## Roadmap

- [x] Slice 1: persisted SSH host/key-reference/snippet contracts and Apple bridge types
- [x] Slice 2: cross-platform SSH engine, host-key pinning, authentication callbacks, terminal sessions
- [x] Slice 3: SSH Hosts, Keys, and Snippets interface on Mac and iPhone/iPad
- [x] Slice 4: zero-knowledge vault crypto, recovery, record sync API, and paid entitlement
- [x] Slice 5: remote `tokenstat-hostd` packaging, CLI installer, service setup, workspace enrollment
- [x] Slice 6: DigitalOcean read-only import
- [x] Slice 7: AWS read-only EC2 import
- [x] Slice 8: screen capability token and host permission policy
- [ ] Slice 9: macOS capture/control helper and encrypted video/input streams
- [ ] Slice 10: audio, display switching, clipboard, and resumable file transfer
- [ ] Slice 11: full verification, privacy/licence checks, and fixes
- [ ] Slice 12: code review and fixes for every commit in `v0.6.8..HEAD`

## Commit checkpoints

- `0bd02f5` — persisted SSH connection records
- `5031bb1` — interactive SSH client sessions
- `08f6162` — Apple SSH connection manager
- `5eadda9` — encrypted credential vault
- `120bf77` — headless host service installer
- `3bc8986` — DigitalOcean Droplet import
- `228cee3` — AWS EC2 import
- `3d15a60` — explicit screen device capabilities
