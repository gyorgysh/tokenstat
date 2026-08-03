#!/usr/bin/env bash
# Build a release body for softprops/action-gh-release.
#
# Usage: release-notes.sh <version> > notes.md
# Expects a full git history (fetch-depth: 0) and HEAD at the tagged commit.

set -euo pipefail

version="${1:?version required (no leading v)}"
tag="v${version}"

prev="$(
  git tag -l 'v*' --sort=-v:refname \
    | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' \
    | grep -Fxv "$tag" \
    | head -n1 || true
)"

if [ -n "$prev" ]; then
  range="${prev}..HEAD"
  compared="Changes since ${prev}"
  subjects="$(git log --no-merges --format='%s' "$range")"
else
  compared="Initial public release"
  subjects="$(git log --no-merges --format='%s' HEAD)"
fi

section() {
  local title="$1"
  local pattern="$2"
  local lines
  lines="$(printf '%s\n' "$subjects" | grep -E "$pattern" || true)"
  if [ -z "$lines" ]; then
    return 0
  fi
  echo
  echo "### ${title}"
  echo
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Drop the conventional type/scope prefix for a cleaner bullet.
    clean="$(printf '%s' "$line" | sed -E 's/^[a-z]+(\([^)]+\))?[!:][[:space:]]*//')"
    echo "- ${clean}"
  done <<< "$lines"
}

cat <<EOF
## tokenstat ${tag}

Local token usage for AI coding agents. Counters stay on your machine unless you opt into sync.

### Install

\`\`\`bash
curl -fsSL https://tokenstat.ai/install.sh | bash
\`\`\`

Windows (PowerShell):

\`\`\`powershell
irm https://tokenstat.ai/install.ps1 | iex
\`\`\`

Or download an archive below, verify \`SHA256SUMS\`, and put \`tokenstat\` on your \`PATH\`.

### ${compared}
EOF

section "Features" '^(feat)(\(|:|!)'
section "Fixes" '^(fix)(\(|:|!)'
section "Documentation" '^(docs)(\(|:|!)'
section "Maintenance" '^(chore|ci|build|refactor|perf|test|style)(\(|:|!)'

# Anything that does not match a conventional prefix still belongs in the notes.
other="$(
  printf '%s\n' "$subjects" \
    | grep -Ev '^(feat|fix|docs|chore|ci|build|refactor|perf|test|style)(\(|:|!)' \
    || true
)"
if [ -n "$other" ]; then
  echo
  echo "### Other"
  echo
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "- ${line}"
  done <<< "$other"
fi

echo
echo "Full commit list and contributors are appended by GitHub below."
echo
