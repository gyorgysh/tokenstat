#!/usr/bin/env bash
#
# The hostd scheduled task must start the helper hidden, and restart it when
# it crashes.
#
# hostd is a console binary, and a task action that runs it directly with an
# interactive logon principal opens a visible console window on every logon
# and every task start. The fix wrapped the action in a hidden powershell
# that starts it hidden; this guard stops either half of that shape from
# regressing to a direct execute, in the script or in the C# fallback.
#
# Restart on failure applies always, not only when always-on: hostd exits 0
# on intentional stops (owner lock gone, self update), and the scheduler only
# restarts nonzero exits, so gating the restart on always-on would leave real
# crashes unrestored on a laptop for no reason.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="scripts/install-host-task.ps1"
FALLBACK="apps/windows/Install/SelfInstall.cs"
fail=0

need() { # file, pattern, complaint
    if ! grep -q "$2" "$1"; then
        echo "$1: $3"
        fail=1
    fi
}

forbid() { # file, pattern, complaint
    if grep -q "$2" "$1"; then
        echo "$1: $3"
        grep -n "$2" "$1" | head -5
        fail=1
    fi
}

forbid "$SCRIPT" 'New-ScheduledTaskAction -Execute \$Bin' \
    "runs hostd as the task action, which opens a visible console window"
need "$SCRIPT" "WindowStyle Hidden" \
    "lost the hidden wrapper around the helper"
need "$SCRIPT" "Start-Process" \
    "lost the hidden wrapper around the helper"
# The fallback body itself must carry the hidden wrapper. A plain file check
# would pass on the uninstall helper, which hides an unrelated call.
if ! awk '/public static void RegisterHostTask/,/^    }$/' "$FALLBACK" | grep -q 'WindowStyle Hidden'; then
    echo "$FALLBACK: schtasks fallback lost the hidden wrapper around the helper"
    fail=1
fi

if ! sed -n '/\$settingsArgs = @{/,/^}/p' "$SCRIPT" | grep -q 'RestartCount'; then
    echo "$SCRIPT: crash restart must live in the base settings, not behind always-on"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "The hostd task starts hidden and restarts on failure."
fi
exit "$fail"
