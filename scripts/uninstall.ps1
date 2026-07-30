#Requires -Version 5.1
<#
.SYNOPSIS
  tokenstat Windows uninstaller.

.DESCRIPTION
  Removes the hourly scan scheduled task, then the install directory under
  %LOCALAPPDATA%\tokenstat. Leaves the local archive alone unless you set
  TOKENSTAT_PURGE=1 (your scanned history, including usage coding tools have
  already deleted). Does not touch a hosted tokenstat.ai profile.

  Website one-liner:
    irm https://tokenstat.ai/uninstall.ps1 | iex

  Purge archive too:
    $env:TOKENSTAT_PURGE="1"; $env:TOKENSTAT_YES="1"; irm https://tokenstat.ai/uninstall.ps1 | iex

.NOTES
  Env overrides:
    TOKENSTAT_BIN_DIR   install directory (default: %LOCALAPPDATA%\tokenstat)
    TOKENSTAT_PURGE     1 = also delete the local data directory
    TOKENSTAT_YES       1 = non-interactive (needed with PURGE when no prompt)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

# Every scheduler entry tokenstat can install. All of them are removed whether or
# not this machine ever had them: a leftover task pointing at a deleted binary is
# the worst thing an uninstaller can leave behind.
$Labels = @("ai.tokenstat.scan", "ai.tokenstat.sync", "ai.tokenstat.update")
$BinDir = if ($env:TOKENSTAT_BIN_DIR) { $env:TOKENSTAT_BIN_DIR } else {
  Join-Path $env:LOCALAPPDATA "tokenstat"
}
# directories::ProjectDirs("ai","tokenstat","tokenstat").data_dir()
$DataDir = Join-Path $env:APPDATA "tokenstat\tokenstat\data"
$CacheDir = Join-Path $env:LOCALAPPDATA "tokenstat\tokenstat\cache"
$Purge = $env:TOKENSTAT_PURGE -eq "1"
$AutoYes = $env:TOKENSTAT_YES -eq "1"

function Say([string]$Msg) { Write-Host "• $Msg" -ForegroundColor Cyan }
function Ok([string]$Msg) { Write-Host "✓ $Msg" -ForegroundColor Green }
function Warn([string]$Msg) { Write-Host "! $Msg" -ForegroundColor Yellow }

function Confirm-No([string]$Prompt) {
  if ($AutoYes) { return $true }
  try {
    $ans = Read-Host "$Prompt [y/N]"
  } catch {
    return $false
  }
  if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
  return $ans -match "^[Yy]"
}

Write-Host ""
Say "uninstalling tokenstat"
Write-Host ""

# 1. Schedule first, so nothing runs a binary we are about to delete.
foreach ($Label in $Labels) {
  $task = Get-ScheduledTask -TaskName $Label -ErrorAction SilentlyContinue
  if ($task) {
    Say "removing scheduled task '$Label'"
    Stop-ScheduledTask -TaskName $Label -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName $Label -Confirm:$false -ErrorAction SilentlyContinue
    # Fallback if the cmdlets are restricted.
    & schtasks /Delete /TN $Label /F 2>$null | Out-Null
    Ok "$Label removed"
  } else {
    $sch = & schtasks /Query /TN $Label 2>$null
    if ($LASTEXITCODE -eq 0) {
      Say "removing scheduled task '$Label'"
      & schtasks /Delete /TN $Label /F | Out-Null
      Ok "$Label removed"
    } else {
      Say "no scheduled task '$Label' found"
    }
  }
}

# 2. Binary / install directory.
if (Test-Path -LiteralPath $BinDir) {
  Say "removing $BinDir"
  Remove-Item -LiteralPath $BinDir -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $BinDir) {
    Warn "could not fully delete $BinDir (file may be in use). Remove it after closing terminals."
  } else {
    Ok "binary removed"
  }
} else {
  Say "no install directory at $BinDir"
}

# User PATH entry pointing at the install dir (harmless if left).
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -and ($userPath -split ";" | Where-Object { $_ -eq $BinDir })) {
  if ($AutoYes -or (Confirm-No "Remove $BinDir from your user PATH?")) {
    $kept = ($userPath -split ";" | Where-Object { $_ -and ($_ -ne $BinDir) }) -join ";"
    [Environment]::SetEnvironmentVariable("Path", $kept, "User")
    Ok "removed $BinDir from user PATH"
  } else {
    Say "left PATH entry in place"
  }
}

# 3. Optional data purge.
if ($Purge) {
  $hasData = (Test-Path -LiteralPath $DataDir) -or (Test-Path -LiteralPath $CacheDir)
  if (-not $hasData) {
    Say "no local data directory found"
  } else {
    Warn "this deletes your local archive (usage your tools may already have purged)"
    Say "data: $DataDir"
    if (Test-Path -LiteralPath $CacheDir) { Say "cache: $CacheDir" }
    if (-not (Confirm-No "Delete local archive and cache?")) {
      if (-not $AutoYes) {
        Warn "purge skipped without confirmation (use TOKENSTAT_YES=1 with TOKENSTAT_PURGE=1 when piping)"
      }
      Say "left data in place"
    } else {
      if (Test-Path -LiteralPath $DataDir) {
        Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
        # Parent tokenstat\tokenstat may be empty now; remove empty parents carefully.
        $parent = Split-Path $DataDir -Parent
        if ((Test-Path $parent) -and -not (Get-ChildItem -Force $parent -ErrorAction SilentlyContinue)) {
          Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
          $grand = Split-Path $parent -Parent
          if ((Test-Path $grand) -and -not (Get-ChildItem -Force $grand -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $grand -Force -ErrorAction SilentlyContinue
          }
        }
        Ok "removed $DataDir"
      }
      if (Test-Path -LiteralPath $CacheDir) {
        Remove-Item -LiteralPath $CacheDir -Recurse -Force -ErrorAction SilentlyContinue
        Ok "removed $CacheDir"
      }
    }
  }
} elseif (Test-Path -LiteralPath $DataDir) {
  Say "left archive at $DataDir"
  Write-Host "  re-run with TOKENSTAT_PURGE=1 to delete it"
}

Write-Host ""
Ok "local install removed"
Write-Host "  hosted profile untouched — export or delete from /settings/data if needed"
Write-Host ""
