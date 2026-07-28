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

`core`, `cli`, `gui`, `parser`, `pricing`, `report`, `sync`, `release`, `deps`.

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

Releases are cut by pushing a `v<version>` tag on `main`. That triggers the
release workflow, which builds every target and publishes a GitHub Release.

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
