# Security policy

## Reporting a vulnerability

Report security issues privately through GitHub Security Advisories on this
repository, under the Security tab. Do not open a public issue.

Please include what you found, how to reproduce it, and what an attacker could
achieve. You will get an acknowledgement within a few days.

## Scope

`tokenstat` reads local session logs that may contain prompts, source code, and
API responses. Issues that are especially relevant:

- Data from a log file being written anywhere it should not go
- Any network transmission that is not an explicit, user initiated sync
- Path traversal or symlink handling when discovering log directories
- Credentials or tokens ending up in output, cache files, or crash reports
- A parser being made to execute or evaluate content from a log file

## Supported versions

Before `1.0.0`, only the most recent release receives fixes.
