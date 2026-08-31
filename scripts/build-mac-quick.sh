#!/usr/bin/env bash
#
# Fast local macOS build for testing the GUI with the host daemon.
#
# Unlike build-mac-app.sh this keeps Xcode's derived data, builds one
# architecture, skips release packaging/signing, and launches the Debug app.
# The host daemon is still built with the release profile so it is quick to
# run and exercises the same local-host code as the packaged app.
#
# Usage:
#   scripts/build-mac-quick.sh              # Swift/UI changes
#   scripts/build-mac-quick.sh --rust       # refresh the FFI framework too
#
# The --rust form is needed when tokenstat-ffi or another Rust crate exposed
# through the FFI changes. Ordinary Swift changes do not need that rebuild.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="${TOKENSTAT_MAC_ARCH:-arm64}"
PROJECT="$ROOT/apps/mac/Tokenstat.xcodeproj"
PROJECT_YML="$ROOT/apps/mac/project.yml"
FFI="$ROOT/apps/mac/Vendor/TokenstatFFI.xcframework"
DERIVED="$ROOT/target/xcode-debug"
APP="$DERIVED/Build/Products/Debug/Tokenstat.app"

refresh_rust=0
case "${1:-}" in
    "") ;;
    --rust) refresh_rust=1 ;;
    *)
        echo "usage: $0 [--rust]" >&2
        exit 2
        ;;
esac

if [ ! -d "$FFI" ]; then
    refresh_rust=1
fi

if [ "$refresh_rust" -eq 1 ]; then
    echo "Building TokenstatFFI ($ARCH)"
    TOKENSTAT_FFI_PLATFORMS=macos "$ROOT/scripts/build-ffi-xcframework.sh" macos
fi

if [ ! -d "$PROJECT" ] || [ "$PROJECT_YML" -nt "$PROJECT/project.pbxproj" ]; then
    command -v xcodegen > /dev/null || {
        echo "xcodegen is required: brew install xcodegen" >&2
        exit 1
    }
    echo "Generating the Xcode project"
    (cd "$ROOT/apps/mac" && xcodegen > /dev/null)
fi

echo "Building Debug Tokenstat ($ARCH)"
xcodebuild \
    -project "$PROJECT" \
    -scheme Tokenstat \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build > /dev/null

if [ ! -d "$APP" ]; then
    echo "no Debug app bundle at $APP" >&2
    exit 1
fi

echo "Building hostd"
cargo build --release --locked -p tokenstat-host --bin tokenstat-hostd
cp "$ROOT/target/release/tokenstat-hostd" \
    "$APP/Contents/Resources/tokenstat-hostd"
chmod 755 "$APP/Contents/Resources/tokenstat-hostd"

echo "Launching $APP"
open "$APP"
echo "Ready: $APP"
