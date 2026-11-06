# Contributing

## Contributions are welcome

Pull requests, bug reports, documentation fixes and translations are welcome.
Useful reports include unsupported tool log formats, incorrect counts,
crashes, and privacy behavior that differs from the documentation. Use redacted
examples; never submit private session logs.

You may fork the source on GitHub, change it, experiment, test locally, and
build and run your own version for personal or internal use. You do not need
to send us your changes. The limits on distributing builds and offering
services to others still apply.

If you want a change considered for tokenstat, open a pull request. PRs are
proposals. Maintainers may request changes, defer or decline them. Submission
does not guarantee review, merge, maintenance or inclusion in a future build.

## Contribution terms

Read [LICENSE, section 6](LICENSE) before submitting a contribution. You keep
any copyright you hold in your work and license it under the repository's
custom licence. You also grant pueev OÜ the additional rights stated there
to distribute and sublicense your contribution as part of tokenstat and its
derivative works,
including under future licence versions, commercial terms and app-store
terms. That additional grant is irrevocable and lets pueev OÜ ship the official
apps. You retain your copyright.

Confirm acceptance using the contribution-terms checkbox in the pull request
template. For a submission through another channel, explicitly state:
"I accept the contribution terms in section 6 of the tokenstat
Source-Available Licence, version 3, including the grant allowing pueev OÜ to
use, distribute and sublicense my contribution as part of tokenstat and its
derivative works under future licence versions or other terms, without
further approval or royalties. I have authority to grant these rights."

Maintainers must obtain that acceptance before merging or publishing a
preview build, including for submissions made before these terms were added. Acceptance must cover all contributed material,
including work from additional authors; a PR opener cannot grant others' rights.
The contribution grant takes effect when you submit work and accept the
terms, even if the PR is not merged. A fork or an issue report by itself does
not accept that grant.

Only submit work you have authority to license. Obtain employer permission
where required, and identify any third-party code, assets and licence terms.
Do not assume that publicly available code can be copied into this project.
Maintainers must review separately licensed material for compatibility.

You may share source forks and build and run your own version under
[LICENSE](LICENSE). Distribution of builds on any platform requires separate
written permission from pueev OÜ, even if you rename, rebrand or modify them.
Third-party hosted services also require separate written permission; personal
and internal hosting is allowed. The trademark policy grants no distribution
rights. See [TRADEMARK.md](TRADEMARK.md) and the
[licensing guide](LICENSING.md) for examples.

## Human, agent and bot submissions

The contributor is the person or entity authorized to grant rights, not the
account name of a bot. Using AI or automation does not itself establish that
anyone owns the output or has permission to copy third-party material.

| Submission | Required handling |
| --- | --- |
| Human-authored code, docs, translations or assets | Obtain acceptance from each relevant rights holder or an authorized representative; confirm employer rights where applicable |
| Human using an AI assistant | The responsible person accepts section 6 for rights they can grant, reviews the result, and discloses material AI assistance and known third-party sources in the PR |
| An autonomous agent opening a PR | Identify a responsible person or entity and obtain their recorded acceptance; an agent checking a box is insufficient |
| Maintainer automation acting for pueev OÜ | Record who authorized it, which accounts and tasks are covered, and the basis on which pueev OÜ can use the output |
| Dependabot or similar mechanical version/lockfile updates | A maintainer records that the diff is mechanical, identifies the bot, and reviews dependency licence changes; do not pretend the bot signed a contributor agreement |
| Bot changes that add code, assets, patches or other expressive material | Use the normal contributor or third-party licensing review; do not exempt it just because it is a bot |

A standing acceptance may cover repeated submissions by identified accounts or
automation under version 3. Keep the accepting person's identity, authority,
exact terms/version, scope, date and acceptance evidence in maintainer records.
Link the relevant record from the PR; keep private contracts and personal
information out of the public repository. New authors or material outside its
scope require their own clearance. Changing the licence used to distribute
accepted contributions does not require renewed acceptance: section 6(b)
already permits that. Changes to the contribution terms require acceptance
for future submissions under those changed terms. A conventional commit, Signed-off-by line,
GitHub username, bot label, or successful CI run is not a substitute.

For mechanical dependency updates, record the review basis, for example:
"Mechanical dependency update reviewed: version and lockfile changes only;
no new authored code or assets; dependency licence checks reviewed."
If there is any material requiring a grant, obtain that grant or use a
compatible existing licence. Dependabot does not grant rights to dependency
code; each dependency keeps its own licence. This rule also applies to actions,
vendor files, fonts, models and generated assets outside the Cargo graph.

## Maintainer acceptance and release review

Before merging, cherry-picking, directly committing an external submission,
or publishing its preview build:

- Verify acceptance and authority for every relevant rights holder, or record
  the applicable third-party licence or mechanical-update review basis.
- Review provenance and separately licensed material; retain required notices.
- Preserve the submission, reviewed commit, acceptance evidence and review
  decision. Do not check a contributor's acceptance box on their behalf.
- Review later commits for new authors or material outside existing acceptance.

Maintainers must check acceptance manually; the current CI does not enforce
it. The PR template records the contributor's confirmation.
Preview artifacts are distribution too. Only authorized pueev OÜ maintainers
may publish them after clearance. A fork may use private CI to build for its
own use under section 4, but may not publish downloadable build artifacts.

For already-merged material, a new licence or checkbox does not retroactively
obtain rights. Verify the existing grant or obtain one before distributing
that material under new terms. Authorship metadata alone does not prove that
pueev OÜ holds an individual's or employer's rights.

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
- Keep tooling attribution out of commit messages; required provenance and
  AI-assistance disclosures belong in the PR or maintainer acceptance record.
  No session identifiers, email addresses, absolute local paths, host names
  or credentials in commit messages.

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

To skip CI for a push to `main`, include `[skip]` in the tip commit's message.
All CI jobs are skipped for that push. Manual and scheduled runs ignore this
marker and keep their usual scope.

Preview defaults to `desktop` (Windows and Mac), including builds requested by
the `preview` PR label. Use the preview workflow's platform selector to build
Android, CLI or host artifacts, or choose `all` for the full preview matrix.

All component builds and Android release bundle validation run Mondays at
03:23 UTC and through **Actions → ci → Run workflow** with **full** enabled
(the default). Run this before tagging a release that changes clients. Full
runs use a separate concurrency group so ordinary pushes do not cancel them.
Rust vulnerability auditing runs on dependency changes and full runs.
Teams device UI suites, chart browser checks, and the Android chart/Teams
emulator suites are available for local validation and do not run in CI.
The Windows smoke suite skips Teams and chat chart UI checks in CI while
retaining its other native regressions. Repeated mobile-feature Rust tests and
legacy wire checks run once on Linux instead of on multiple desktop runners.

For example, a Windows UI-only change uses three runner jobs rather than the old
27; an Apple UI change uses four, and a Rust change uses eight. A full manual
or scheduled run uses 11. Native Windows startup, terminal and H.264 playback
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
