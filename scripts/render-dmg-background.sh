#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Render the disk image background from its HTML source at 1x and 2x.
#
# Usage:
#   scripts/render-dmg-background.sh
#
# Run it after editing apps/mac/Installer/background.html and commit both PNGs.
# They are committed rather than rendered at release time so the release runner
# needs no browser, and so the image people download is the one that was
# reviewed. Needs Google Chrome.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/apps/mac/Installer"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "$CHROME" ]; then
    echo "Google Chrome not found at $CHROME (set CHROME to override)" >&2
    exit 1
fi

render() {
    local scale="$1" out="$2"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --window-size=660,400 --force-device-scale-factor="$scale" \
        --screenshot="$out" "file://$DIR/background.html" 2>/dev/null
}

render 1 "$DIR/background.png"
render 2 "$DIR/background@2x.png"

echo "Wrote $DIR/background.png and background@2x.png"
