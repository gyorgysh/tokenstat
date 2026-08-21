#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/apps/android/app/src/main/jniLibs}"
command -v cargo-ndk >/dev/null || {
  echo "cargo-ndk is required: cargo install cargo-ndk" >&2
  exit 1
}
mkdir -p "$OUT"
cd "$ROOT"
cargo ndk --platform 28 --target arm64-v8a --target x86_64 \
  --output-dir "$OUT" build --profile release-ffi -p tokenstat-ffi --no-default-features
