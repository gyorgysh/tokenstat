#!/usr/bin/env bash
# Build a concise release body for softprops/action-gh-release.
#
# Usage: release-notes.sh <version> > notes.md
# The matching CHANGELOG section is deliberately the only source of release
# highlights. A release can follow hundreds of small commits; turning every
# subject into a bullet makes the GitHub page unusable as a download page.

set -euo pipefail

version="${1:?version required (no leading v)}"
tag="v${version}"
heading="## [${version}]"

notes="$(
  awk -v heading="$heading" '
    $0 == heading || index($0, heading " - ") == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
    END { if (!found) exit 1 }
  ' CHANGELOG.md
)" || {
  echo "CHANGELOG.md has no section for ${version}." >&2
  exit 1
}

# The emptiness test strips whitespace, so a section holding nothing but blank
# lines fails as loudly as one that is missing.
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md section for ${version} is empty." >&2
  exit 1
fi

cat <<EOF
## tokenstat ${tag}

tokenstat is CLI-first, local usage tracking for AI coding agents. Stable
downloads below include the CLI for macOS, Linux, and Windows, plus the macOS
desktop app and Windows desktop review build. Counters stay on your machine
unless you opt into sync.

### Install the CLI

\`\`\`bash
curl -fsSL https://tokenstat.ai/install.sh | bash
\`\`\`

Windows (PowerShell):

\`\`\`powershell
irm https://tokenstat.ai/install.ps1 | iex
\`\`\`

Or download an archive below, verify \`SHA256SUMS\`, and put \`tokenstat\` on your \`PATH\`.

### macOS desktop app

Download \`tokenstat-${version}-macos.dmg\` below, open it, and drag the app to
Applications.

### Windows desktop review build

Download \`tokenstat-${version}-windows-x64-setup.exe\` below and run the installer.
The Windows desktop is still a review build.

Unsigned desktop previews and Android debug APKs remain available from the
**Preview** workflow. Android Play uploads use a separately signed App Bundle;
this release workflow does not build or publish Android releases.

## What's changed
EOF

printf '%s\n\n' "$notes"
printf '[Full changelog](https://github.com/gyorgysh/tokenstat/blob/%s/CHANGELOG.md)\n' "$tag"
