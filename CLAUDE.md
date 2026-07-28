# CLAUDE.md

Guidance for Claude Code and other agents working in this repository.

## What this project is

`tokenstat` collects token usage from AI coding agents and LLM tools that write
local session logs, normalizes it into one schema, and reports spend by model,
project, tool, and time period. A separate, not yet started project serves
public profiles at `tokenstat.ai/<handle>`.

This repository contains the CLI, the shared core library, and later a Tauri
desktop GUI. It does not contain the website.

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
crates/tokenstat-core/   Parsing, normalization, pricing, aggregation
crates/tokenstat-cli/    Command line front end
crates/tokenstat-gui/    Tauri desktop app (planned, not present yet)
fixtures/                Redacted test data, committed
fixtures/local/          Real local data, git ignored
.github/workflows/       CI and release
```

Keep logic in `tokenstat-core`. Front ends should contain argument parsing,
formatting, and nothing else. Anything a GUI would also need belongs in the
core crate.

## Commands

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
cargo build --release
cargo run -p tokenstat-cli -- --help
```

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
- Every parser gets a fixture based test. Fixtures are redacted by hand.
- Public items get doc comments explaining why, not restating the signature.

## Data handling rules

These are product requirements, not preferences.

- Read only. Never write to, move, or delete a log file belonging to another
  tool.
- Nothing leaves the machine except through an explicit sync command the user
  ran, against an account the user created.
- Prompts, completions, file contents, and file paths from user projects are
  never eligible for sync. Only aggregate counts are.
- Never commit real session logs. Use `fixtures/local/` while working, and
  commit only redacted fixtures.
- Handle a missing or unreadable log directory as an empty result with a
  warning, not an error. Users will have only a subset of supported tools
  installed.

## Pricing

Model prices change. Keep them in versioned data, not in code, so a price update
is a data change with a date attached. Usage covered by a subscription is
reported as plan usage, separately from metered spend. Never present a plan
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
