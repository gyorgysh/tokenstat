#!/usr/bin/env bash
#
# Build tokenstat-ffi into TokenstatFFI.xcframework for the Apple app.
#
# An xcframework rather than a plain static library because it is the artifact
# that gains iOS and simulator slices without the Xcode project changing: Xcode
# picks the right slice per destination. Today only the platforms whose Rust
# targets are installed get built, so a Mac-only checkout stays fast.
#
# Usage:
#   scripts/build-ffi-xcframework.sh                # macOS only
#   scripts/build-ffi-xcframework.sh macos ios sim  # everything installed
#
# Add the Rust targets first for anything beyond macOS:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A sandbox may export CARGO_TARGET_DIR elsewhere, which would leave the app
# linking a stale library from a previous run. Same trap as the CLI install.
unset CARGO_TARGET_DIR

# Match the app's deployment target from `apps/mac/project.yml`. Without this,
# Rust builds each object for whatever macOS the build machine runs, and the
# linker warns that a library built for 26.5 is being linked into a binary that
# claims to run on 14.0. The warning is the honest one: those objects are free
# to reference symbols a macOS 14 machine does not have.
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0

LIB="libtokenstat_ffi.a"
CRATE="crates/tokenstat-ffi"
HEADERS="$CRATE/include"
OUT="$ROOT/apps/mac/Vendor"
STAGE="$ROOT/target/xcframework"
FRAMEWORK="$OUT/TokenstatFFI.xcframework"

PLATFORMS=("${@:-macos}")

installed() { rustup target list --installed | grep -qx "$1"; }

# Build every installed target in a group, then lipo them into one library.
# Returns non-zero when the group has nothing installed, so the caller can skip
# the platform rather than fail the whole run.
build_group() {
    local name="$1"; shift
    local targets=("$@")
    local built=()

    for t in "${targets[@]}"; do
        if installed "$t"; then
            echo "  building $t"
            cargo build --profile release-ffi -p tokenstat-ffi --target "$t"
            built+=("target/$t/release-ffi/$LIB")
        else
            echo "  skipping $t (run: rustup target add $t)"
        fi
    done

    [ ${#built[@]} -gt 0 ] || return 1

    mkdir -p "$STAGE/$name"
    lipo -create "${built[@]}" -output "$STAGE/$name/$LIB"
    return 0
}

echo "Building TokenstatFFI for: ${PLATFORMS[*]}"
rm -rf "$STAGE" "$FRAMEWORK"
mkdir -p "$STAGE" "$OUT"

ARGS=()
for p in "${PLATFORMS[@]}"; do
    case "$p" in
        macos)
            echo "macOS:"
            build_group macos aarch64-apple-darwin x86_64-apple-darwin \
                && ARGS+=(-library "$STAGE/macos/$LIB" -headers "$HEADERS")
            ;;
        ios)
            echo "iOS device:"
            build_group ios aarch64-apple-ios \
                && ARGS+=(-library "$STAGE/ios/$LIB" -headers "$HEADERS")
            ;;
        sim)
            echo "iOS simulator:"
            build_group sim aarch64-apple-ios-sim x86_64-apple-ios \
                && ARGS+=(-library "$STAGE/sim/$LIB" -headers "$HEADERS")
            ;;
        *)
            echo "unknown platform: $p (expected macos, ios, or sim)" >&2
            exit 2
            ;;
    esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
    echo "nothing was built: no requested Rust target is installed" >&2
    exit 1
fi

xcodebuild -create-xcframework "${ARGS[@]}" -output "$FRAMEWORK" >/dev/null

# The linker failing on a missing symbol at app build time is a slow way to
# learn the profile dropped the export table, so check it here.
#
# The symbol list is captured before matching rather than piped into `grep -q`.
# Under `pipefail` the short-circuiting grep closes the pipe, nm dies of
# SIGPIPE, and the pipeline reports failure precisely when the symbol *was*
# found. That reads as a missing symbol and is a genuinely confusing half hour.
for slice in "$FRAMEWORK"/*/"$LIB"; do
    symbols="$(nm -gU "$slice" 2>/dev/null || true)"
    case "$symbols" in
        *_tokenstat_ffi_call*) ;;
        *)
            echo "error: tokenstat_ffi_call is missing from $slice" >&2
            echo "hint: the release-ffi profile must keep lto=false and strip=none" >&2
            exit 1
            ;;
    esac
done

echo "Wrote $FRAMEWORK"
