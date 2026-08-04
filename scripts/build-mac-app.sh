#!/usr/bin/env bash
#
# Build Tokenstat.app for release, unsigned.
#
# Unsigned on purpose. The Developer ID identity lives on the release
# environment and never reaches the build matrix, so this produces the bundle
# and the publish job signs, notarizes and packages it. Running it locally gives
# the same bundle without needing a certificate.
#
# Usage:
#   scripts/build-mac-app.sh [version] [output-dir]
#
# The version is written into CFBundleShortVersionString, so a release tag names
# the build the user sees in About rather than whatever was last committed to
# project.yml.
#
# Needs xcodegen (brew install xcodegen). The Xcode project is generated, not
# committed: see apps/mac/project.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
OUT="${2:-$ROOT/dist}"

if [ -z "$VERSION" ]; then
    VERSION="$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)"
fi

# A sandbox may point this elsewhere and leave the app linking a stale library.
unset CARGO_TARGET_DIR

if ! command -v xcodegen > /dev/null; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

echo "Building TokenstatFFI (universal)"
"$ROOT/scripts/build-ffi-xcframework.sh" macos

echo "Generating the Xcode project"
(cd "$ROOT/apps/mac" && xcodegen > /dev/null)

DERIVED="$ROOT/target/xcode-release"
rm -rf "$DERIVED"

# Build only the architectures the Rust library actually has a slice for.
#
# A release must be universal, and CI installs both targets so it is. A checkout
# with only the host target installed would otherwise fail at the link step for
# the architecture it never built, which is a confusing way to learn that
# `rustup target add x86_64-apple-darwin` was missing.
INSTALLED="$(rustup target list --installed)"
ARCHS=""
for pair in "aarch64-apple-darwin:arm64" "x86_64-apple-darwin:x86_64"; do
    target="${pair%%:*}"
    arch="${pair##*:}"
    if grep -qx "$target" <<< "$INSTALLED"; then
        ARCHS="${ARCHS:+$ARCHS }$arch"
    fi
done
if [ -z "$ARCHS" ]; then
    echo "no Apple Silicon or Intel Rust target installed" >&2
    exit 1
fi
case "$ARCHS" in
    *" "*) ;;
    *) echo "warning: building $ARCHS only. A release needs both, run:" >&2
       echo "         rustup target add aarch64-apple-darwin x86_64-apple-darwin" >&2 ;;
esac

# CODE_SIGNING_ALLOWED=NO keeps the identity out of the build matrix entirely.
# The bundle is signed once, deep, in the publish job, which is also the only
# place that can staple a notarization ticket to it.
echo "Building Tokenstat.app $VERSION"
xcodebuild \
    -project "$ROOT/apps/mac/Tokenstat.xcodeproj" \
    -scheme Tokenstat \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build > /dev/null

APP="$DERIVED/Build/Products/Release/Tokenstat.app"
if [ ! -d "$APP" ]; then
    echo "no app bundle at $APP" >&2
    exit 1
fi

# The permissive dependencies ask that their notices travel with the binary, and
# a .app is a binary somebody receives. Inside Resources, so it cannot be
# separated from the thing it describes.
cargo run --release --locked -p xtask -- notices \
    "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md" tokenstat-cli

mkdir -p "$OUT"
rm -rf "${OUT:?}/Tokenstat.app"
# ditto rather than cp: a bundle has symlinks and extended attributes, and cp
# flattens both.
ditto "$APP" "$OUT/Tokenstat.app"

echo "Wrote $OUT/Tokenstat.app"
