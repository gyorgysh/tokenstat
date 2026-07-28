# tokenstat

Unified token usage stats for AI coding agents and LLM tools.

`tokenstat` reads the local session logs your AI tools already write, normalizes
them into one schema, and reports how many tokens you spent, on which models,
and what that usage was worth. It runs entirely on your machine by default. You
opt in explicitly if you want to sync a profile to tokenstat.ai.

> **Status: pre-alpha.** The repository currently holds project groundwork,
> tooling, and CI. The collector and reporting commands are in progress.

## Why

Every agent and assistant tracks usage in its own format, in its own directory,
behind its own dashboard. If you use several, you have no single answer to
"how much did I actually use this month, and what did it cost?".

`tokenstat` answers that question locally, then optionally turns it into a
public profile.

## What it will do

**Local CLI (free, offline)**

- Discover and parse session logs from supported AI tools
- Normalize input, output, cache read, and cache write tokens per model
- Price usage against current model rates, or against subscription limits when
  the tool is covered by a plan rather than metered billing
- Report by day, week, month, project, tool, and model
- Export to JSON and CSV for your own analysis

**Profile sync (opt in)**

- Publish a profile at `tokenstat.ai/<handle>`
- Contribution style activity map, model breakdown, and a synced timeline
- Leaderboards and social links

**Planned tiers**

| Tier | Includes |
| --- | --- |
| Free | Full local CLI, basic profile sync |
| Supporter | Extended history, richer profile themes, additional profile options |

The CLI stays free and functional without an account. Paid tiers only affect the
hosted profile.

## Architecture

The website is a separate project. This repository is the CLI, the shared core
library, and later the desktop GUI.

```
crates/
  tokenstat-core/   Parsing, normalization, pricing, aggregation. No I/O policy.
  tokenstat-cli/    Command line front end.
  tokenstat-gui/    Tauri desktop app (planned).
```

Keeping the logic in `tokenstat-core` means the CLI, the GUI, and any future
sync agent share one implementation.

## Install

Release builds are published as GitHub Releases for macOS (Apple silicon and
Intel), Windows, and Linux. A Homebrew tap and a Scoop manifest are planned once
the release format is stable.

From source:

```bash
cargo install --path crates/tokenstat-cli
```

## Usage

```bash
tokenstat --version
```

Command surface is under active design. See `docs/` as it lands.

## Development

Requires a recent stable Rust toolchain. The pinned version lives in
`rust-toolchain.toml`.

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
cargo build --release
```

## Privacy

`tokenstat` reads local log files. It sends nothing anywhere unless you run an
explicit sync command against an account you created. Log contents, prompts, and
code never leave your machine. Only aggregate counts are eligible for sync, and
you choose what a public profile exposes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branching model, commit message
format, and review process.

## License

To be decided before the first tagged release.
