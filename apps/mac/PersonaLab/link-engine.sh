#!/usr/bin/env bash
#
# Point the lab at the app's persona engine.
#
# Symlinks, not copies. A lab that drifts from the thing it is tuning is worse
# than no lab: every number in it would have to be carried over by hand, and
# the one that was not is the one that ships.
set -euo pipefail
cd "$(dirname "$0")"

ENGINE="Sources/PersonaLab/Engine"
rm -rf "$ENGINE"
mkdir -p "$ENGINE"

for file in ../Sources/Design/Persona/*.swift; do
    ln -s "../../../$file" "$ENGINE/$(basename "$file")"
done

echo "linked $(ls "$ENGINE" | wc -l | tr -d ' ') engine files"
