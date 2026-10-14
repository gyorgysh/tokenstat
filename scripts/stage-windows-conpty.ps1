# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Stage Microsoft's fixed-version terminal transport beside the host.
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [ValidateSet("x64", "arm64")][string]$Arch = "x64"
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Version = "1.24.260710001"
$PackageHash = "175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e"
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
        "conpty.dll" = "39fba2713e2495117b1591ae8c32a3b904bea7aa66069cf7815e2844c76d75d8"
        "OpenConsole.exe" = "b7fd936c2668b87b9ecf7b3366dc6568afc1c6f981874cba3e955a1c35cf8160"
    }
    arm64 = @{
        "conpty.dll" = "db3d173640b172bafd42d5b541b638a9aeec1c7d0e40dd636bf02822a32c912c"
        "OpenConsole.exe" = "ed7622fd0d3bedc9ab9f122f5e58edf0def9e7999224f52dd395ba9f54edbe09"
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
