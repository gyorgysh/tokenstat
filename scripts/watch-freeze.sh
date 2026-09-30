#!/bin/sh
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Record what the whole Mac is doing every few seconds, to a file that
# survives a forced power-off.
#
# The app writes its own record (DiagnosticsLog, app-<day>.log). A freeze of
# the whole desktop can stop the app from writing, and the cause may be
# another process entirely, so this runs outside it. Each pass writes the
# free memory, the compressor, WindowServer, the tokenstat processes, and the
# processes using the most memory and CPU, then syncs the file.
#
#   scripts/watch-freeze.sh            # every 2 seconds, until Ctrl-C
#   scripts/watch-freeze.sh 5          # every 5 seconds
#   nohup scripts/watch-freeze.sh >/dev/null 2>&1 &   # in the background
#
# Files: ~/Library/Logs/tokenstat/system-<day>.log, kept for five days.

set -u
interval="${1:-2}"
case "$interval" in
    *[!0-9]*|'')
        echo 'interval must be a positive whole number of seconds' >&2
        exit 2
        ;;
esac
if ! [ "$interval" -gt 0 ] 2>/dev/null; then
    echo 'interval must be a positive whole number of seconds' >&2
    exit 2
fi
dir="$HOME/Library/Logs/tokenstat"
mkdir -p "$dir"
find "$dir" -name 'system-*.log' -mtime +5 -delete 2>/dev/null

# One process per line. The name is everything after the third column, since
# an app path can contain spaces.
row='{ name = $4; for (i = 5; i <= NF; i++) name = name " " $i
       printf "pid=%s mem_mb=%d cpu=%s %s\n", $1, $2 / 1024, $3, name }'

echo "writing to $dir/system-$(date +%F).log every ${interval}s"
while :; do
    log="$dir/system-$(date +%F).log"
    {
        echo "== $(date '+%F %T') $(memory_pressure -Q 2>/dev/null | tail -1)"
        vm_stat | awk '
            /page size of/ { page = $8 }
            /occupied by compressor/ { gsub("\\.", "", $5); printf "compressed_mb=%d ", $5 * page / 1048576 }
            /Swapouts/ { gsub("\\.", "", $2); printf "swapouts=%s", $2 }
            END { print "" }'
        ps -axo pid=,rss=,%cpu=,comm= | awk "$row" | grep -E 'WindowServer|Tokenstat|tokenstat-hostd' | sed 's/^/watch /'
        echo "top memory:"
        ps -axo pid=,rss=,%cpu=,comm= | sort -k2 -nr | head -6 | awk "$row" | sed 's/^/  /'
        echo "top cpu:"
        ps -axo pid=,rss=,%cpu=,comm= | sort -k3 -nr | head -4 | awk "$row" | sed 's/^/  /'
    } >>"$log" 2>/dev/null
    sync
    sleep "$interval"
done
