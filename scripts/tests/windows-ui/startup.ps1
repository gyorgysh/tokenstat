# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Runs only on the disposable CI runner: the real application may register its helper.
$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw 'Run this startup regression on a disposable CI runner.' }
$app = Get-ChildItem "$PSScriptRoot/../../../apps/windows/bin" -Filter Tokenstat.exe -Recurse |
    Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
if (!$app) { throw 'Build the Windows application before running this test.' }
Copy-Item "$PSScriptRoot/../../../target/debug/tokenstat-hostd.exe" $app.DirectoryName -Force
$started = Get-Date
$process = Start-Process -FilePath $app.FullName -WorkingDirectory $app.DirectoryName -PassThru
try {
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "GUI exited during startup with code $($process.ExitCode)" }
    }
    if ($process.MainWindowHandle -eq 0 -or !$process.Responding) {
        throw 'The application did not create a responsive main window.'
    }
    $trace = Get-Content "$env:LOCALAPPDATA/tokenstat/logs/startup.log" |
        Where-Object { $_ -match "pid=$($process.Id) " }
    if (!($trace -match 'Main window content loaded') -or ($trace -match '[Uu]nhandled exception')) {
        throw 'The main window did not finish loading without exceptions.'
    }
    Write-Output 'PASS: production Windows application survives startup with a responsive main window'
} finally {
    Get-ChildItem "$env:LOCALAPPDATA/tokenstat/logs" -Filter '*.log' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output "--- $($_.Name) ---"; Get-Content $_.FullName -Tail 80 }
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1001,1026} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Tokenstat|Microsoft.UI.Xaml' } |
        Select-Object TimeCreated,Id,Message | Format-List
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
}
