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
    function Wait-ForControl([string]$Id, [int]$Seconds = 10) {
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
        for ($attempt = 0; $attempt -lt $Seconds * 4; $attempt++) {
            $control = $window.FindFirst($descendants, $condition)
            if ($control -and !$control.Current.IsOffscreen) { return $control }
            Start-Sleep -Milliseconds 250
        }
        throw "Production page did not render '$Id'"
    }
    # Exercise real pages, including the task board's reusable composer controls.
    # The startup-only check could pass while Tasks caught a XAML parenting
    # exception and showed a blank board with an installation error message.
    Open-Place 'Tasks'
    Wait-ForControl 'tasks.column.backlog' | Out-Null
    Wait-ForControl 'tasks.column.doing' | Out-Null
    Wait-ForControl 'tasks.column.done' | Out-Null
    Open-Place 'Notes'
    Wait-ForControl 'notes.search' | Out-Null
    Open-Place 'Tasks'
    Wait-ForControl 'tasks.column.backlog' | Out-Null
    Open-Place 'Home'
    Write-Output 'PASS: production rail opens Tasks and Notes and renders the task columns again after navigation'

    function Call-Host([string]$Method, [hashtable]$Parameters = @{}) {
        $user = ($env:USERNAME -replace '[^A-Za-z0-9._-]', '_')
        if (!$user) { $user = 'user' }
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', "ai.tokenstat.hostd.$user", [System.IO.Pipes.PipeDirection]::InOut)
        $reader = $null; $writer = $null
        try {
            $pipe.Connect(5000)
            $encoding = [System.Text.UTF8Encoding]::new($false)
            $reader = [System.IO.StreamReader]::new($pipe, $encoding, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($pipe, $encoding, 4096, $true)
            $writer.WriteLine((@{id = 9001; method = $Method; params = $Parameters} | ConvertTo-Json -Depth 10 -Compress))
            $writer.Flush()
            $response = $reader.ReadLineAsync()
            if (!$response.Wait(15000)) { throw "Fixture host call timed out: $Method" }
            $answer = $response.Result | ConvertFrom-Json
            if (!$answer.ok) { throw "Fixture host call failed: $Method $($answer.error | ConvertTo-Json -Compress)" }
            return $answer.result
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($writer) { $writer.Dispose() }
            $pipe.Dispose()
        }
    }
    function Invoke-Control($Control) {
        $pattern = $null
        if ($Control.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
        if ($Control.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select(); return }
        throw "Control cannot be invoked: $($Control.Current.Name)"
    }
    # Seed only the disposable runner. No agent is started or message sent.
    Wait-ForControl 'sidebar.addProject' | Out-Null
    $folders = @(Call-Host 'workspace.list')
    if ($folders.Count -eq 0) { Wait-ForControl 'projects.firstAdd' | Out-Null }
    $fixture = Join-Path $env:RUNNER_TEMP 'tokenstat-ui-project'
    New-Item -Path $fixture -ItemType Directory -Force | Out-Null
    $folder = Call-Host 'workspace.add' @{path = $fixture}
    Call-Host 'workspace.rename' @{id = $folder.id; name = 'UI smoke project'} | Out-Null
    $chats = @()
    for ($index = 1; $index -le 12; $index++) {
        $chats += Call-Host 'chat.create' @{workspaceId = $folder.id; backend = 'codex'; title = "UI smoke chat $index"}
    }
    # The slow sidebar poll discovers externally registered folders once a minute.
    Open-Place 'Projects'
    $chatRow = Wait-ForControl "sidebar.chat.$($chats[-1].id)" 65
    Invoke-Control $chatRow
    $draft = Wait-ForControl 'chat.composer'
    $value = $draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue('Retained unsent smoke draft')
    Wait-ForControl 'chat.title' | Out-Null
    Open-Place 'Setup'
    $draft = Wait-ForControl 'chat.composer'
    if ($draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne 'Retained unsent smoke draft') {
        throw 'Rebuilding the chat setup lost the draft'
    }
    Open-Place 'Reload chats'
    $draft = Wait-ForControl 'chat.composer'
    if ($draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne 'Retained unsent smoke draft') {
        throw 'Reopening the chat composer lost the draft'
    }
    Invoke-Control (Wait-ForControl 'sidebar.chatMore')
    Wait-ForControl "sidebar.chat.$($chats[4].id)" | Out-Null
    Invoke-Control (Wait-ForControl 'sidebar.chatAll')
    Wait-ForControl 'chat.list' | Out-Null
    # Create uses the same composer path as opening an archived conversation.
    Open-Place 'New chat in UI smoke project'
    Wait-ForControl 'chat.composer' | Out-Null
    $trace = Get-Content "$env:LOCALAPPDATA/tokenstat/logs/startup.log" | Where-Object { $_ -match "pid=$($process.Id) " }
    if ($trace -match 'Chat open failed|[Uu]nhandled exception') { throw 'Production chat or sidebar raised a XAML exception' }
    Write-Output 'PASS: production chats open, rebuild setup, retain drafts on reopen, expand history and create a new conversation'
} finally {
    Get-ChildItem "$env:LOCALAPPDATA/tokenstat/logs" -Filter '*.log' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output "--- $($_.Name) ---"; Get-Content $_.FullName -Tail 80 }
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1001,1026} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Tokenstat|Microsoft.UI.Xaml' } |
        Select-Object TimeCreated,Id,Message | Format-List
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
}
