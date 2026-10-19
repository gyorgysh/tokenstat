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
    function Wait-ForControl([string]$Id, [int]$Seconds = 10, [switch]$Enabled, [switch]$IncludePopups, [string]$ExpectedName = '') {
        Write-Host "Waiting for '$Id'"
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
        for ($attempt = 0; $attempt -lt $Seconds * 4; $attempt++) {
            $process.Refresh()
            if ($process.HasExited) { throw "GUI exited while waiting for '$Id'" }
            $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $control = $window.FindFirst($descendants, $condition)
            if (!$control -and $IncludePopups) {
                # WinUI may expose Popup in a separate native window. Keep
                # the search inside this production application's process.
                $sameProcess = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
                foreach ($surface in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $sameProcess)) {
                    $candidate = $surface.FindFirst($descendants, $condition)
                    if ($candidate -and !$candidate.Current.IsOffscreen) { $control = $candidate; break }
                }
            }
            if ($control -and !$control.Current.IsOffscreen -and (!$Enabled -or $control.Current.IsEnabled) -and
                (!$ExpectedName -or $control.Current.Name -eq $ExpectedName)) { return $control }
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
    function Reveal-RepositorySidebar {
        $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $id = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'sidebar.addProject')
        $add = $window.FindFirst($descendants, $id)
        if (!$add -or $add.Current.IsOffscreen) { Open-Place 'Show or hide repositories' }
    }
    # Seed only the disposable runner. No agent is started or message sent.
    Wait-ForControl 'sidebar.addProject' | Out-Null
    $folders = @(Call-Host 'workspace.list')
    if ($folders.Count -eq 0) { Wait-ForControl 'projects.firstAdd' | Out-Null }
    $fixture = Join-Path $env:RUNNER_TEMP 'tokenstat-ui-project'
    New-Item -Path $fixture -ItemType Directory -Force | Out-Null
    & git -C $fixture init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the disposable workbench repository' }
    $reviewFile = Join-Path $fixture 'workbench-review.txt'
    [System.IO.File]::WriteAllText($reviewFile, "workbench-live-first`n")
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
    $text = $draft.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $selectedText = $text.DocumentRange.FindText('unsent', $false, $false)
    if (!$selectedText) { throw 'The production composer did not expose its unsent text selection' }
    $selectedText.Select()
    Wait-ForControl 'chat.title' | Out-Null
    # Backend/persona discovery can repaint the composer after the transcript
    # opens. Wait for its new native control to finish layout before invoking.
    Invoke-Control (Wait-ForControl 'chat.setup')
    $agent = Wait-ForControl 'chat.setup.agent' 10 -Enabled
    $selection = $agent.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $selectedAgent = @($selection.Current.GetSelection())
    if ($selectedAgent.Count -ne 1 -or $selectedAgent[0].Current.Name -ne 'Codex') {
        throw 'Opening Setup did not render the selected native agent control'
    }
    $draft = Wait-ForControl 'chat.composer'
    Wait-ForControl 'chat.send' | Out-Null
    if ($draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne 'Retained unsent smoke draft') {
        throw 'Rebuilding the chat setup lost the draft'
    }
    $draftSelection = $draft.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).GetSelection()
    if ($draftSelection.Count -ne 1 -or $draftSelection[0].GetText(-1) -ne 'unsent') {
        throw 'Opening Setup lost the composer text selection'
    }
    Invoke-Control (Wait-ForControl 'chat.setup.done')
    Wait-ForControl 'chat.composer' | Out-Null
    Open-Place 'Reload chats'
    $draft = Wait-ForControl 'chat.composer'
    if ($draft.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne 'Retained unsent smoke draft') {
        throw 'Reopening the chat composer lost the draft'
    }
    # Repeat the production setup rebuild after reopening. Nested inspector
    # content must release its logical owner even if its card was unmounted.
    Invoke-Control (Wait-ForControl 'chat.setup')
    $agent = Wait-ForControl 'chat.setup.agent' 10 -Enabled
    $selectedAgent = @($agent.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection())
    if ($selectedAgent.Count -ne 1 -or $selectedAgent[0].Current.Name -ne 'Codex') {
        throw 'Reopening Setup lost the selected agent'
    }
    Invoke-Control (Wait-ForControl 'chat.setup.done')
    # Explicit information is the same action for chat and terminal rows.
    # Resolve within the retained row, then confirm the native copyable ID
    # surface appears without replacing or navigating the composer.
    # Chat now reserves room for its side workbench. At the runner's narrow
    # window, the native repository sidebar becomes a drawer.
    Reveal-RepositorySidebar
    $chatRow = Wait-ForControl "sidebar.chat.$($chats[-1].id)"
    $detailsId = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'sidebar.details')
    $details = $chatRow.FindFirst($descendants, $detailsId)
    if (!$details) { throw 'The chat row is missing its explicit information button' }
    Invoke-Control $details
    $copyId = Wait-ForControl "session.identity.$($chats[-1].id)" -IncludePopups
    if ($copyId.Current.Name -notlike '*Tokenstat chat ID*') { throw 'The information card did not expose the full chat ID for copying' }
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
    # ValuePattern.SetValue can return before TextChanged updates the button's
    # accessible name. The existing Send button is already enabled, so wait
    # for the expected action as well before asserting and invoking it.
    $openChat = Wait-ForControl 'newChat.send' 30 -Enabled -ExpectedName 'Open chat'
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
    Reveal-RepositorySidebar
    Wait-ForControl "sidebar.chat.$($latest.id)" | Out-Null
    Open-Place 'Show or hide repositories'
    function Wait-ForNativeName([string]$Name, [System.Windows.Automation.ControlType]$Type, [int]$Seconds = 15) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
        $sameProcess = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        for ($attempt = 0; $attempt -lt $Seconds * 4; $attempt++) {
            $process.Refresh()
            if ($process.HasExited) { throw "GUI exited while waiting for '$Name'" }
            foreach ($surface in [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $sameProcess)) {
                $found = $surface.FindAll($descendants, $condition) | Where-Object { !$_.Current.IsOffscreen } | Select-Object -First 1
                if ($found) { return $found }
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Workbench control '$Name' did not appear"
    }
    $buttonType = [System.Windows.Automation.ControlType]::Button
    $textType = [System.Windows.Automation.ControlType]::Text
    Invoke-Control (Wait-ForNativeName 'Review working tree beside chat' $buttonType)
    Invoke-Control (Wait-ForNativeName 'Review all' $buttonType)
    Wait-ForNativeName 'workbench-live-first' $textType | Out-Null
    [System.IO.File]::WriteAllText($reviewFile, "workbench-live-first`nworkbench-live-second`n")
    Wait-ForNativeName 'workbench-live-second' $textType | Out-Null
    Invoke-Control (Wait-ForNativeName 'Browser beside chat' $buttonType)
    Invoke-Control (Wait-ForNativeName 'Changes' ([System.Windows.Automation.ControlType]::TabItem))
    Wait-ForNativeName 'workbench-live-second' $textType | Out-Null
    Invoke-Control (Wait-ForNativeName 'Full diff' $buttonType)
    # Equal line counts must still refresh the actual text, without chat events.
    [System.IO.File]::WriteAllText($reviewFile, "workbench-live-first`nworkbench-live-third`n")
    Wait-ForNativeName 'workbench-live-third' $textType | Out-Null
    if (@((Call-Host 'chat.events' @{id = $latest.id; offset = 0}).events).Count -ne 0) {
        throw 'Reviewing workspace changes appended chat events'
    }
    Write-Output 'PASS: production chat workbench mounts native tabs, retains live review across tools, and refreshes equal-count file edits without sending'
    function Open-DesktopAction([string]$Tool, [string]$Options = '') {
        $project = [Uri]::EscapeDataString($folder.id)
        Start-Process -FilePath "tokenstat://workbench/open?workspace=$project&tool=$Tool$Options"
    }
    function Wait-ForDesktopTool([string]$Tool) {
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            $tab = Wait-ForControl "workbench.tool.$Tool" 10
            $selected = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($selected.Current.IsSelected) { return }
            Start-Sleep -Milliseconds 100
        }
        foreach ($name in @('inspector', 'changes', 'browser', 'terminal')) {
            $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "workbench.tool.$name")
            foreach ($tab in $window.FindAll($descendants, $condition)) {
                $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                Write-Host "Tool state: $name; selected=$($pattern.Current.IsSelected); offscreen=$($tab.Current.IsOffscreen)"
            }
        }
        throw "Desktop activation did not select $Tool"
    }
    $beforeShells = @(Call-Host 'pty.list' | Where-Object { $_.workspaceId -eq $folder.id })
    Open-DesktopAction 'inspector' '&tab=files'
    Wait-ForDesktopTool 'inspector'
    Open-DesktopAction 'browser' '&url=http%3A%2F%2F127.0.0.1%3A65529%2Fdesktop-preview'
    Wait-ForDesktopTool 'browser'
    Open-DesktopAction 'terminal' '&new=1'
    Wait-ForDesktopTool 'terminal'
    $shell = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $afterShells = @(Call-Host 'pty.list' | Where-Object { $_.workspaceId -eq $folder.id })
        $shell = $afterShells | Where-Object { $_.id -notin $beforeShells.id } | Select-Object -First 1
        if ($shell) { break }
        Start-Sleep -Milliseconds 250
    }
    if (!$shell -or $afterShells.Count -ne $beforeShells.Count + 1) { throw 'A new-terminal desktop action must start exactly one shell' }
    Open-DesktopAction 'changes'
    Wait-ForDesktopTool 'changes'
    & git -C $fixture add workbench-review.txt
    & git -C $fixture -c user.name=fixture -c user.email=fixture commit --quiet -m 'Desktop action commit fixture'
    if ($LASTEXITCODE -ne 0) { throw 'The desktop action commit fixture could not be created' }
    $commit = (& git -C $fixture rev-parse HEAD).Trim()
    Open-DesktopAction 'changes' ("&commit=" + $commit)
    Wait-ForDesktopTool 'changes'
    Wait-ForNativeName 'Desktop action commit fixture' $textType | Out-Null
    Wait-ForNativeName 'workbench-live-third' $textType | Out-Null
    Open-DesktopAction 'terminal' ("&session=" + [Uri]::EscapeDataString($shell.id))
    Wait-ForDesktopTool 'terminal'
    Open-Place 'Home'
    Open-DesktopAction 'terminal'
    Wait-ForDesktopTool 'terminal'
    if (@(Call-Host 'pty.list' | Where-Object { $_.workspaceId -eq $folder.id }).Count -ne $afterShells.Count) {
        throw 'Reopening a terminal pane replayed the new-shell request'
    }
    $process.Refresh()
    if ($process.HasExited -or @((Get-Process Tokenstat -ErrorAction SilentlyContinue) | Where-Object { $_.MainWindowHandle -ne 0 }).Count -ne 1) {
        throw 'Warm desktop protocol actions must reach the original application window'
    }
    Write-Output 'PASS: warm protocol actions select inspector, browser, changes and an exact terminal without duplicate windows or shell replay'
    if (!$process.CloseMainWindow() -or !$process.WaitForExit(15000)) { throw 'The app did not close before cold protocol activation' }
    $process.Dispose()
    Open-DesktopAction 'changes'
    $process = $null
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        $process = Get-Process Tokenstat -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($process) { break }
        Start-Sleep -Milliseconds 250
    }
    if (!$process) { throw 'Cold desktop protocol activation did not open the application' }
    Wait-ForDesktopTool 'changes'
    Write-Output 'PASS: cold protocol activation waits for the project inventory and opens its changes pane'
    $trace = Get-Content "$env:LOCALAPPDATA/tokenstat/logs/startup.log" | Where-Object { $_ -match "pid=$($process.Id) " }
    if ($trace -match 'Chat open failed|Chat (composer|inspector) construction failed|[Uu]nhandled exception') { throw 'Production chat or sidebar raised a XAML exception' }
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
