# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Publish the unpackaged WinUI app plus hostd into a folder.
#
# Usage:
#   scripts/build-windows-app.ps1 [-Version 0.6.8] [-Rid win-x64] [-Out dist]
#
# Does not sign. Preview and a first Windows release ship unsigned.
# Authenticode comes later, read from the running binary like Developer ID.

param(
    [string]$Version = "",
    [string]$InformationalVersion = "",
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Rid = "win-x64",
    [string]$Out = "dist"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if (-not $Version) {
    $line = Select-String -Path (Join-Path $Root "Cargo.toml") -Pattern '^version\s*=' | Select-Object -First 1
    $Version = ($line.Line -split '"')[1]
}
if (-not $InformationalVersion) {
    $InformationalVersion = $Version
}

$Arch = if ($Rid -eq "win-arm64") { "arm64" } else { "x64" }
$RustTarget = if ($Rid -eq "win-arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }

Write-Host "hostd $RustTarget"
if ($Rid -eq "win-arm64") {
    rustup target add $RustTarget | Out-Null
}
cargo build --release --locked --target $RustTarget -p tokenstat-host --bin tokenstat-hostd

$Csproj = Join-Path $Root "apps\windows\Tokenstat.csproj"
$PublishDir = Join-Path $Root "apps\windows\bin\publish\$Rid"
if (Test-Path $PublishDir) {
    Remove-Item -Recurse -Force $PublishDir
}

Write-Host "dotnet publish $Rid $InformationalVersion"
dotnet publish $Csproj `
    -c Release `
    -r $Rid `
    --self-contained true `
    -o $PublishDir `
    -p:Platform=$Arch `
    -p:TokenstatVersion=$Version `
    -p:InformationalVersion=$InformationalVersion `
    -p:WindowsPackageType=None `
    -p:WindowsAppSDKSelfContained=true `
    -p:DebugType=none `
    -p:DebugSymbols=false

$hostd = Join-Path $Root "target\$RustTarget\release\tokenstat-hostd.exe"
if (-not (Test-Path $hostd)) {
    $hostd = Join-Path $Root "target\release\tokenstat-hostd.exe"
}
if (-not (Test-Path $hostd)) {
    throw "tokenstat-hostd.exe was not built"
}
Copy-Item $hostd (Join-Path $PublishDir "tokenstat-hostd.exe") -Force
Copy-Item (Join-Path $Root "scripts\install-host-task.ps1") (Join-Path $PublishDir "install-host-task.ps1") -Force
Copy-Item (Join-Path $Root "LICENSE") (Join-Path $PublishDir "LICENSE") -Force
Copy-Item (Join-Path $Root "README.md") (Join-Path $PublishDir "README.md") -Force
@(
    "tokenstat $InformationalVersion"
    "Double-click Tokenstat.exe to install for this user."
    "It copies itself to %LOCALAPPDATA%\Programs\tokenstat, adds a Start Menu shortcut, and registers the host helper."
    "pueev OÜ  https://tokenstat.ai"
) | Set-Content -Path (Join-Path $PublishDir "INSTALL.txt") -Encoding utf8

$notices = Join-Path $PublishDir "THIRD-PARTY-NOTICES.md"
cargo run --release --locked -p xtask -- notices $notices tokenstat-cli
Add-Content -Path $notices -Value @"

## Windows App SDK and .NET

This folder also contains a self-contained .NET 8 runtime and the Microsoft
Windows App SDK, redistributed under their MIT licenses.
See https://github.com/microsoft/WindowsAppSDK and https://github.com/dotnet/runtime.
"@

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$stageName = "tokenstat-$InformationalVersion-windows-$Arch"
$stage = Join-Path $Out $stageName
if (Test-Path $stage) {
    Remove-Item -Recurse -Force $stage
}
Copy-Item $PublishDir $stage -Recurse

Write-Host "staged $stage"
Write-Output $stage
