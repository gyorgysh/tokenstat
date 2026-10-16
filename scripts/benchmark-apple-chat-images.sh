#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Opt-in native Release benchmark. Images stay local; output is aggregate JSON.
# Usage: scripts/benchmark-apple-chat-images.sh /path/to/fixtures [sample-limit]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "Usage: $0 /path/to/local/image/fixtures [sample-limit]" >&2
  exit 2
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Use the actual encoded-preview implementation, without importing ChatInbox's
# account, share or staging dependencies into this standalone benchmark.
python3 - "$root" "$work/ChatThumbnail.swift" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatInbox.swift').read_text()
start = source.index('enum ChatThumbnail {')
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
output.write_text('import Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n' + source[start:end])
PY
swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
  "$work/ChatThumbnail.swift" \
  "$root/apps/mac/Sources/Features/Workspaces/Chat/ChatImageDecode.swift" \
  "$root/scripts/benchmarks/AppleChatImages.swift" \
  -o "$work/AppleChatImages"
"$work/AppleChatImages" "$1" "${2:-64}"
