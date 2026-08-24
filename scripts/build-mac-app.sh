#!/usr/bin/env bash
#
# Build Tokenstat.app for release.
#
# The Developer ID identity lives on the release environment and never reaches
# the build matrix, so on CI this produces an unsigned bundle and the publish
# job signs, notarizes and packages it.
#
# Locally it signs with Developer ID when this machine has one, because macOS
# keys a TCC grant to the code signature: an ad-hoc signature changes on every
# build, so every rebuild silently loses Screen Recording and Accessibility.
# With no identity present it still builds, unsigned, and says what that costs.
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

# The host helper is tokenstat-owned infrastructure, so the shipped app must
# carry it. The Machines screen installs this copy into the user's support
# directory and owns its launch agent; it never silently installs an external
# agent CLI.
# Universal, for the same reason the app is: the helper travels inside a bundle
# that runs on both kinds of Mac, and a host binary that has no slice for the
# machine it landed on cannot even be told apart from one that is missing.
echo "Building bundled tokenstat-hostd ($ARCHS)"
HOSTD_SLICES=()
for pair in "aarch64-apple-darwin:arm64" "x86_64-apple-darwin:x86_64"; do
    target="${pair%%:*}"
    arch="${pair##*:}"
    grep -qw "$arch" <<< "$ARCHS" || continue
    cargo build --release --locked --target "$target" -p tokenstat-host --bin tokenstat-hostd
    HOSTD_SLICES+=("$ROOT/target/$target/release/tokenstat-hostd")
done
lipo -create "${HOSTD_SLICES[@]}" -output "$APP/Contents/Resources/tokenstat-hostd"
chmod 755 "$APP/Contents/Resources/tokenstat-hostd"

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

# Sign with Developer ID when this machine has the identity.
#
# Not cosmetic. macOS keys a TCC grant to the code signature, and the ad-hoc
# signature this produces otherwise changes on every build, so every rebuild
# silently loses Screen Recording and Accessibility: the app looks the same and
# the screen never arrives. A real identity is stable across builds, so the
# grant survives.
#
# CI has no identity and stays unsigned, which is correct: the publish job is
# the only place that signs, notarizes and staples for release.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)"
if [ -n "$IDENTITY" ]; then
    echo "Signing with $IDENTITY"
    # The helper first, by hand, then the bundle with --deep. Same order and
    # the same reason as the publish job: the helper is a Mach-O executable
    # living in Resources, which codesign hashes as a resource rather than
    # signing as code, and the bundle embeds a Swift package's frameworks that
    # have to be signed before the outer seal goes on. A bundle signed over
    # unsigned nested code fails its own verification, and macOS will not hold
    # a TCC grant against a signature that does not validate, which would leave
    # this step doing nothing at all.
    # A secure timestamp, not --timestamp=none. Notarization rejects a
    # signature without one, and a local build that cannot be notarized is a
    # trap: it looks finished right up to the point somebody tries to ship or
    # install it on another Mac. It costs one round trip to Apple.
    codesign --force --options runtime --timestamp \
        --sign "$IDENTITY" "$OUT/Tokenstat.app/Contents/Resources/tokenstat-hostd"
    codesign --verify --strict --verbose=2 "$OUT/Tokenstat.app/Contents/Resources/tokenstat-hostd"
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" "$OUT/Tokenstat.app"
    codesign --verify --deep --strict --verbose=2 "$OUT/Tokenstat.app"
else
    echo "No Developer ID identity on this machine: leaving the app unsigned."
    echo "Screen Recording and Accessibility grants will be lost on each rebuild."
fi

echo "Wrote $OUT/Tokenstat.app"
