#!/usr/bin/env bash
#
# Fast local macOS build for testing the GUI with the host daemon.
#
# Unlike build-mac-app.sh this keeps Xcode's derived data, builds one
# architecture, skips release packaging, and launches the Debug app.
# Signs with Developer ID when a matching profile is installed, so Touch ID
# works locally. TOKENSTAT_MAC_PROFILE can select a downloaded profile.
# The host daemon is still built with the release profile so it is quick to
# run and exercises the same local-host code as the packaged app.
#
# Usage:
#   scripts/build-mac-quick.sh              # Swift/UI changes
#   scripts/build-mac-quick.sh --rust       # refresh the FFI framework too
#
# The --rust form is needed when tokenstat-ffi or another Rust crate exposed
# through the FFI changes. Ordinary Swift changes do not need that rebuild.
# An iOS-only xcframework leftover from an archive still occupies this path,
# so the script also rebuilds when the macOS slice is missing, and when any
# Rust source is newer than the framework.
#
# Before launching it quits any running copy of the app and puts the new
# hostd in place under the launch agent. `open` on a running app only brings
# it forward, and the daemon outlives the app, so without this the old app
# and the old hostd kept answering after a build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A sandbox may export this elsewhere and leave hostd copied from a stale path.
unset CARGO_TARGET_DIR

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

# A directory at this path is not enough. build-ffi-xcframework.sh replaces
# the xcframework with only the platforms it was asked for, so an iOS or
# simulator run leaves no macOS slice here and xcodebuild fails with
# "no library for this platform".
ffi_has_macos() {
    [ -d "$FFI" ] || return 1
    [ -n "$(find "$FFI" -maxdepth 1 -type d -name 'macos-*' -print -quit)" ]
}

if [ "$refresh_rust" -eq 0 ] && ! ffi_has_macos; then
    echo "TokenstatFFI has no macOS slice, rebuilding"
    refresh_rust=1
fi

# The app and hostd must speak the same protocol, and hostd is rebuilt on
# every run. A framework older than any Rust source or manifest is a stale
# one, and the app then refuses the fresh hostd as "does not match".
ffi_is_stale() {
    [ -n "$(find "$ROOT/crates" "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" \
        \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
        -newer "$FFI" -print -quit 2> /dev/null)" ]
}

if [ "$refresh_rust" -eq 0 ] && ffi_is_stale; then
    echo "Rust sources changed since TokenstatFFI was built, rebuilding"
    refresh_rust=1
fi

if [ "$refresh_rust" -eq 1 ]; then
    echo "Building TokenstatFFI ($ARCH)"
    "$ROOT/scripts/build-ffi-xcframework.sh" macos
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
mkdir -p "$DERIVED"
LOG="$DERIVED/build-mac-quick.log"
if ! xcodebuild \
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
    build > "$LOG" 2>&1; then
    echo "xcodebuild failed" >&2
    if grep -E 'error:|fatal error:' "$LOG" >&2; then
        :
    else
        tail -n 80 "$LOG" >&2
    fi
    echo "full log: $LOG" >&2
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "no Debug app bundle at $APP" >&2
    exit 1
fi

echo "Building hostd"
cargo build --release --locked -p tokenstat-host --bin tokenstat-hostd
cp "$ROOT/target/release/tokenstat-hostd" \
    "$APP/Contents/Resources/tokenstat-hostd"
chmod 755 "$APP/Contents/Resources/tokenstat-hostd"

python3 "$ROOT/scripts/sign-mac-app.py" "$APP" --optional

# The Mac app, by its bundle layout. A simulator copy is also a process
# named Tokenstat, but it has no Contents/MacOS and is left alone.
mac_app_pids() {
    pgrep -f '/Tokenstat\.app/Contents/MacOS/Tokenstat$' || true
}

quit_running_app() {
    [ -n "$(mac_app_pids)" ] || return 0
    echo "Quitting the running app"
    osascript -e 'tell application id "ai.tokenstat.tokenstat" to quit' > /dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        [ -n "$(mac_app_pids)" ] || return 0
        sleep 0.2
    done
    echo "the app did not quit, stopping it"
    mac_app_pids | xargs kill 2> /dev/null || true
    sleep 1
}

# Install the signed helper from the bundle where the launch agent runs it,
# then restart the agent so the socket answers with this build. When no agent
# is loaded the app installs and starts one itself on launch.
deploy_hostd() {
    local support="$HOME/Library/Application Support/tokenstat/bin"
    local helper="$support/tokenstat-hostd"
    local service="gui/$(id -u)/ai.tokenstat.hostd"
    mkdir -p "$support"
    local staged="$support/.tokenstat-hostd-quick.$$"
    # -p keeps the bundle copy's date: the app compares size and date on
    # launch, and a fresh date would make it reinstall and restart hostd again.
    cp -p "$APP/Contents/Resources/tokenstat-hostd" "$staged"
    chmod 755 "$staged"
    mv -f "$staged" "$helper"
    if launchctl print "$service" > /dev/null 2>&1; then
        echo "Restarting hostd"
        if launchctl kickstart -k "$service"; then
            # This build is the one running, so a marker left by an earlier
            # failed install no longer asks the app for another restart.
            rm -f "$helper.restart-required"
        else
            echo "could not restart hostd, the app will start it" >&2
        fi
    fi
}

quit_running_app
deploy_hostd

echo "Launching $APP"
open "$APP"
echo "Ready: $APP"
