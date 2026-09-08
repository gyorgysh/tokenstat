#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Run the client's standalone Swift tests.
#
# These are plain executables, not an XCTest bundle: each one compiles a small
# number of real app sources plus its own stubs and asserts against them. That
# is what makes them runnable in CI in seconds without a simulator, a signing
# identity or a generated Xcode project.
#
# Every test names the sources it needs in its own header comment, the way
# these files already did before anything ran them:
#
#     // Compile with ClientSetupState.swift and Foo.swift.
#
# The names are resolved under apps/mac/Sources, so a file that moves is found
# and a file that is deleted fails here rather than silently stopping being
# tested. Nothing in these tests touches an account, a network or a credential.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$root/apps/mac/Sources"
tests="$root/scripts/tests"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is not on this machine, so the Swift tests cannot run here." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failed=0
ran=0
for test in "$tests"/*Tests.swift; do
  name="$(basename "$test" .swift)"
  # The header names its sources. Two lines is the whole convention.
  wanted="$(head -4 "$test" | grep -oE '[A-Za-z0-9_]+\.swift' || true)"
  paths=()
  missing=""
  for file in $wanted; do
    found="$(find "$sources" -name "$file" -type f -print -quit)"
    if [ -z "$found" ]; then
      missing="$missing $file"
    else
      paths+=("$found")
    fi
  done
  if [ -n "$missing" ]; then
    echo "FAIL $name: named sources not found:$missing" >&2
    failed=1
    continue
  fi
  echo "== $name"
  if ! swiftc -parse-as-library -swift-version 5 -o "$work/$name" \
      "$test" "${paths[@]}" 2> "$work/$name.log"; then
    echo "FAIL $name: did not compile" >&2
    sed 's/^/    /' "$work/$name.log" >&2
    failed=1
    continue
  fi
  if ! "$work/$name"; then
    echo "FAIL $name" >&2
    failed=1
    continue
  fi
  ran=$((ran + 1))
done

if [ "$ran" -eq 0 ]; then
  echo "No Swift tests ran. That is a failure, not a pass." >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "$ran Swift test executables passed."
