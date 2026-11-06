<!--
The title of this pull request becomes the commit on main, so it must follow
the Conventional Commits format from CONTRIBUTING.md, for example:

  feat(parser): read codex session logs
-->

## What changed

<!-- One or two sentences. -->

## Why

<!-- The problem this solves. Not a restatement of the diff. -->

## How to verify

<!-- Commands to run, or the manual steps a reviewer should follow. -->

## Contribution provenance

<!-- Identify additional authors, employer-owned work, material AI/agent
assistance and third-party sources/licences. For a bot PR, a maintainer must
record the responsible person/standing acceptance or mechanical-update
review basis described in CONTRIBUTING.md. Only the rights holder or an
authorized representative can accept the contribution grant. -->

## Checklist

- [ ] I accept the contribution terms in section 6 of the tokenstat
  Source-Available Licence, version 3 (`LICENSE`), including the grant allowing
  pueev OÜ to use, distribute and sublicense my contribution as part of tokenstat
  and its derivative works under future licence versions or other terms, without
  further approval or royalties. I have authority to grant these rights
- [ ] I identified other authors, third-party material and material AI/agent
  assistance, or linked the applicable standing acceptance/review record
- [ ] `cargo fmt --all` is clean
- [ ] `cargo clippy --all-targets --all-features -- -D warnings` is clean
- [ ] `cargo test --all-features` passes
- [ ] Tests cover the behavior change
- [ ] Documentation updated if commands or structure changed
- [ ] No real session logs, credentials, or personal paths in the diff
- [ ] Breaking changes are marked with `!` and a `BREAKING CHANGE:` footer
