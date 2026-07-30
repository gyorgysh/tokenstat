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
macOS binaries when Apple secrets are present, writes `SHA256SUMS`, and
publishes a GitHub Release. A tag containing a hyphen publishes as a prerelease.

### macOS signing (optional, recommended for public downloads)

Ad-hoc signing (`codesign --sign -`) is enough for local copies. Downloads from
the internet need a **Developer ID Application** certificate and notarization,
which require an [Apple Developer Program](https://developer.apple.com/programs/)
membership (paid, yearly).

1. Enrol in the Apple Developer Program.
2. Create a **Developer ID Application** certificate in
   [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
3. Export it as a `.p12` and base64-encode it for CI:
   `base64 -i developer-id.p12 | pbcopy`
4. Create an App Store Connect API key (Users and Access → Integrations →
   Team Keys) with access to notarization. Download the `.p8` and base64-encode
   it the same way.
5. GitHub setup (Settings):

- **Environment `release`**: required reviewers, deployment limited to tags
  `v*`. Used only by the early approval job. No secrets needed here.
- **Repository secrets** (Settings → Secrets and variables → Actions): the
  signing values below. They must be repository secrets so `publish` can read
  them without attaching the `release` environment again (which would ask for
  a second approval). If you previously stored them on the environment, copy
  them to repository secrets.

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | base64 of the `.p12` (`base64 -i cert.p12 \| pbcopy`, no line wraps) |
| `DEVELOPER_ID_P12_PASSWORD` | password used when exporting the `.p12` (no trailing newline) |
| `KEYCHAIN_PASSWORD` | throwaway password for the CI keychain |
| `DEVELOPER_ID_APP` | full identity, e.g. `Developer ID Application: Name (TEAMID)` |
| `TEAM_ID` | 10-character Team ID |
| `NOTARY_KEY_P8_BASE64` | base64 of the AuthKey `.p8` |
| `NOTARY_KEY_ID` | Key ID from App Store Connect |
| `NOTARY_ISSUER_ID` | Issuer UUID from App Store Connect |

The publish job re-exports the `.p12` into an Apple-compatible form before
`security import`. If import still fails, re-export the Developer ID cert from
Keychain Access, re-encode the file, and paste the password with no trailing
newline.

The release workflow asks for `release` approval right after the tag is
verified, before the build matrix starts. Builds only run once that is
approved. Publish does not wait for a second approval. If
`DEVELOPER_ID_P12_BASE64` is absent, the release still publishes unsigned
macOS binaries. Gatekeeper will warn on first open until signing is wired.
Notarization runs only when all three `NOTARY_*` secrets are set.

### Self-update

`tokenstat update` downloads the matching asset from GitHub Releases, verifies
`SHA256SUMS`, and replaces the running binary when the install path is writable
(for example `~/.local/bin`). Cargo and system paths are refused. Automatic
daily updates are on by default (schedule install persists that). Opt out with
`tokenstat update --auto off`, `"update":{"auto":false}` in config.json, or
`TOKENSTAT_AUTO_UPDATE=0`.

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
