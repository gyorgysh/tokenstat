#!/bin/sh
# Third-party attribution for the Android build. The Cargo side is generated
# from the resolved dependency graph (see xtask notices), rooted at the crate
# whose closure ships in the app's .so; the rest are committed files appended
# here, the same arrangement the Mac build phase uses.
set -eu
OUT="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
cargo run -q -p xtask -- notices "$OUT" tokenstat-ffi
{
  printf '\n\n## xterm.js\n\nThe terminal emulator behind SSH and workspace shells.\n\n'
  cat "apps/android/app/src/main/assets/term/LICENSE-xterm.txt"
  printf '\n\n## Manrope\n\nBundled as the interface typeface.\n\n'
  cat "apps/android/app/src/main/res/raw/manrope_ofl.txt"
  printf '\n\n## JetBrains Mono\n\nBundled for terminals, code and identifiers.\n\n'
  cat "apps/android/app/src/main/res/raw/jetbrainsmono_ofl.txt"
  printf '\n\n'
  cat "apps/android/app/src/main/assets/licenses-gradle.md"
} >> "$OUT"
