# SSH, remote hosts, and Legend screen control

Each milestone lands as a separate commit after its focused tests, formatting,
clippy, and relevant client build pass. The final milestone reviews the whole
`v0.6.8..HEAD` range rather than only the last commit.

- [x] Slice 1: persisted SSH host/key-reference/snippet contracts and Apple bridge types
- [x] Slice 2: cross-platform SSH engine, host-key pinning, authentication callbacks, terminal sessions
- [x] Slice 3: SSH Hosts, Keys, and Snippets interface on Mac and iPhone/iPad
- [x] Slice 4: zero-knowledge vault crypto, recovery, record sync API, and paid entitlement
- [x] Slice 5: remote `tokenstat-hostd` packaging, CLI installer, service setup, workspace enrollment
- [ ] Slice 6: DigitalOcean read-only import
- [ ] Slice 7: AWS read-only EC2 import
- [ ] Slice 8: screen capability token and host permission policy
- [ ] Slice 9: macOS capture/control helper and encrypted video/input streams
- [ ] Slice 10: audio, display switching, clipboard, and resumable file transfer
- [ ] Slice 11: full verification, privacy/licence checks, and fixes
- [ ] Slice 12: code review and fixes for every commit in `v0.6.8..HEAD`
