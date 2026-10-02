# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Runs only on the disposable CI runner: the real application may register its helper.
param([string]$AppPath = '')

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw 'Run this startup regression on a disposable CI runner.' }
if ($AppPath) {
    # Preview uses the published folder and its actual release helper.
    $app = Get-Item -LiteralPath $AppPath
    if ($app.PSIsContainer) { throw 'AppPath must name Tokenstat.exe.' }
} else {
    $app = Get-ChildItem "$PSScriptRoot/../../../apps/windows/bin" -Filter Tokenstat.exe -Recurse |
        Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
    if (!$app) { throw 'Build the Windows application before running this test.' }
    Copy-Item "$PSScriptRoot/../../../target/debug/tokenstat-hostd.exe" $app.DirectoryName -Force
}
if (!(Test-Path -LiteralPath (Join-Path $app.DirectoryName 'tokenstat-hostd.exe') -PathType Leaf)) {
    throw 'The application folder is missing its host helper.'
}
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
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    $descendants = [System.Windows.Automation.TreeScope]::Descendants
    function Open-Place([string]$Name) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
        $button = $window.FindAll($descendants, $condition) | Where-Object { !$_.Current.IsOffscreen } | Select-Object -First 1
        if (!$button) { throw "Rail destination '$Name' is missing" }
        $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
    }
    function Wait-ForControl([string]$Id) {
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            if ($window.FindFirst($descendants, $condition)) { return }
            Start-Sleep -Milliseconds 250
        }
        throw "Production page did not render '$Id'"
    }
    # Exercise real pages, including the task board's reusable composer controls.
    # The startup-only check could pass while Tasks caught a XAML parenting
    # exception and showed a blank board with an installation error message.
    Open-Place 'Tasks'
    Wait-ForControl 'tasks.column.backlog'
    Wait-ForControl 'tasks.column.doing'
    Wait-ForControl 'tasks.column.done'
    Open-Place 'Notes'
    Wait-ForControl 'notes.search'
    Open-Place 'Tasks'
    Wait-ForControl 'tasks.column.backlog'
    Open-Place 'Home'
    Write-Output 'PASS: production rail opens Tasks and Notes and renders the task columns again after navigation'
} finally {
    Get-ChildItem "$env:LOCALAPPDATA/tokenstat/logs" -Filter '*.log' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output "--- $($_.Name) ---"; Get-Content $_.FullName -Tail 80 }
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1001,1026} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Tokenstat|Microsoft.UI.Xaml' } |
        Select-Object TimeCreated,Id,Message | Format-List
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
}
