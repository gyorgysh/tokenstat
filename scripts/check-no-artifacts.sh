#!/usr/bin/env bash
#
# Fail if a build artifact, a large binary, or an internal note has been
# committed. Internal notes are docs/, tools/, WORKLOG.md, CLAUDE.md,
# TODO.md, and roadmap.md. .gitignore is not enough: a `!` un-ignore under
# /docs/ already put two files on GitHub.
#
# `.gitignore` is not enough, and this exists because it already failed once. A
# commit built while checked out at an older revision uses *that* revision's
# ignore rules, so a `git add -A` there happily swept in a generated Xcode
# project and a 30 MB static library. Nothing complained until someone looked.
#
# Git history is append-only in practice: removing a large blob afterwards means
# rewriting published history, which is exactly the mess this avoids.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Paths that are always generated and must never be tracked.
FORBIDDEN_PATHS='(\.xcodeproj/|\.xcworkspace/|/Vendor/|\.xcframework/|(^|/)DerivedData[^/]*/|(^|/)target/)'

# Extensions that are build output rather than source.
FORBIDDEN_EXTS='\.(a|o|so|dylib|dll|exe|rlib|rmeta|pdb|zip|tar|gz|dmg|pkg|msix|appx|jks|keystore)$'

# A source file this big is not a source file. Fixtures and images are checked
# by eye when added; this is a backstop against a binary nobody noticed.
MAX_BYTES=$((1024 * 1024))

failed=0

tracked="$(git ls-files)"

offenders="$(printf '%s\n' "$tracked" | grep -E "$FORBIDDEN_PATHS" || true)"
if [ -n "$offenders" ]; then
    echo "error: generated paths are tracked:" >&2
    printf '%s\n' "$offenders" | while IFS= read -r f; do printf '  %s\n' "$f" >&2; done
    failed=1
fi

offenders="$(printf '%s\n' "$tracked" | grep -E "$FORBIDDEN_EXTS" || true)"
if [ -n "$offenders" ]; then
    echo "error: build output is tracked:" >&2
    printf '%s\n' "$offenders" | while IFS= read -r f; do printf '  %s\n' "$f" >&2; done
    failed=1
fi

# Internal notes. Gitignored, and this is the backstop when a `!` un-ignore
# or an old checkout's rules put them on the index anyway. Two files under
# docs/ already leaked that way.
INTERNAL_PATHS='^(docs/|tools/|WORKLOG\.md|CLAUDE\.md|TODO\.md|roadmap\.md)'
offenders="$(printf '%s\n' "$tracked" | grep -E "$INTERNAL_PATHS" || true)"
if [ -n "$offenders" ]; then
    echo "error: internal notes are tracked:" >&2
    printf '%s\n' "$offenders" | while IFS= read -r f; do printf '  %s\n' "$f" >&2; done
    failed=1
fi

# Checked against the committed blob rather than the working file, so a file
# that is large in HEAD is caught even if it is small on disk right now.
big="$(git ls-files -z \
    | xargs -0 -I{} sh -c 'size=$(git cat-file -s "$(git rev-parse ":{}" 2>/dev/null)" 2>/dev/null || echo 0); [ "$size" -gt '"$MAX_BYTES"' ] && echo "$size {}"' \
    2>/dev/null || true)"
if [ -n "$big" ]; then
    echo "error: files over $((MAX_BYTES / 1024)) KB are tracked:" >&2
    printf '%s\n' "$big" | while IFS= read -r line; do printf '  %s\n' "$line" >&2; done
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    cat >&2 <<'MSG'

Add the path to .gitignore, then `git rm --cached` it. If it is already
published, the blob stays in history until that history is rewritten, so deal
with it now rather than later.
MSG
    exit 1
fi

echo "ok: no build artifacts, large binaries, or internal notes are tracked"
