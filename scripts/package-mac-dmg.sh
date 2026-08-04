#!/usr/bin/env bash
#
# Wrap Tokenstat.app in a disk image with an Applications shortcut beside it.
#
# Usage:
#   scripts/package-mac-dmg.sh <app-bundle> <output.dmg> [volume-name]
#
# The drag-to-Applications layout is the one macOS users already know, and it is
# the reason this is a .dmg rather than a .zip: a zip unpacks wherever the
# download went, so the app ends up running from Downloads and every update
# leaves another copy behind.
#
# Signing and notarization are the caller's, because the identity lives on the
# release environment. Sign the app before calling this, and sign, notarize and
# staple the image afterwards.

set -euo pipefail

APP="${1:?usage: package-mac-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
DMG="${2:?usage: package-mac-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
VOLUME="${3:-tokenstat}"

if [ ! -d "$APP" ]; then
    echo "no app bundle at $APP" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto rather than cp: a bundle carries symlinks and extended attributes, and
# a signature does not survive cp flattening them.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" > /dev/null

echo "Wrote $DMG"
