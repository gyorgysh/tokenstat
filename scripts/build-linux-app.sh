#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Build a reviewable development bundle. Installation and publication are separate.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if [ "$(uname -s)" != Linux ]; then
    echo "Build Linux desktop bundles on Linux. Use apps/linux for a macOS GUI preview." >&2
    exit 1
fi
case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "This prototype bundles x86_64 and aarch64 only." >&2; exit 1 ;;
esac

build_dir="$root/target/linux-desktop"
bash scripts/prepare-linux-fonts.sh
bash scripts/check-dep-licences.sh --manifest-path apps/linux/Cargo.toml --locked
cargo build --release --manifest-path apps/linux/Cargo.toml --locked --target-dir "$build_dir"
cargo build --release --locked -p tokenstat-host --bin tokenstat-hostd --target-dir "$build_dir"
cargo build --locked -p xtask --target-dir "$build_dir"

version="$("$build_dir/release/tokenstat-linux" --version | awk '{print $3}')"
host_version="$("$build_dir/release/tokenstat-hostd" --version | awk '{print $2}')"
if [ "$version" != "$host_version" ]; then
    echo "The desktop and host versions disagree. Refusing to stage a mixed bundle." >&2
    exit 1
fi
bundle="$root/dist/tokenstat-$version-linux-$arch-desktop-dev"
if [ -e "$bundle" ]; then
    echo "Bundle already exists: $bundle. Move it aside before rebuilding." >&2
    exit 1
fi
mkdir -p "$bundle/bin"
install -m755 "$build_dir/release/tokenstat-linux" "$bundle/bin/tokenstat-desktop"
install -m755 "$build_dir/release/tokenstat-hostd" "$bundle/bin/tokenstat-hostd"
"$bundle/bin/tokenstat-desktop" --stage-integration "$bundle" --installed-bin /usr/bin
mkdir -p "$bundle/share/icons/hicolor/256x256/apps"
cp apps/mac/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-light-256.png \
    "$bundle/share/icons/hicolor/256x256/apps/ai.tokenstat.tokenstat.png"
cp LICENSE "$bundle/LICENSE"
cp apps/mac/Resources/Fonts/Manrope-OFL.txt "$bundle/Manrope-OFL.txt"
cp apps/mac/Resources/Fonts/JetBrainsMono-OFL.txt "$bundle/JetBrainsMono-OFL.txt"
cp apps/linux/README.md "$bundle/README.md"
cp apps/linux/PARITY.md "$bundle/PARITY.md"
(
    cd apps/linux
    "$build_dir/debug/xtask" notices "$bundle/THIRD-PARTY-NOTICES.md" tokenstat-linux
)
"$build_dir/debug/xtask" notices "$bundle/HOST-THIRD-PARTY-NOTICES.md" tokenstat-host
printf '%s\n' 'Private development build. Linux acceptance is pending.' > "$bundle/PREVIEW.txt"
echo "Development bundle: $bundle"
