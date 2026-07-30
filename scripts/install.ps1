#Requires -Version 5.1
<#
.SYNOPSIS
  tokenstat Windows installer.

.DESCRIPTION
  Downloads the matching GitHub Release zip into %LOCALAPPDATA%\tokenstat,
  verifies SHA256SUMS, adds the directory to the user PATH, and runs
  `tokenstat setup` (scan, hourly schedule, and a prompt to link an account
  when run on a TTY).

  Website one-liner:
    irm https://tokenstat.ai/install.ps1 | iex

  SmartScreen may warn once on unsigned GitHub Release EXEs. That is expected
  until Authenticode signing lands. Prefer Unblock-File (this script does it).

.NOTES
  Env overrides (set before irm | iex):
    TOKENSTAT_VERSION     pin a release (without leading v)
    TOKENSTAT_BIN_DIR     install directory
    TOKENSTAT_NO_SCHEDULE set to 1 to pass --no-schedule to setup
    TOKENSTAT_YES         set to 1 for non-interactive PATH edits
    GITHUB_TOKEN          optional, raises API rate limits
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

$Repo = "gyorgysh/tokenstat"
$BinDir = if ($env:TOKENSTAT_BIN_DIR) { $env:TOKENSTAT_BIN_DIR } else {
  Join-Path $env:LOCALAPPDATA "tokenstat"
}
$Version = if ($env:TOKENSTAT_VERSION) { $env:TOKENSTAT_VERSION.TrimStart("v") } else { "" }
$NoSchedule = $env:TOKENSTAT_NO_SCHEDULE -eq "1"
$AutoYes = $env:TOKENSTAT_YES -eq "1"

function Say([string]$Msg) { Write-Host "• $Msg" -ForegroundColor Cyan }
function Ok([string]$Msg) { Write-Host "✓ $Msg" -ForegroundColor Green }
function Warn([string]$Msg) { Write-Host "! $Msg" -ForegroundColor Yellow }
function Die([string]$Msg) { Write-Host "✖ $Msg" -ForegroundColor Red; exit 1 }

function Get-TargetTriple {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  switch ($arch) {
    "X64" { return "x86_64-pc-windows-msvc" }
    "Arm64" { return "aarch64-pc-windows-msvc" }
    default {
      # Older PowerShell: fall back to PROCESSOR_ARCHITECTURE
      switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { return "x86_64-pc-windows-msvc" }
        "ARM64" { return "aarch64-pc-windows-msvc" }
        default { Die "unsupported Windows arch: $arch / $($env:PROCESSOR_ARCHITECTURE)" }
      }
    }
  }
}

function Get-LatestVersion {
  if ($Version) { return $Version }
  $headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "tokenstat-install"
  }
  if ($env:GITHUB_TOKEN) {
    $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
  }
  $url = "https://api.github.com/repos/$Repo/releases/latest"
  $rel = Invoke-RestMethod -Uri $url -Headers $headers
  $tag = [string]$rel.tag_name
  if (-not $tag) { Die "could not read latest release tag from GitHub" }
  return $tag.TrimStart("v")
}

function Get-ExpectedSha([string]$SumsText, [string]$AssetName) {
  foreach ($line in ($SumsText -split "`n")) {
    $line = $line.Trim()
    if (-not $line) { continue }
    $parts = $line -split "\s+", 2
    if ($parts.Count -lt 2) { continue }
    $hash = $parts[0].ToLowerInvariant()
    $name = $parts[1].Trim().TrimStart("*")
    if ($name -eq $AssetName -or $name.EndsWith("/$AssetName") -or $name.EndsWith("\$AssetName")) {
      return $hash
    }
  }
  return $null
}

function Ensure-UserPath([string]$Dir) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }
  $parts = $userPath -split ";" | Where-Object { $_ }
  if ($parts -contains $Dir) {
    Say "$Dir already on user PATH"
    return
  }
  if (-not $AutoYes) {
    $ans = Read-Host "Add $Dir to your user PATH? [Y/n]"
    if ($ans -match "^[Nn]") {
      Warn "skip PATH edit; add $Dir manually"
      return
    }
  }
  $newPath = if ($userPath.TrimEnd(";")) { "$userPath;$Dir" } else { $Dir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  $env:Path = "$Dir;$env:Path"
  Ok "added $Dir to user PATH (open a new terminal)"
}

# --- main -------------------------------------------------------------------

$target = Get-TargetTriple
$ver = Get-LatestVersion
$asset = "tokenstat-$ver-$target.zip"
$archiveUrl = "https://github.com/$Repo/releases/download/v$ver/$asset"
$sumsUrl = "https://github.com/$Repo/releases/download/v$ver/SHA256SUMS"

Say "installing tokenstat v$ver ($target)"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tokenstat-install-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $zipPath = Join-Path $tmp $asset
  $sumsPath = Join-Path $tmp "SHA256SUMS"

  Say "downloading $asset"
  Invoke-WebRequest -Uri $archiveUrl -OutFile $zipPath -UseBasicParsing
  Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -UseBasicParsing
  Unblock-File -Path $zipPath -ErrorAction SilentlyContinue

  $sumsText = Get-Content -Raw -Path $sumsPath
  $want = Get-ExpectedSha -SumsText $sumsText -AssetName $asset
  if (-not $want) { Die "SHA256SUMS has no entry for $asset" }
  $got = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLowerInvariant()
  if ($got -ne $want) { Die "checksum mismatch: expected $want, got $got" }
  Ok "checksum ok"

  $extractDir = Join-Path $tmp "extract"
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
  $exeSrc = Get-ChildItem -Path $extractDir -Recurse -Filter "tokenstat.exe" |
    Select-Object -First 1
  if (-not $exeSrc) { Die "archive did not contain tokenstat.exe" }

  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  $dest = Join-Path $BinDir "tokenstat.exe"
  Copy-Item -Force -Path $exeSrc.FullName -Destination $dest
  Unblock-File -Path $dest -ErrorAction SilentlyContinue
  Ok "installed $dest"

  Ensure-UserPath -Dir $BinDir
  $env:Path = "$BinDir;$env:Path"

  Say "running setup (scan, schedule, optional account link)"
  $setupArgs = @()
  if ($NoSchedule) { $setupArgs += "--no-schedule" }
  if ($AutoYes) { $setupArgs += "--yes" }
  & $dest setup @setupArgs
  if ($LASTEXITCODE -ne 0) {
    Warn "setup reported an error (you can re-run: tokenstat setup)"
  }

  Write-Host ""
  Ok "tokenstat v$ver ready"
  Write-Host "  try:    tokenstat"
  Write-Host "  link:   tokenstat login"
  Write-Host "  check:  tokenstat doctor"
  Write-Host "  update: tokenstat update"
  Write-Host ""
}
finally {
  Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}
