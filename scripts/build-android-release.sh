#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Build an upload-key-signed release APK and Android App Bundle.
#
# The upload keystore is required. Source ~/.tokenstat/android/play.env, or
# run `scripts/android-play-keystore.sh init` first. An unsigned minified
# bundle is a local smoke test, not a Play upload.
#
# Usage:
#   scripts/build-android-release.sh [out-dir]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/android}"
ENV_FILE="${TOKENSTAT_ANDROID_ENV:-$HOME/.tokenstat/android/play.env}"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a && source "$ENV_FILE" && set +a
fi

if [ -z "${TOKENSTAT_ANDROID_KEYSTORE:-}" ] || [ ! -f "${TOKENSTAT_ANDROID_KEYSTORE}" ]; then
    echo "error: Play upload keystore is not available" >&2
    echo "hint: scripts/android-play-keystore.sh init" >&2
    exit 1
fi

for name in TOKENSTAT_ANDROID_STORE_PASSWORD TOKENSTAT_ANDROID_KEY_ALIAS TOKENSTAT_ANDROID_KEY_PASSWORD; do
    if [ -z "${!name:-}" ]; then
        echo "error: $name is required for release signing" >&2
        exit 1
    fi
done
export TOKENSTAT_ANDROID_STORE_PASSWORD

for tool in keytool jarsigner zip; do
    command -v "$tool" >/dev/null || {
        echo "error: $tool is required to verify and package the release" >&2
        exit 1
    }
done
if command -v sha256sum >/dev/null; then
    checksum=(sha256sum)
elif command -v shasum >/dev/null; then
    checksum=(shasum -a 256)
else
    echo "error: sha256sum or shasum is required" >&2
    exit 1
fi

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ] && [ -f "$ROOT/apps/android/local.properties" ]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' "$ROOT/apps/android/local.properties")"
fi
# Prefer the build tools for our compile SDK; allow an explicit override.
build_tools="${TOKENSTAT_ANDROID_BUILD_TOOLS:-$sdk/build-tools/36.0.0}"
for tool in apksigner zipalign; do
    if [ ! -x "$build_tools/$tool" ]; then
        echo "error: $tool is missing from Android build tools" >&2
        echo "hint: set ANDROID_HOME or TOKENSTAT_ANDROID_BUILD_TOOLS" >&2
        exit 1
    fi
done

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
expected_cert="$(
    keytool -J-Duser.language=en -J-Duser.country=US -list -v \
        -keystore "$TOKENSTAT_ANDROID_KEYSTORE" \
        -storepass:env TOKENSTAT_ANDROID_STORE_PASSWORD -alias "$TOKENSTAT_ANDROID_KEY_ALIAS" \
        | awk '/SHA256:/ { gsub(":", "", $2); print tolower($2); exit }'
)"
if [ -z "$expected_cert" ]; then
    echo "error: could not read the upload certificate" >&2
    exit 1
fi

command -v cargo-ndk >/dev/null || {
    echo "error: cargo-ndk is required: cargo install cargo-ndk --locked" >&2
    exit 1
}

cd "$ROOT"
apps/android/gradlew -p apps/android assembleRelease bundleRelease

src="$ROOT/apps/android/app/build/outputs/bundle/release/app-release.aab"
if [ ! -f "$src" ]; then
    echo "error: gradle did not write $src" >&2
    exit 1
fi

apk="$ROOT/apps/android/app/build/outputs/apk/release/app-release.apk"
if [ ! -f "$apk" ]; then
    echo "error: gradle did not write a signed release APK" >&2
    exit 1
fi

# JAR verification alone exits successfully even for unsigned archives. Require
# its verified result and reject unsigned entries as well as a different key.
jarsigner -J-Duser.language=en -J-Duser.country=US -verify "$src" > "$scratch/aab-verification.txt" 2>&1
if ! awk '/^jar verified\.$/ { ok = 1 } /contains unsigned entries/ { bad = 1 }
    END { exit !(ok && !bad) }' "$scratch/aab-verification.txt"; then
    echo "error: App Bundle signature verification failed" >&2
    exit 1
fi
aab_cert="$(
    keytool -J-Duser.language=en -J-Duser.country=US -printcert -jarfile "$src" \
        | awk '/SHA256:/ { gsub(":", "", $2); print tolower($2); exit }'
)"
"$build_tools/apksigner" verify --verbose --print-certs "$apk" > "$scratch/apk-verification.txt"
apk_cert="$(awk '/^Signer #1 certificate SHA-256 digest:/ { print $NF }' "$scratch/apk-verification.txt")"
if [ "$aab_cert" != "$expected_cert" ] || [ "$apk_cert" != "$expected_cert" ] || \
    ! awk '/^Number of signers: 1$/ { ok = 1 } END { exit !ok }' "$scratch/apk-verification.txt"; then
    echo "error: release artifacts must both use the expected upload key" >&2
    exit 1
fi
"$build_tools/zipalign" -c -P 16 4 "$apk" >/dev/null

mapping_dir="$ROOT/apps/android/app/build/outputs/mapping/release"
symbols="$ROOT/apps/android/app/build/outputs/native-debug-symbols/release/native-debug-symbols.zip"
if [ ! -s "$mapping_dir/mapping.txt" ] || [ ! -s "$symbols" ]; then
    echo "error: release R8 mapping or native debug symbols are missing" >&2
    exit 1
fi

version="$(
    awk -F'"' '/^[[:space:]]*versionName[[:space:]]*=/{ print $2; exit }' \
        "$ROOT/apps/android/app/build.gradle.kts"
)"
version_code="$(awk '/^[[:space:]]*versionCode[[:space:]]*=/ { print $3; exit }' "$ROOT/apps/android/app/build.gradle.kts")"
if [ -z "$version" ] || [ -z "$version_code" ]; then
    echo "error: Android version metadata is missing" >&2
    exit 1
fi
bundle_name="tokenstat-${version}-release.aab"
apk_name="tokenstat-${version}-release.apk"
symbols_name="tokenstat-${version}-${version_code}-symbols.zip"
package_dir="$scratch/package"
mkdir -p "$package_dir" "$scratch/symbols"
cp "$src" "$package_dir/$bundle_name"
cp "$apk" "$package_dir/$apk_name"
cp -R "$mapping_dir" "$scratch/symbols/mapping"
cp "$symbols" "$scratch/symbols/native-debug-symbols.zip"
(
    cd "$scratch/symbols"
    zip -qr "$package_dir/$symbols_name" mapping native-debug-symbols.zip
)
source_state=clean
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    source_state="uncommitted changes"
fi
cat > "$package_dir/release-info.txt" <<EOF
tokenstat Android $version ($version_code)
Commit: $(git rev-parse HEAD)
Source state: $source_state
Package: ai.tokenstat.tokenstat
Minimum SDK: 28; target SDK: 36
ABIs: arm64-v8a, x86_64
Rust: $(rustc --version)
Release: R8 minification and resource shrinking enabled.
Upload certificate SHA-256: $expected_cert
AAB signature and APK signature verified against the upload keystore.
APK 16 KB ZIP alignment verified.
AAB: for Google Play upload. No upload or publication was performed.
APK: for direct installation with the upload key; Play may use a different app signing key.
Symbols archive: R8 mappings and native debug symbols for this build.
Production acceptance checks: apps/android/PARITY.md and apps/android/PLAY_RELEASE.md.
EOF
(
    cd "$package_dir"
    "${checksum[@]}" "$bundle_name" "$apk_name" "$symbols_name" release-info.txt > SHA256SUMS
)
mkdir -p "$OUT"
cp "$package_dir/$bundle_name" "$package_dir/$apk_name" "$package_dir/$symbols_name" \
    "$package_dir/release-info.txt" "$package_dir/SHA256SUMS" "$OUT/"

echo "Verified upload certificate SHA-256: $expected_cert"
echo "$OUT/$apk_name"
echo "$OUT/$bundle_name"
echo "$OUT/$symbols_name"
echo "$OUT/SHA256SUMS"
