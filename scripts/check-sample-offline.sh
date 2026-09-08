#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# The sample is a picture, and a picture cannot call anything.
#
# `ClientSampleStore` and `ClientSampleWorkspace` exist so somebody with no
# account standing, no machine and nothing bought can see what the product is.
# The moment either of them reaches the bridge, a peer or the network, it stops
# being a sample: it starts needing the thing it exists to stand in for, and it
# gains a way to write somewhere on somebody's behalf.
#
# So this is a rule rather than a habit. Add a call here and CI says no.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(
  "$root/apps/mac/Sources/Client/ClientSampleStore.swift"
  "$root/apps/mac/Sources/Client/ClientSampleWorkspace.swift"
)

# Anything that talks to the host, a peer, the account or the network.
forbidden='Bridge\.|ClientRemote\.|URLSession|AccountModel|SSHLibraryModel|ChatModel|\.write\(|FileManager'

status=0
for file in "${files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "missing: ${file#"$root"/}" >&2
    status=1
    continue
  fi
  # Comments explain the rule and name the things it forbids, so they are not
  # evidence of a call. Only real code counts.
  if grep -nE "$forbidden" "$file" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | grep -q .; then
    echo "${file#"$root"/} reaches outside the sample:" >&2
    grep -nE "$forbidden" "$file" | grep -vE '^\s*[0-9]+:\s*(//|///|\*)' | sed 's/^/    /' >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo >&2
  echo "The sample must stay a local fixture. Move real work to a real screen." >&2
  exit 1
fi
echo "The sample reaches nothing outside itself."
