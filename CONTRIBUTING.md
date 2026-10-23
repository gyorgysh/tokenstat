# Contributing

## Code contributions are not accepted

This repository does not take pull requests. Please do not open one: it will be
closed unread, which wastes your time and is a rude way to treat work somebody
did in good faith. Saying so here is the only way to prevent that.

**Issues are very welcome**, and are the most useful thing you can send:

- a harness tokenstat does not read yet, with the shape of its log files
- counts that disagree with what the tool itself reports, with both numbers
- a crash, or a parser that skips rows it should not
- anything in the privacy claim that does not match what the code does

Why closed. Every contributor keeps copyright in their work, so a merged patch
makes them a co-owner. tokenstat is shipped only by pueev OÜ, which is possible
precisely because pueev owns all of it. One merged patch would end that
permanently, and the rights cannot be collected afterwards.
The alternative is a contributor licence agreement, which is a real imposition
to place on someone fixing a typo.

So: the source is readable, the reports are open, and the door for patches is
shut on purpose. The whole repository is source-available and not open source:
read it, study it, fork it, build it, run your build. Publishing a copy or a
build is reserved. See `LICENSE`.

## Language

Everything in this repository is written in English: code, comments, commit
messages, branch names, issues, pull requests, and documentation.

## Branching

`main` is always releasable. CI must be green on `main` at all times.

Work happens on short lived branches, merged into `main` by pull request:

```
<type>/<short-description>
```

Examples: `feat/claude-code-parser`, `fix/windows-path-expansion`,
`docs/pricing-model`.

Rebase your branch on `main` before merging. Merges use squash, so the pull
request title becomes the commit on `main` and must follow the format below.

## Commit messages

Conventional Commits, always in English, always lowercase type.

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Types

| Type | Use for |
| --- | --- |
| `feat` | A new user facing capability |
| `fix` | A bug fix |
| `perf` | A change that improves performance without changing behavior |
| `refactor` | Restructuring that changes neither behavior nor performance |
| `docs` | Documentation only |
| `test` | Adding or correcting tests only |
| `build` | Build system, dependencies, packaging, release artifacts |
| `ci` | CI configuration and workflows |
| `chore` | Maintenance that fits nothing above, such as repo config |
| `revert` | Reverting a previous commit |

### Scopes

Optional, but preferred. Use the crate or area the change touches:

`core`, `cli`, `parser`, `pricing`, `report`, `sync`, `release`, `deps`, `ci`,
`host`, `windows`.

### Rules

- Subject in the imperative mood: "add windows path support", not "added" or
  "adds".
- Subject in lowercase, no trailing period, 72 characters or fewer.
- Body wrapped at 72 characters. Explain why the change was needed, not what
  the diff already shows.
- Breaking changes get a `!` after the type or scope, and a `BREAKING CHANGE:`
  footer explaining the migration.
- Reference issues in the footer: `Closes #12`.
- No tooling attribution of any kind, no session identifiers, no email
  addresses, no absolute local paths, no host names, no credentials.

### Examples

```
feat(parser): read codex session logs

Codex writes one jsonl file per session under a per project directory.
The reader walks that tree and emits the same normalized events as the
claude code reader, so aggregation stays shared.

Closes #14
```

```
fix(cli): expand tilde in --config on windows

Windows has no tilde expansion, so a config path copied from macOS docs
resolved to a literal directory named "~" and silently produced an empty
report.
```

```
refactor(core)!: split pricing out of the aggregator

BREAKING CHANGE: Aggregator::new no longer takes a PriceTable. Callers
build a Report first, then apply prices with Report::priced.
```

CI checks every commit in a pull request against this format. Fix violations by
rewriting the branch, not by adding a follow up commit.

The macOS build number in `apps/mac/project.yml` rides along with the next
functional commit. Never a standalone bump commit.

## CI scope and full validation

Quick source, localization, design and installer checks share one Ubuntu job;
each rule still has its own step and runs even when another rule fails.
`.github/ci-paths.yml` selects the remaining jobs from changed files. Rust
changes run tests on Linux, macOS and Windows and compile all native clients.
Client-only changes run that client's build and regressions. Documentation-only
changes run the source checks. Shared scripts and workflow changes deliberately
select broader validation. Chart renderer and SDK changes also select Linux
and Windows integration checks; the shared JSON contract selects Rust checks.
Portable terminal and hook regressions run in the shared Ubuntu job.

Preview defaults to `desktop` (Windows and Mac), including builds requested by
the `preview` PR label. Use the preview workflow's platform selector to build
Android, CLI or host artifacts, or choose `all` for the full preview matrix.

The iPhone/iPad UI suites, Android emulator tests, and Android release bundle
validation run Mondays at 03:23 UTC and through **Actions → ci → Run workflow**
with **full** enabled (the default). Run this before tagging a release that
changes clients. Full runs use a separate concurrency group so ordinary pushes
do not cancel them. Rust vulnerability auditing runs on dependency changes and
full runs. Chart dependency auditing runs on chart dependency changes and full
runs. Behavioral tests remain available; repeated mobile-feature Rust tests and
legacy wire checks run once on Linux instead of on multiple desktop runners.

For example, a Windows UI-only change uses three runner jobs rather than the old
27; an Apple UI change uses four, and a Rust change uses eight. A full manual
or scheduled run uses 14. Native Windows startup, terminal and H.264 playback
regressions remain automatic for Windows changes, including generation of the
encoder fixture they consume.

### Release build performance

The [v1.7.5 release](https://github.com/gyorgysh/tokenstat/actions/runs/39647798154)
took 64 minutes. The Mac app build accounted for 57: about 13 minutes building
FFI slices, 32 in Xcode, 11 building daemon slices, and 1½ compiling the notices
tool. Signing and notarization took only 2½ minutes. The preceding v1.7.4 Mac
build took 83 minutes. CI runs also consumed roughly 133–138 runner minutes
per push before component filtering and scheduled device tests.

The Mac FFI cache now shares a key and compiler flags with the main-branch CI
writer. Preview/release CLI and Windows packaging also share keys. Release
caches remain restore-only because
[tag-scoped writes cannot warm the next tag](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).
The first main-branch run after these changes must populate the new keys.
Keep PR cache writes disabled: the audit found the repository's 10 GB cache
budget already full, so adding large Xcode caches would displace useful Rust
and Gradle dependencies.

Mac packaging retains Release `-O` optimization and uses incremental Swift
compilation instead of whole-module optimization, allowing file compilation
in parallel and reuse of local DerivedData. This changes cross-file optimization
opportunities; compare runtime performance when profiling. Set
`TOKENSTAT_SWIFT_COMPILATION_MODE=wholemodule` for a comparison build. The FFI
profile uses 16 codegen units rather than one, and notices tools run in the dev
profile instead of paying for release LTO. Release assembly embeds the two
same-commit daemon binaries from the CLI matrix, removing another 11 minutes
of duplicate compilation from the Mac app job. Complete Xcode logs are retained
as artifacts, with build timing summaries printed in the job and step summary.

Local validation compiled the optimized ARM64 Mac app in 3 minutes 28 seconds
and the ARM64 FFI in 1 minute 22 seconds. These are single-architecture local
measurements, not a new universal GitHub runner baseline. A search-index
microbenchmark comparing `-O` with and without whole-module optimization kept
indexing near 260 ms and successful queries near 3–6 ms on a 10 MB corpus;
this does not measure every app code path. Measure the next hosted release
before setting a build-time target.

## Versioning

Semantic versioning. Until `1.0.0`, minor versions may break compatibility, and
breaking changes are still marked as described above.

### Cutting a release

The release workflow refuses to run if the tag and the manifest disagree, so
the version bump is its own commit on `main` before the tag:

```bash
# 1. Set the version in the workspace manifest. Both the workspace package
#    version and the tokenstat-core dependency requirement must change, and a
#    prerelease version has to be written in full, for example 0.1.0-rc.1,
#    because Cargo does not match a prerelease against a plain 0.1.0.
# 2. Refresh the lockfile, which CI verifies with --locked.
cargo generate-lockfile
cargo build --locked

git commit -am "build: set version to 0.1.0"
git push origin main

# 3. Tag once CI is green on main. The release workflow only runs on tag
#    pushes (not on commits to main). To re-run a failed release, move the
#    tag onto the same commit and push it again.
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

The workflow then builds all six targets, optionally signs and notarizes the
macOS binaries when Apple secrets are present on the `release` environment,
writes `SHA256SUMS`, and publishes a GitHub Release. A tag containing a hyphen
publishes as a prerelease. Release signing and environment setup are
maintainer-only; contributors do not need those secrets. GitHub asks for one
`release` environment approval after the builds and before signing or publishing.

### Self-update

`tokenstat update` downloads the matching asset from GitHub Releases, verifies
`SHA256SUMS`, and replaces the running binary when the install path is writable
(for example `~/.local/bin`). Cargo and system paths are refused. Automatic
daily updates are on by default. Opt out with `tokenstat update --auto off`.

## Before you open a pull request

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-features
```

Pull requests should be small enough to review in one sitting. Include tests for
behavior changes and update documentation in the same pull request.

## Privacy in test data

Never commit real session logs. They contain prompts and source code. Add
redacted, hand written fixtures under `fixtures/` instead. Anything under
`fixtures/local/` is ignored so you can keep real data locally while you work.
