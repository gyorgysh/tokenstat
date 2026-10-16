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
# The landing page offers installed agents. Advertise a disposable, fail-closed
# fixture so this check does not depend on a runner's real agent installation.
# Use a conventional agent directory too: a scheduled helper need not inherit
# this PowerShell process's PATH. Restore any existing command after the check.
# Opening an empty chat must never execute a turn through this command.
$agentBin = Join-Path $env:USERPROFILE '.local/bin'
New-Item -Path $agentBin -ItemType Directory -Force | Out-Null
$agentFile = Join-Path $agentBin 'codex.cmd'
$previousAgent = Join-Path $env:RUNNER_TEMP 'codex.cmd.before-ui-smoke'
$hadAgent = Test-Path -LiteralPath $agentFile
if ($hadAgent) { Copy-Item -LiteralPath $agentFile -Destination $previousAgent -Force }
$originalPath = $env:PATH
$started = Get-Date
$process = $null
try {
    [System.IO.File]::WriteAllText($agentFile, "@echo off`r`necho UI startup fixture cannot run an agent. 1>&2`r`nexit /b 64`r`n")
    $env:PATH = "$agentBin;$originalPath"
    $process = Start-Process -FilePath $app.FullName -WorkingDirectory $app.DirectoryName -PassThru
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
        Write-Host "Opening '$Name'"
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))
        $button = $null
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $process.Refresh()
            if ($process.HasExited) { throw "GUI exited while waiting for '$Name'" }
            $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $button = $window.FindAll($descendants, $condition) | Where-Object { !$_.Current.IsOffscreen } | Select-Object -First 1
            if ($button) { break }
            Start-Sleep -Milliseconds 250
        }
        if (!$button) { throw "Rail destination '$Name' is missing after layout" }
        $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $invoke.Invoke()
    }
    function Wait-ForControl([string]$Id, [int]$Seconds = 10, [switch]$Enabled) {
        Write-Host "Waiting for '$Id'"
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
        for ($attempt = 0; $attempt -lt $Seconds * 4; $attempt++) {
            $process.Refresh()
            if ($process.HasExited) { throw "GUI exited while waiting for '$Id'" }
            $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $control = $window.FindFirst($descendants, $condition)
            if ($control -and !$control.Current.IsOffscreen -and (!$Enabled -or $control.Current.IsEnabled)) { return $control }
            Start-Sleep -Milliseconds 250
        }
        $window.FindAll($descendants, [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.AutomationId -match '^(sidebar|chat|newChat|projects)\.' -or (!$_.Current.IsOffscreen -and $_.Current.Name) } |
            Select-Object -First 100 |
            ForEach-Object { Write-Host "UI: $($_.Current.AutomationId); offscreen=$($_.Current.IsOffscreen); $($_.Current.Name)" }
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
        Write-Host "Invoking '$($Control.Current.Name)'"
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
    # chat.recent deliberately omits chats without messages. Give the fixture
    # a synthetic archived user event without sending anything to an agent.
    $indexFile = Get-ChildItem -Path "$env:APPDATA/tokenstat", "$env:LOCALAPPDATA/tokenstat" -Filter conversations.json -Recurse -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw).Contains($chats[-1].id) } | Select-Object -First 1
    if (!$indexFile) { throw 'The disposable conversation index was not found' }
    $archive = Get-Content -LiteralPath $indexFile.FullName -Raw | ConvertFrom-Json
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    for ($index = 0; $index -lt $chats.Count; $index++) {
        $id = $chats[$index].id
        $directory = Join-Path $indexFile.DirectoryName $id
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
        $event = @{kind = 'user'; at_ms = $timestamp + $index; text = "Archived UI fixture message $index"}
        [System.IO.File]::WriteAllText((Join-Path $directory 'events.ndjson'), (($event | ConvertTo-Json -Compress) + "`n"))
        $record = $archive.conversations | Where-Object { $_.id -eq $id } | Select-Object -First 1
        $record | Add-Member -MemberType NoteProperty -Name lastMessageAtMs -Value ($timestamp + $index) -Force
        $record | Add-Member -MemberType NoteProperty -Name lastMessageAuthor -Value 'user' -Force
    }
    [System.IO.File]::WriteAllText($indexFile.FullName, ($archive | ConvertTo-Json -Depth 30))
    # A normal update reloads the durable index into the helper's memory.
    Call-Host 'chat.update' @{id = $chats[-1].id; title = $chats[-1].title} | Out-Null
    if (@(Call-Host 'chat.recent' @{limit = 50}).Count -lt 12) { throw 'Archived fixture chats did not enter the recent feed' }
    # The slow sidebar poll discovers externally registered folders once a minute.
    Open-Place 'Repositories'
    $chatRow = Wait-ForControl "sidebar.chat.$($chats[-1].id)" 65
    Invoke-Control $chatRow
    $draft = Wait-ForControl 'chat.composer'
    $value = $draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue('Retained unsent smoke draft')
    Wait-ForControl 'chat.title' | Out-Null
    # Backend/persona discovery can repaint the composer after the transcript
    # opens. Wait for its new native control to finish layout before invoking.
    Invoke-Control (Wait-ForControl 'chat.setup')
    $draft = Wait-ForControl 'chat.composer'
    Wait-ForControl 'chat.send' | Out-Null
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
    Wait-ForControl 'chat.list.create' | Out-Null
    # Opening New chat is an unsent landing draft, with no durable conversation.
    $before = @(Call-Host 'chat.list' @{workspaceId = $folder.id})
    Open-Place 'New chat in UI smoke project'
    Wait-ForControl 'newChat.repository' | Out-Null
    $landing = Wait-ForControl 'newChat.composer'
    Wait-ForControl 'newChat.send' 30 -Enabled | Out-Null
    if (@(Call-Host 'chat.list' @{workspaceId = $folder.id}).Count -ne $before.Count) {
        throw 'Opening the new chat landing page created a conversation'
    }
    $landing.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Retained landing smoke draft')
    Open-Place 'Home'
    Open-Place 'New chat in UI smoke project'
    $landing = Wait-ForControl 'newChat.composer'
    $landingValue = $landing.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($landingValue.Current.Value -ne 'Retained landing smoke draft') { throw 'Reopening New chat lost the landing draft' }
    if (@(Call-Host 'chat.list' @{workspaceId = $folder.id}).Count -ne $before.Count) {
        throw 'Reopening the new chat landing page created a conversation'
    }
    # An explicit empty Open chat restores file/image-first prompts without
    # sending a message. It uses the production creation and composer path.
    $landingValue.SetValue('')
    $openChat = Wait-ForControl 'newChat.send' 30 -Enabled
    if ($openChat.Current.Name -ne 'Open chat') { throw 'The empty landing prompt must offer Open chat' }
    Invoke-Control $openChat
    Wait-ForControl 'chat.composer' 30 | Out-Null
    $after = @(Call-Host 'chat.list' @{workspaceId = $folder.id})
    $created = @($after | Where-Object { $_.id -notin $before.id })
    if ($after.Count -ne $before.Count + 1 -or $created.Count -ne 1) { throw 'Explicit Open chat must create exactly one conversation' }
    $latest = $created[0]
    if ($latest.running -or $latest.sendRevision -ne 0) { throw 'Empty Open chat started an agent turn' }
    if (@((Call-Host 'chat.events' @{id = $latest.id; offset = 0}).events).Count -ne 0) {
        throw 'Empty Open chat appended transcript events'
    }
    Wait-ForControl "sidebar.chat.$($latest.id)" | Out-Null
    $trace = Get-Content "$env:LOCALAPPDATA/tokenstat/logs/startup.log" | Where-Object { $_ -match "pid=$($process.Id) " }
    if ($trace -match 'Chat open failed|[Uu]nhandled exception') { throw 'Production chat or sidebar raised a XAML exception' }
    Write-Output 'PASS: production chats retain drafts, expand history, keep New chat drafts without ghost conversations, and explicitly open one empty chat without sending'
} finally {
    $env:PATH = $originalPath
    if ($hadAgent) { Move-Item -LiteralPath $previousAgent -Destination $agentFile -Force }
    elseif (Test-Path -LiteralPath $agentFile) { Remove-Item -LiteralPath $agentFile -Force }
    Get-ChildItem "$env:LOCALAPPDATA/tokenstat/logs" -Filter '*.log' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Output "--- $($_.Name) ---"; Get-Content $_.FullName -Tail 80 }
    Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=$started; Id=1000,1001,1026} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Tokenstat|Microsoft.UI.Xaml' } |
        Select-Object TimeCreated,Id,Message | Format-List
    if ($process) {
        if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
        $process.Dispose()
    }
}
