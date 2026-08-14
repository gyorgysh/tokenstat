#!/usr/bin/env bash
#
# Install the tokenstat host daemon as a launchd user agent.
#
# A user agent, not a process the app spawns. Always-on host decides whether
# it outlives the app. Automations need that on a Mac that is meant to be
# reached with the window closed. A laptop defaults off so the helper cannot
# keep the machine reachable after quit.
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

IDENTITY_DIR="${TOKENSTAT_IDENTITY_DIR:-$HOME/Library/Application Support/ai.tokenstat.tokenstat/identity}"
HOST_JSON="$IDENTITY_DIR/host.json"
if [ -f "$HOST_JSON" ] && grep -q '"alwaysOn"[[:space:]]*:[[:space:]]*true' "$HOST_JSON"; then
    ALWAYS_ON=1
elif [ -f "$HOST_JSON" ]; then
    ALWAYS_ON=0
elif ioreg -r -c AppleSmartBattery -d 1 2>/dev/null | grep -q AppleSmartBattery; then
    ALWAYS_ON=0
else
    ALWAYS_ON=1
fi
if [ "$ALWAYS_ON" -eq 1 ]; then
    KEEP_ALIVE=true
else
    KEEP_ALIVE=false
fi
if [ ! -f "$HOST_JSON" ]; then
    mkdir -p "$IDENTITY_DIR"
    if [ "$ALWAYS_ON" -eq 1 ]; then
        printf '{\n  "alwaysOn": true\n}\n' > "$HOST_JSON"
    else
        printf '{\n  "alwaysOn": false\n}\n' > "$HOST_JSON"
    fi
    chmod 600 "$HOST_JSON"
fi

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
    <!-- KeepAlive and RunAtLoad follow Always-on host. Off on a battery
         Mac so the helper dies with the app. On for a mini, studio or pro.
         ProcessType stays Interactive either way: Background throttles
         terminals. It is not a sleep lock. -->
    <key>KeepAlive</key>
    <$KEEP_ALIVE/>
    <key>RunAtLoad</key>
    <$KEEP_ALIVE/>
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
# silently keeping the old one. RunAtLoad is off when Always-on is off, so
# kickstart after bootstrap or the helper never comes up.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "Installed $LABEL"
echo "  binary  $BIN"
echo "  logs    $LOG_DIR/hostd.err.log"
if [ "$ALWAYS_ON" -eq 1 ]; then
    echo "  host    always-on (starts at login)"
else
    echo "  host    app-lifetime (Always-on host is off)"
fi
echo
echo "Stop with: scripts/install-host-agent.sh --uninstall"
