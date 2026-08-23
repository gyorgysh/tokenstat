# Install the tokenstat host daemon as a per-user scheduled task.
#
# A user task, not a Windows Service. Always-on host decides whether it
# outlives the app. Automations need that on a machine that is meant to be
# reached with the window closed. A laptop defaults off so the helper cannot
# keep the machine reachable after quit.
#
# User task rather than a service: it runs as you, reads your logs, and has no
# business existing before you log in or running as SYSTEM.
#
# The WinUI app holds host-owner.lock while it is open. A laptop default
# (alwaysOn false) then stops the helper after quit. Set alwaysOn true in
# host.json to keep the helper up with the window closed, or while testing
# hostd on its own.
#
# Usage:
#   scripts/install-host-task.ps1 [[-Bin] path-to-tokenstat-hostd.exe]
#   scripts/install-host-task.ps1 -Uninstall

param(
    [string]$Bin,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$TaskName = "ai.tokenstat.hostd"
$LogDir = Join-Path $env:LOCALAPPDATA "tokenstat\logs"

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Write-Host "Removed $TaskName"
    exit 0
}

if (-not $Bin) {
    $Bin = Join-Path $env:LOCALAPPDATA "tokenstat\bin\tokenstat-hostd.exe"
}
if (-not (Test-Path -LiteralPath $Bin)) {
    Write-Error "error: $Bin is not an executable`nhint: cargo build --release -p tokenstat-host --bin tokenstat-hostd"
}
$Bin = (Resolve-Path -LiteralPath $Bin).Path

$IdentityDir = if ($env:TOKENSTAT_IDENTITY_DIR) {
    $env:TOKENSTAT_IDENTITY_DIR
} else {
    Join-Path $env:APPDATA "tokenstat\tokenstat\identity"
}
$HostJson = Join-Path $IdentityDir "host.json"

function Test-InternalBattery {
    $null -ne (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
}

$AlwaysOn = $false
if (Test-Path -LiteralPath $HostJson) {
    try {
        $parsed = Get-Content -LiteralPath $HostJson -Raw | ConvertFrom-Json
        if ($null -ne $parsed.alwaysOn) {
            $AlwaysOn = [bool]$parsed.alwaysOn
        } else {
            $AlwaysOn = -not (Test-InternalBattery)
        }
    } catch {
        $AlwaysOn = -not (Test-InternalBattery)
    }
} else {
    $AlwaysOn = -not (Test-InternalBattery)
    New-Item -ItemType Directory -Force -Path $IdentityDir | Out-Null
    $json = if ($AlwaysOn) { "{`n  `"alwaysOn`": true`n}`n" } else { "{`n  `"alwaysOn`": false`n}`n" }
    Set-Content -LiteralPath $HostJson -Value $json -Encoding utf8
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$Action = New-ScheduledTaskAction -Execute $Bin
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
$settingsArgs = @{
    AllowStartIfOnBatteries     = $true
    DontStopIfGoingOnBatteries  = $true
    ExecutionTimeLimit          = [TimeSpan]::Zero
    MultipleInstances           = "IgnoreNew"
}
if ($AlwaysOn) {
    $settingsArgs.RestartCount = 3
    $settingsArgs.RestartInterval = New-TimeSpan -Minutes 1
}
$Settings = New-ScheduledTaskSettingsSet @settingsArgs
if ($AlwaysOn) {
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal `
        -Settings $Settings -Trigger $Trigger -Force | Out-Null
} else {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal `
        -Settings $Settings -Force | Out-Null
}

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed $TaskName (alwaysOn=$AlwaysOn) -> $Bin"
