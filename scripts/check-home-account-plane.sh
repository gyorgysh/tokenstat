#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Home's recent places must render without contacting a machine.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for name in ClientHomeView ClientContinueSection ClientRecentPlaces; do
  file="$root/apps/mac/Sources/Client/$name.swift"
  [ -f "$file" ] || { echo "missing: $file" >&2; exit 1; }
  if sed '/^[[:space:]]*\/\//d; /ClientRemote.rawWorkspaceID(of: folder)/d' "$file" | grep -nE 'Bridge\.|URLSession|ChatModel|recentChats\(|ClientRemote\.' >/dev/null 2>&1; then
    echo "$name must not contact a machine" >&2
    exit 1
  fi
done
echo "Home's recent places need no awake machine."
