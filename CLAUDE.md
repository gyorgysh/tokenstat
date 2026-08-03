# CLAUDE.md

Guidance for Claude Code and other agents working in this repository.

## What this project is

`tokenstat` collects token usage from AI coding agents and LLM tools that write
local session logs, normalizes it into one schema, and reports spend by model,
project, tool, and time period. A separate, not yet started project serves
public profiles at `tokenstat.ai/<handle>`.

This repository contains the CLI, the shared core library, and the MCP server.
It does not contain the website. Native desktop apps, if any, will come later
as separate clients over the core or CLI.

Source-available under `LICENSE`, not open source: readable and auditable, not
redistributable. The hosted service is separate.

## Start here

Two gitignored files hold the working context. Read both before making changes.

- `WORKLOG.md`: what is done, what is next, known ground truth for testing, and
  gotchas already hit. **Update it before you stop working**, especially if a
  task is half finished. Sessions end abruptly, and this file is what makes the
  next one able to continue.
- `roadmap.md`: research findings, the verified inventory of every log format on
  disk, and the design rationale.

## Stack

- Rust, stable toolchain pinned in `rust-toolchain.toml`
- Cargo workspace, one crate per concern
- GitHub Actions for CI and releases
- GitHub Releases for distribution, with a Homebrew tap and a Scoop manifest
  planned once the artifact format settles
- Cloudflare is the intended host for the website when that project starts. No
  Cloudflare configuration belongs in this repository.

## Layout

```
crates/tokenstat-core/   Parsing, normalization, pricing, aggregation. NO NETWORK.
crates/tokenstat-cli/    Command line front end
crates/tokenstat-sync/   The only crate allowed to link a network stack
crates/tokenstat-mcp/    MCP server over the core facade
crates/tokenstat-ffi/    C ABI bridge for native apps. JSON in, JSON out.
apps/mac/                SwiftUI universal app (macOS now, iOS/iPadOS later)
xtask/                   Fixture redaction, benches
fixtures/                Redacted test data, committed
fixtures/local/          Real local data, git ignored
.github/workflows/       CI and release
docs/                    Design plans: desktop-app.md, licensing.md
```

Inside the CLI, `render/` and `interactive/` are module directories, split by
what the reader is looking at rather than by widget type. `render/mod.rs` and
`interactive/mod.rs` hold only what their submodules share. Keep new output code
in the submodule that owns that screen.

Keep logic in `tokenstat-core`. Front ends should contain argument parsing,
formatting, and nothing else. Anything another client would also need belongs
in the core crate. Every front end goes through one facade, `Engine`, rather
than touching parsers or storage directly.
**Fixtures** under `fixtures/` are produced by `cargo xtask redact`. They keep
only allowlisted counter/id fields with pseudonymized values. They are safe to
commit. Never commit `fixtures/local/` or real session logs.

**`tokenstat-core` must never gain a network dependency**, directly or
transitively. This is not a style preference, it is the mechanism behind the
privacy claim. Anything that makes a request belongs in `tokenstat-sync`.

`scripts/check-no-network.sh` enforces this, in CI as the `privacy boundary`
job and runnable locally. It walks the resolved tree, so a transitive HTTP
client fails it exactly like a direct one. Guarded today: `tokenstat-core` and
`tokenstat-mcp`. Deliberately not guarded: `tokenstat-sync`, which is the one
crate allowed a network stack, and `tokenstat-ffi`, which depends on it so the
app can offer account and sync.

Add a crate to the `GUARDED` list when it should never make a request. Do not
remove one to make a build pass.

## Commands

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
cargo build --release
cargo run -p tokenstat-cli -- --help
```

### The Mac app

The Xcode project is generated from `apps/mac/project.yml` and is git ignored,
so both steps are needed on a fresh checkout. The build script must run first:
the app links the xcframework it produces.

```bash
scripts/build-ffi-xcframework.sh
cd apps/mac && xcodegen && xcodebuild -scheme Tokenstat -destination 'platform=macOS' build
```

The static library builds under the `release-ffi` profile, not `release`. That
profile exists because Rust's LLVM runs ahead of the one inside Xcode, and thin
LTO leaves metadata in the archive that Apple's tools reject with "Unknown
attribute kind". Do not point the script at `release` to save a rebuild.

Add iOS slices when that target starts:

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ffi-xcframework.sh macos ios sim
```

### Local install for manual testing

After a release build, copy the binary onto your PATH so you can run `tokenstat`
from any shell without `cargo run`.

**Agents: every job that changes the CLI must end with this install** (after
fmt/clippy/test), so the user can try the build immediately. Use unrestricted
permissions for the copy (`~/.local/bin` is outside the workspace).

**macOS exception:** if `~/.local/bin/tokenstat` already carries a real signing
identity (`codesign --display` shows `Authority=`), do **not** overwrite it and
do **not** ad-hoc `codesign --sign -` it. That path belongs to the official
Developer ID release from the website installer / `tokenstat update`. Test with
`cargo run` instead.

```bash
# Prefer the workspace target dir so a sandbox CARGO_TARGET_DIR does not
# leave you copying a stale binary.
unset CARGO_TARGET_DIR
cargo build --release -p tokenstat-cli
DEST="$HOME/.local/bin/tokenstat"
if [ "$(uname -s)" = "Darwin" ] && [ -f "$DEST" ] \
  && codesign --display --verbose=2 "$DEST" 2>&1 | grep -q '^Authority='; then
  echo "skipping: $DEST is Developer ID signed"
else
  mkdir -p ~/.local/bin
  cp -f target/release/tokenstat "$DEST"
  xattr -cr "$DEST" 2>/dev/null || true
  codesign --force --sign - "$DEST"
fi
```

Ensure `~/.local/bin` is on your `PATH`. On macOS, resign after `cp` so the
shell does not `SIGKILL` an ad-hoc binary (`zsh: killed`). If a full-screen
session is stuck, `pkill -x tokenstat` then `reset`.

Run format, clippy, and tests before proposing a change as finished. Clippy
warnings are errors in CI, so do not leave them for later.

## Conventions

### Commits

Conventional Commits, English, lowercase type, imperative subject. The full
specification with types, scopes, and examples is in
[CONTRIBUTING.md](CONTRIBUTING.md). CI rejects commits that do not match.

Never add tooling attribution, session identifiers, email addresses, absolute
local paths, host names, or credentials to a commit message, pull request body,
code comment, or any other published artifact.

### Writing style

Applies to code comments, documentation, commit messages, and user facing CLI
output.

- No em dashes. Use a comma, a colon, parentheses, or two sentences.
- Avoid semicolons in prose.
- Never call a computer a "box". Say server, machine, computer, laptop, or Mac,
  whichever is accurate.
- Plain words, short sentences, no filler.

### Code

- Prefer explicit types on public APIs, inference inside function bodies.
- Errors: `thiserror` for library crates, `anyhow` for the CLI binary. A parser
  that meets an unfamiliar log line should skip it and record a warning, not
  abort the run.
- No `unwrap` or `expect` outside tests and `main`.
- Every parser gets a fixture based test. Build fixtures with
  `cargo xtask redact`, which keeps an explicit allowlist of fields per source
  and drops everything else. Hand redaction does not scale to thousands of files
  and one miss publishes someone's code, so a CI guard also rejects any committed
  fixture containing path-shaped strings or unexpected keys.
- Public items get doc comments explaining why, not restating the signature.

## Data handling rules

These are product requirements, not preferences.

- Read only. Never write to, move, or delete a log file belonging to another
  tool.
- Nothing leaves the machine except through an explicit sync command the user
  ran, against an account the user created.
- Prompts, completions, file contents, and file paths from user projects are
  never eligible for sync. Only aggregate counts are.
- Drop conversation text at the parser boundary. Counters and identifiers go
  into the store, nothing else, so the local database holds numbers rather than
  conversations.
- Local vendor credentials may be discovered for convenience (Cursor /
  Antigravity keychain items the apps already store). Those tokens are used only
  on this machine to fetch aggregate usage, are never written into the archive,
  and are not eligible for sync. Where a vendor has no local credential, the
  user can still paste a token.
- Never commit real session logs. Use `fixtures/local/` while working, and
  commit only redacted fixtures.
- Handle a missing or unreadable log directory as an empty result with a
  warning, not an error. Users will have only a subset of supported tools
  installed.
- Where usage is genuinely unavailable, say so. Never report zero for a tool
  that simply does not expose counts.

### How to describe privacy

Be precise, because the claim is the product. The wording is:

> Everything happens on your machine. tokenstat reads your local logs, extracts
> counters, and discards the rest. Only aggregate numbers are eligible for sync.

Do not drift into "never reads prompts". Parsing a session log means opening a
file that contains prompts, so that phrasing is an overclaim. The guarantee is
the boundary, not the read.

Locally the tool is unrestricted: real project names, models, and session ids in
reports. Salted hashing applies to the sync payload only.

## Pricing

Do not host a price book in this repository. The CLI fetches a list-rate
snapshot from tokenstat.ai (`tokenstat pricing --refresh`) into the user's data directory.
`tokenstat-core` only reads that local snapshot. Usage covered by a subscription
is reported as plan usage, separately from metered spend. Never present a plan
figure as money charged.

## Releases

Tag `v<version>` on `main`. The release workflow builds every target and
publishes a GitHub Release. Do not create tags or push to `main` directly
without being asked.

## Working agreements

- Ask before adding a dependency that is large, unmaintained, or duplicates
  something already in the tree.
- Keep pull requests small and focused on one concern.
- Update `README.md` and this file when structure or commands change.
- If you find a real problem with a requested approach, say so briefly, then
  deliver the work under a stated assumption rather than stopping.
- Never name, cite, or compare against other products in source, docs, commits,
  or user-facing text. Early research was one-time context only.
