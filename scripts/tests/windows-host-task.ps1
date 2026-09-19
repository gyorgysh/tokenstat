# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Portable fault test for the exact generated scheduled-task command.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\install-host-task.ps1'
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $source, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
$assignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$Action'
}, $true)
function New-ScheduledTaskAction {
    param($Execute, $Argument)
    [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
}
$BinQuoted = "C:\Users\Example O''Brien\tokenstat-hostd.exe"
$WorkDirQuoted = "C:\Users\Example O''Brien"
Invoke-Expression $assignment.Extent.Text
$marker = '-Command "'
$offset = $Action.Argument.IndexOf($marker)
if ($offset -lt 0) { throw 'Missing task command' }
$body = $Action.Argument.Substring($offset + $marker.Length).TrimEnd('"')
$mock = @'
$ErrorActionPreference = 'Stop'
function Start-Process {
    param($FilePath, $WorkingDirectory, $WindowStyle, [switch]$PassThru, [switch]$Wait)
    if ($Wait) { throw 'Waiting for descendants prevents crash recovery' }
    if (-not $PassThru -or $WindowStyle -ne 'Hidden') { throw 'Incorrect launch options' }
    if ($FilePath -ne "C:\Users\Example O'Brien\tokenstat-hostd.exe") { throw 'Path quoting failed' }
    $process = [pscustomobject]@{ Captured = $false; Waited = $false }
    $process | Add-Member ScriptProperty Handle { $this.Captured = $true; return 123 }
    $process | Add-Member ScriptMethod WaitForExit { $this.Waited = $true }
    $process | Add-Member ScriptProperty ExitCode {
        if (-not $this.Captured -or -not $this.Waited) { throw 'Process status not retained' }
        return 37
    }
    return $process
}
'@
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes($mock + "`n" + $body))
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$child = [System.Diagnostics.Process]::Start($start)
$null = $child.Handle
try {
    if (-not $child.WaitForExit(10000)) { $child.Kill(); throw 'Task wrapper blocked after host exit' }
    if ($child.ExitCode -ne 37) { throw "Expected host crash status 37; got $($child.ExitCode)" }
} finally { $child.Dispose() }
Write-Host 'Host task waits only for the daemon, preserves its crash status, and quotes profile paths.'
