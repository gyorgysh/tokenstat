#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Assemble the app's universal helper from the same-run release CLI archives.
# Usage: scripts/embed-mac-hostd.sh Tokenstat.app archive-dir version
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 Tokenstat.app archive-dir version" >&2
    exit 2
fi
app="$1"
archives="$2"
version="$3"
test -d "$app/Contents/Resources"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

slices=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    archive="$archives/tokenstat-${version}-${target}.tar.gz"
    stage="$work/$target"
    mkdir -p "$stage"
    tar xzf "$archive" -C "$stage"
    helper="$stage/tokenstat-${version}-${target}/tokenstat-hostd"
    test -f "$helper" || { echo "no helper in $archive" >&2; exit 1; }
    slices+=("$helper")
done
# Only replace the embedded helper after both slices have been validated.
lipo -create "${slices[@]}" -output "$work/tokenstat-hostd"
lipo "$work/tokenstat-hostd" -verify_arch arm64
lipo "$work/tokenstat-hostd" -verify_arch x86_64
chmod 755 "$work/tokenstat-hostd"
mv -f "$work/tokenstat-hostd" "$app/Contents/Resources/tokenstat-hostd"
