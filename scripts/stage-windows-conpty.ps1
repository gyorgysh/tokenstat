# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Stage Microsoft's fixed-version terminal transport beside the host.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [ValidateSet("x64", "arm64")][string]$Arch = "x64"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Version = "1.25.260930003"
$PackageHash = "02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee"
$Cache = Join-Path $Root "target/conpty/$Version"
$Package = Join-Path $Cache "conpty.nupkg"
New-Item -ItemType Directory -Force -Path $Cache | Out-Null
if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
    $Download = "$Package.download"
    try {
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$Version/microsoft.windows.console.conpty.$Version.nupkg" -OutFile $Download
        if ((Get-FileHash -LiteralPath $Download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $PackageHash) {
            throw "ConPTY package checksum mismatch"
        }
        Move-Item -LiteralPath $Download -Destination $Package -Force
    } finally {
        if (Test-Path -LiteralPath $Download) { Remove-Item -LiteralPath $Download -Force }
    }
}
if ((Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant() -ne $PackageHash) {
    throw "Cached ConPTY package checksum mismatch"
}
$Hashes = @{
    x64 = @{
        "conpty.dll" = "feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a"
        "OpenConsole.exe" = "3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586"
    }
    arm64 = @{
        "conpty.dll" = "151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf"
        "OpenConsole.exe" = "4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f"
    }
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [IO.Compression.ZipFile]::OpenRead($Package)
try {
    foreach ($Name in @("conpty.dll", "OpenConsole.exe")) {
        $EntryPath = if ($Name -eq "conpty.dll") { "runtimes/win-$Arch/native/$Name" } else { "build/native/runtimes/$Arch/$Name" }
        $Entry = $Archive.GetEntry($EntryPath)
        if ($null -eq $Entry) { throw "ConPTY package is missing $EntryPath" }
        $Destination = Join-Path $Out $Name
        [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $Destination, $true)
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hashes[$Arch][$Name]) {
            throw "ConPTY $Name checksum mismatch"
        }
    }
} finally { $Archive.Dispose() }
@'
Microsoft Windows Console (ConPTY)
https://github.com/microsoft/terminal
Copyright (c) Microsoft Corporation. All rights reserved.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@ | Set-Content -LiteralPath (Join-Path $Out "CONPTY-LICENSE.txt") -Encoding utf8
Write-Host "Staged Microsoft ConPTY $Version ($Arch)"
