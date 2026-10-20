#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Build the production Teams views against fictional in-memory responses.
# No host, FFI, account login or credential storage is part of this executable.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:---build-only}"
if [[ "$mode" != "--build-only" && "$mode" != "--open" ]]; then
    echo "Usage: scripts/run-team-ui-fixture.sh [--build-only|--open]" >&2
    exit 2
fi
app="$root/target/teams-ui-fixture/TeamUIFixture.app"
source_root="$root/apps/mac/Sources"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/localization" "$root/target/teams-ui-fixture/ModuleCache"
sources=("$root/scripts/qa/teams/"*.swift "$source_root/Features/Teams/"*.swift)
for name in Theme AppFonts FlowLayout FeatureMark SyntaxKind Avatar AvatarImageDecode ActionIcon ThemedSheet SearchablePicker L10n NativeMenuTrigger; do
    sources+=("$source_root/Design/$name.swift")
done
sources+=("$source_root/App/SidebarContextClick.swift" "$source_root/Features/Work/WorkReference.swift" "$source_root/Bridge/JSONValue.swift")
swiftc -parse-as-library -swift-version 5 -module-cache-path "$root/target/teams-ui-fixture/ModuleCache" \
    -o "$app/Contents/MacOS/TeamUIFixture" "${sources[@]}"
cp -R "$root/apps/localization/." "$app/Contents/Resources/localization/"
cp "$root/apps/mac/Resources/Fonts/"*.ttf "$root/apps/mac/Resources/Fonts/"*-OFL.txt "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>ai.tokenstat.qa.teams</string>
<key>CFBundleExecutable</key><string>TeamUIFixture</string>
<key>CFBundleName</key><string>Teams UI fixture</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier ai.tokenstat.qa.teams "$app"
echo "Built isolated Teams fixture: $app"
if [[ "$mode" == "--open" ]]; then open -n "$app"; fi
