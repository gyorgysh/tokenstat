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

## Checklist

- [ ] `cargo fmt --all` is clean
- [ ] `cargo clippy --all-targets --all-features -- -D warnings` is clean
- [ ] `cargo test --all-features` passes
- [ ] Tests cover the behavior change
- [ ] Documentation updated if commands or structure changed
- [ ] No real session logs, credentials, or personal paths in the diff
- [ ] Breaking changes are marked with `!` and a `BREAKING CHANGE:` footer
