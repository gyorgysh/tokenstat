#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Build-only dependency. The Cargo font step never installs packages or uses the network.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
venv="$root/target/linux-fonttools-4.68.0"
if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv"
fi
"$venv/bin/python" -m pip install --disable-pip-version-check --only-binary=:all: \
    --require-hashes --no-deps -r "$root/scripts/linux-fonttools-requirements.txt"
