#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Build a Play-signed Android App Bundle.
#
# The upload keystore is required. Source ~/.tokenstat/android/play.env, or
# run `scripts/android-play-keystore.sh init` first. An unsigned minified
# bundle is a local smoke test, not a Play upload.
#
# Usage:
#   scripts/build-android-release.sh [out-dir]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/android}"
ENV_FILE="${TOKENSTAT_ANDROID_ENV:-$HOME/.tokenstat/android/play.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a && source "$ENV_FILE" && set +a
fi

if [ -z "${TOKENSTAT_ANDROID_KEYSTORE:-}" ] || [ ! -f "${TOKENSTAT_ANDROID_KEYSTORE}" ]; then
    echo "error: Play upload keystore is not available" >&2
    echo "hint: scripts/android-play-keystore.sh init" >&2
    exit 1
fi

command -v cargo-ndk >/dev/null || {
    echo "error: cargo-ndk is required: cargo install cargo-ndk --locked" >&2
    exit 1
}

cd "$ROOT"
apps/android/gradlew -p apps/android bundleRelease

src="$ROOT/apps/android/app/build/outputs/bundle/release/app-release.aab"
if [ ! -f "$src" ]; then
    echo "error: gradle did not write $src" >&2
    exit 1
fi

version="$(
    awk -F'"' '/^[[:space:]]*versionName[[:space:]]*=/{ print $2; exit }' \
        "$ROOT/apps/android/app/build.gradle.kts"
)"
mkdir -p "$OUT"
dest="$OUT/tokenstat-${version}-release.aab"
cp -f "$src" "$dest"

if command -v keytool >/dev/null; then
    echo "signed as:"
    keytool -printcert -jarfile "$dest" | awk '/Owner:|SHA256:/ { print "  " $0 }'
fi

echo "$dest"
