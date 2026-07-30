# Contributing

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

`core`, `cli`, `parser`, `pricing`, `report`, `sync`, `release`, `deps`, `ci`.

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
