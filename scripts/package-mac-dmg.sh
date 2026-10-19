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
# The window carries the background in apps/mac/Installer, with the icons fixed
# where its arrow points. dmgbuild writes that layout straight into the image's
# .DS_Store, so it works on a headless runner where scripting Finder does not.
# It is installed into target/ from the pinned, hashed requirements on first use.
#
# Signing and notarization are the caller's, because the identity lives on the
# release environment. Sign the app before calling this, and sign, notarize and
# staple the image afterwards.

set -euo pipefail

APP="${1:?usage: package-mac-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
DMG="${2:?usage: package-mac-dmg.sh <app-bundle> <output.dmg> [volume-name]}"
VOLUME="${3:-tokenstat}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/apps/mac/Installer"

if [ ! -d "$APP" ]; then
    echo "no app bundle at $APP" >&2
    exit 1
fi

VOLUME_ICON="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$VOLUME_ICON" ]; then
    echo "no AppIcon.icns in $APP" >&2
    exit 1
fi

VENV="$ROOT/target/dmgbuild-venv"
if [ ! -x "$VENV/bin/python" ] || [ ! -x "$VENV/bin/pip" ]; then
    python3 -m venv "$VENV"
fi
if [ ! -x "$VENV/bin/dmgbuild" ] || ! cmp -s "$INSTALLER/requirements.txt" "$VENV/installed-requirements.txt"; then
    "$VENV/bin/pip" install --quiet --disable-pip-version-check \
        --require-hashes --only-binary :all: -r "$INSTALLER/requirements.txt"
    cp "$INSTALLER/requirements.txt" "$VENV/installed-requirements.txt"
fi

# Keep the finished image on the destination filesystem so the final rename
# replaces an earlier artifact atomically, including on external volumes.
DMG_DIRECTORY="$(cd "$(dirname "$DMG")" && pwd)"
STAGE="$(mktemp -d "$DMG_DIRECTORY/.tokenstat-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# ditto rather than cp: a bundle carries symlinks and extended attributes, and
# a signature does not survive cp flattening them.
ditto "$APP" "$STAGE/$(basename "$APP")"

# One TIFF holding both resolutions, so Finder picks the sharp one on Retina.
tiffutil -cathidpicheck "$INSTALLER/background.png" "$INSTALLER/background@2x.png" \
    -out "$STAGE/background.tiff" > /dev/null 2>&1

# hdiutil warns that each of its verbs is deprecated on every call. Drop those
# lines and keep anything else, with dmgbuild's own exit status.
set +e
"$VENV/bin/dmgbuild" \
    -s "$INSTALLER/dmg-settings.py" \
    -D app="$STAGE/$(basename "$APP")" \
    -D background="$STAGE/background.tiff" \
    -D volume_icon="$VOLUME_ICON" \
    "$VOLUME" "$STAGE/package.dmg" 2>&1 | grep -v "is deprecated"
status="${PIPESTATUS[0]}"
set -e
if [ "$status" -ne 0 ] || [ ! -f "$STAGE/package.dmg" ]; then
    echo "dmgbuild failed to write $DMG" >&2
    exit 1
fi
mv -f "$STAGE/package.dmg" "$DMG"

echo "Wrote $DMG"
