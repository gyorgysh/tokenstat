#!/usr/bin/env bash
#
# The Windows zip runs with nothing installed.
#
# The app ships unpackaged and self-contained: the Windows App SDK travels in
# the folder next to the exe, so a person who unzips it is done. What this
# guard stops is the state it was in before, where the project asked for the
# self-contained binaries and for the framework-package bootstrapper in the
# same build. The bootstrapper runs first, looks for an installed Windows App
# Runtime, and puts up "This application requires the Windows App Runtime"
# with a Yes/No install prompt on a machine that was never meant to need one.
#
# Fails on:
#   - `WindowsAppSDKSelfContained` anything but true: the SDK would have to
#     come from an installed framework package instead of the app folder
#   - `WindowsAppSdkBootstrapInitialize` anything but false: the generated
#     `MddBootstrapInitialize` call demands the framework package at startup,
#     which is exactly the dialog above
#   - `WindowsPackageType` anything but None: v1 is unpackaged and per-user
#   - `SelfContained` anything but true: the .NET runtime ships in the folder
#   - a `MddBootstrap` call in C# sources: hand-written bootstrap does what
#     the generated one did
#   - the publish script re-enabling the bootstrapper behind the project file
#   - a packaged-identity API in C# or XAML sources: unpackaged means no
#     package identity, so `ApplicationData.Current` and `Package.Current`
#     throw. `RunNotifications` kept the launch switch in LocalSettings, which
#     killed every launch before any window existed, with no error anywhere.
#     Persist under %LOCALAPPDATA% with plain file APIs instead, the way the
#     rest of the app already does. (The `Windows.ApplicationModel` namespace
#     itself is fine: clipboard transfer lives there and works unpackaged.)
set -euo pipefail
cd "$(dirname "$0")/.."

CSPROJ="apps/windows/Tokenstat.csproj"
PUBLISH="scripts/build-windows-app.ps1"
fail=0

need() { # file, pattern, complaint
    if ! grep -q "$2" "$1"; then
        echo "$1: $3"
        fail=1
    fi
}

forbid() { # file, pattern, complaint
    if grep -q "$2" "$1"; then
        echo "$1: $3"
        grep -n "$2" "$1" | head -5
        fail=1
    fi
}

need "$CSPROJ" "<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>" \
    "must ship the Windows App SDK in the app folder (WindowsAppSDKSelfContained true)"
need "$CSPROJ" "<WindowsAppSdkBootstrapInitialize>false</WindowsAppSdkBootstrapInitialize>" \
    "must not initialize the framework-package bootstrapper (WindowsAppSdkBootstrapInitialize false)"
need "$CSPROJ" "<WindowsPackageType>None</WindowsPackageType>" \
    "must stay unpackaged (WindowsPackageType None)"
need "$CSPROJ" "<SelfContained>true</SelfContained>" \
    "must ship its own .NET runtime (SelfContained true)"

ISS="scripts/windows/tokenstat.iss"
PACK="scripts/pack-windows-installer.ps1"
need "$ISS" "AppName=tokenstat" \
    "installer product name must be tokenstat"
need "$ISS" "PrivilegesRequired=lowest" \
    "installer must stay per-user (no UAC)"
need "$ISS" "LicenseFile=" \
    "installer must show LICENSE"
need "$ISS" 'Parameters: "--install"' \
    "installer must run Tokenstat.exe --install rather than copy ARP itself"
need "$ISS" "Uninstallable=no" \
    "Inno must not write a second Add/Remove Programs row"
need "$PACK" "ISCC" \
    "pack script must compile the Inno script"
if grep -qiE 'open source' "$ISS" "$PACK"; then
    echo "installer copy must not call the product open source"
    fail=1
fi

forbid "$CSPROJ" "WindowsAppSdkBootstrapInitialize>true<" \
    "enables the bootstrapper that puts up the Windows App Runtime dialog"
forbid "$PUBLISH" "BootstrapInitialize.*true" \
    "re-enables the bootstrapper behind the project file"

if grep -rn "MddBootstrap" apps/windows --include='*.cs' --include='*.xaml' --include='*.xaml.cs' | grep -v "check-windows-packaging"; then
    echo "apps/windows: a hand-written MddBootstrap call demands the installed runtime"
    fail=1
fi

# Comment lines are skipped, so a comment may name the banned API while
# explaining why it is banned. A real call is never a comment.
hits=$(grep -rn -e "ApplicationData\.Current" -e "Package\.Current" apps/windows \
    --include='*.cs' --include='*.xaml' --include='*.xaml.cs' \
    | grep -v ':[0-9][0-9]*: *//' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "apps/windows: packaged-identity APIs throw in an unpackaged app (see above)"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "The Windows zip runs with nothing installed."
fi
exit "$fail"
