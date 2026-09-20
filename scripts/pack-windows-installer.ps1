# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Wrap a published Tokenstat.exe folder in a branded Inno Setup installer.
# The wizard extracts to a temp directory and runs Tokenstat.exe --install.
#
# Usage:
#   scripts/pack-windows-installer.ps1 -StageDir dist/tokenstat-1.0.7-windows-x64 -Version 1.0.7 [-Out dist]

param(
    [Parameter(Mandatory = $true)]
    [string]$StageDir,
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$Out = "dist",
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$StageDir = (Resolve-Path -LiteralPath $StageDir).Path
$exe = Join-Path $StageDir "Tokenstat.exe"
$hostd = Join-Path $StageDir "tokenstat-hostd.exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "StageDir is missing Tokenstat.exe: $StageDir"
}
if (-not (Test-Path -LiteralPath $hostd -PathType Leaf)) {
    throw "StageDir is missing tokenstat-hostd.exe: $StageDir"
}

$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iscc) {
    throw "Inno Setup 6 is not installed (ISCC.exe not found). CI installs it with choco."
}

$work = Join-Path $env:TEMP ("tokenstat-inno-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$wizard = Join-Path $work "wizard.bmp"
$small = Join-Path $work "wizard-small.bmp"
$png = Join-Path $Root "apps\windows\Assets\tokenstat.png"
if (-not (Test-Path -LiteralPath $png -PathType Leaf)) {
    throw "Missing app icon PNG: $png"
}

Add-Type -AssemblyName System.Drawing
function Write-WizardBitmap([string]$Source, [string]$Dest, [int]$Width, [int]$Height) {
    $src = [System.Drawing.Image]::FromFile($Source)
    try {
        $bmp = New-Object System.Drawing.Bitmap $Width, $Height
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.Clear([System.Drawing.Color]::FromArgb(255, 251, 251, 253))
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $pad = [Math]::Min($Width, $Height) / 6
                $side = [Math]::Min($Width, $Height) - (2 * $pad)
                $x = [int](($Width - $side) / 2)
                $y = [int](($Height - $side) / 2)
                $g.DrawImage($src, $x, $y, [int]$side, [int]$side)
            } finally {
                $g.Dispose()
            }
            $bmp.Save($Dest, [System.Drawing.Imaging.ImageFormat]::Bmp)
        } finally {
            $bmp.Dispose()
        }
    } finally {
        $src.Dispose()
    }
}
Write-WizardBitmap $png $wizard 164 314
Write-WizardBitmap $png $small 55 55

$iss = Join-Path $Root "scripts\windows\tokenstat.iss"
$outDir = Join-Path $Root $Out
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$base = "tokenstat-$Version-windows-$Arch-setup"
$fileVersion = ($Version -split '-')[0]
if ($fileVersion -notmatch '^\d+\.\d+\.\d+$') {
    $fileVersion = "0.0.0"
}

& $iscc `
    "/DAppVersion=$fileVersion" `
    "/DFileVersion=$fileVersion" `
    "/DStageDir=$StageDir" `
    "/DOutputDir=$outDir" `
    "/DOutputBase=$base" `
    "/DSetupIcon=$Root\apps\windows\Assets\tokenstat.ico" `
    "/DLicenseFile=$Root\LICENSE" `
    "/DWizardImage=$wizard" `
    "/DWizardSmallImage=$small" `
    $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }

$setup = Join-Path $outDir "$base.exe"
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    throw "ISCC did not produce $setup"
}
Remove-Item -Recurse -Force $work
Write-Host "installer $setup"
Write-Output $setup
