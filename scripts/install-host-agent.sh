#!/usr/bin/env bash
#
# Install the tokenstat host daemon as a launchd user agent.
#
# A user agent, not a process the app spawns. Automations are the reason: a job
# that stops when you close a window is not an automation. It also means one
# host per login session rather than one per client, so the app, the CLI and a
# future iPad all talk to the same archive through the same lock.
#
# User agent rather than a system daemon: it runs as you, reads your logs, and
# has no business existing before you log in or running as root.
#
# Usage:
#   scripts/install-host-agent.sh [path-to-tokenstat-hostd]
#   scripts/install-host-agent.sh --uninstall

set -euo pipefail

LABEL="ai.tokenstat.hostd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/tokenstat"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi

BIN="${1:-$HOME/.local/bin/tokenstat-hostd}"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN is not an executable" >&2
    echo "hint: cargo build --release -p tokenstat-host, then pass target/release/tokenstat-hostd" >&2
    exit 1
fi
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <!-- Restart if it dies, and start at login. The socket is how clients find
         it, so a host that is not running looks like a broken app. -->
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <!-- Interactive, not Background. The daemon owns live terminals the user
         types into; ProcessType=Background throttles the process tree and was
         measured at ~5s agent first paint vs ~0.3s for the same binary under a
         normal shell. Automations still run here, but the user's session is
         the reason this process exists. -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/hostd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/hostd.err.log</string>
</dict>
</plist>
PLIST_END

# bootout first so re-running this picks up a changed binary path rather than
# silently keeping the old one.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed $LABEL"
echo "  binary  $BIN"
echo "  logs    $LOG_DIR/hostd.err.log"
echo
echo "Stop with: scripts/install-host-agent.sh --uninstall"
