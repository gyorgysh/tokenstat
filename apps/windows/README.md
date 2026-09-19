<!-- SPDX-License-Identifier: LicenseRef-tokenstat-source-available -->

# Windows app

WinUI 3 desktop client for tokenstat. Unpackaged, per-user, talks to
`tokenstat-hostd` over a named pipe. Same host methods as the Mac app.

Identifiers stay lowercase: `ai.tokenstat.tokenstat` and `ai.tokenstat.hostd`.

## Company metadata

Filled from [tokenstat.ai](https://tokenstat.ai):

| Field | Value |
| --- | --- |
| Product | tokenstat |
| Company | pueev OÜ |
| Copyright | © pueev OÜ. All rights reserved. |
| Website | https://tokenstat.ai |
| Author | Gyorgy, gyorgy@pueev.com |

The `.exe` version resource, About screen, Start Menu shortcut, and Add/Remove
Programs row all use those strings.

## Install

The published folder is the installer. Double-click `Tokenstat.exe`:

1. Stages the complete folder, then swaps it into `%LOCALAPPDATA%\Programs\tokenstat`
2. Writes a Start Menu shortcut
3. Writes `HKCU\...\Uninstall\ai.tokenstat.tokenstat`
4. Registers the per-user host task `ai.tokenstat.hostd`
5. Relaunches from the install directory

`--install` explicitly installs and opens the installed copy. `--uninstall` reverses it.
A development build (`apps\windows\bin\...`, or `TOKENSTAT_DEV=1`) does not
copy itself.

This is not a Store package and not a Windows Service.

## Auto-update

The host method `app.updateCheck` reports `winZipUrl`. `app.updateDownloadWin`
fetches the zip and checks it against `SHA256SUMS`. The app then stages the
files and offers Relaunch.

Authenticode is required only when the running `Tokenstat.exe` is already
signed, and the replacement must be the same publisher. Preview builds are
unsigned, so they skip that check. The publisher is read from the running
binary, not written down in source.

## Build

Build on Windows with the .NET 8 SDK and a Rust MSVC toolchain, including
the Visual Studio C++ build tools and Windows SDK. NuGet restores the
Windows App SDK dependencies declared in `Tokenstat.csproj`.

```powershell
./scripts/build-windows-app.ps1 -Rid win-x64 -Out dist
```

Produces `dist/tokenstat-<version>-windows-x64/` with `Tokenstat.exe` and
`tokenstat-hostd.exe`. Zip that folder for GitHub Actions.
The version defaults to the Cargo workspace version. Use `-Rid win-arm64`
for ARM64. A failed native build, publish, or notice generation stops the
script before staging an artifact; fix the first reported failure.

Do not put the CLI in the same folder as `Tokenstat.exe`. Windows paths are
case-insensitive, and `tokenstat.exe` would overwrite the app.

Portable installer regression checks run without changing an installed app:

```powershell
dotnet run --project scripts/tests/windows-install/WindowsInstallTests.csproj
```

Native acceptance still requires Windows: publish, launch from an extracted
zip, relaunch the installed copy, test update/rollback and uninstall, and
check light/dark themes, keyboard navigation, window resizing, and 100%/150%/200%
display scaling. A managed C# compilation on another OS does not run the
Windows XAML compiler or validate rendered layout.

Startup failures are recorded in `%LOCALAPPDATA%\tokenstat\logs\startup.log`;
UI exceptions are recorded in `app.log` in the same folder. The helper writes
startup, stderr and panic diagnostics to `hostd.log`, independently of whether
it was launched by the app or Task Scheduler. A log over 5 MiB rotates to
`hostd.previous.log` at the next start. App-side helper launch failures go to
`app-host.log` (with a 1 MiB rotation at the next write).

In PowerShell, follow the host log with:

```powershell
Get-Content "$env:LOCALAPPDATA\tokenstat\logs\hostd.log" -Tail 100 -Wait
```

To distinguish a restarting daemon from a background command opening a console:

```powershell
Get-Process tokenstat-hostd -ErrorAction SilentlyContinue | Select-Object Id,StartTime,Path
Get-ScheduledTaskInfo -TaskName ai.tokenstat.hostd | Format-List LastRunTime,LastTaskResult,NextRunTime
```

The host log is available in builds containing the persistent-logging fix;
older builds created the logs directory without capturing daemon stderr.

## Design

Colours and IA match the Mac app (`Theme`, Home / Insights / Devices / SSH / Tasks /
Notes / Workflows / Automations / Account, plus folders). Buttons pick glyphs
from `Design/ActionIcon.cs`, the same vocabulary as
`apps/mac/Sources/Design/ActionIcon.swift`.

Terminals, SSH password and key connect, Notes, Workflows, Automations,
Browser, and Legend screen sharing are in this cut. The canvas
editor is not. The boards and reports are.

## Icon

`Assets/tokenstat.ico` is generated from the Mac light app icon:

```
python3 scripts/generate-windows-icon.py
```

## Remote work and screen sharing

Devices puts Remote access beside Always-on host, before the machine list.
Connected machines group their folders in the sidebar. Folder rows include the
branch and working-tree additions/removals. Sessions offers the target machine's
shells and agents, with Install/Reinstall in each agent's setup menu. Clicking a
folder opens its launcher, with shortcuts to workspace sections and the Mac
client's bundled agent artwork. Remote conversations appear under Chat.

Local PTY, remote PTY and SSH sessions use the same bundled xterm surface in
WebView2. The terminal renders VT control sequences, colors and full-screen
programs, preserves UTF-8 across reads, and forwards keyboard and mouse input
directly. Copy/paste uses the Windows clipboard and terminal bracketed paste.

Each workspace holds one tab strip for its launcher, terminals, individual
files, browser pages and workspace sections. The file tree stays in the right
inspector, and open documents retain unsaved edits when switching tabs or
folders during the app session. Closing a document checks unsaved changes;
closing a terminal tab detaches the viewer without killing its process. Remote
files use the same editor as local files. Windows launches npm batch shims
through an interpreter and discovers the standalone Codex install directory
without requiring a daemon restart. Remote loopback addresses in the
browser use encrypted forwarding; tabs share a listener until the last user
closes it. SSH connections explicitly choose a saved key, a password, or pasted
private-key material.

Windows screen viewing uses Media Foundation with Annex-B H.264 samples. The
Windows host also captures an unlocked desktop and encodes H.264 for Apple,
Android, and Windows viewers. Capture lives in hostd, so it survives quitting the
app when Always-on host is enabled. Mouse, drag, wheel, physical keys, and text
input require the existing per-device Control grant. Closing or revoking a
session releases held keys/buttons. Secure desktops (including the lock screen)
are not captured or controlled. Encoder/capture failures appear in `hostd.log`
and are sent to the viewer.

The Windows CI job runs the encoder with synthetic pixels, then opens its frames
through the production Windows player pipeline. It also tests actual RichEdit
text round trips, including trailing newlines, terminal VT/UTF-8/input, responsive
card geometry, and repeated player detach/dispose/reopen. To run those checks on Windows:

```powershell
$env:TOKENSTAT_SCREEN_FIXTURE = Join-Path $env:TEMP 'tokenstat-screen-fixture'
cargo test -p tokenstat-host native_encoder_produces_an_independent_annex_b_frame
dotnet run --project scripts/tests/windows-ui/WindowsUiTests.csproj -c Release
```

Real-machine acceptance still includes Mac → Windows and Windows → Mac screen
view/control, display selection, revocation while dragging, Always-on mode after
quitting the Windows app, and LAN versus relay connections. The synthetic test
does not replace these checks.

### Desktop follow-up regressions

The terminal reads retained output from the owning host rather than the destructive
subscription cache, and the shared PTY host retains a bounded 1 MiB replay tail after
acknowledgement. Update the host on the remote Mac as well as the Windows client for
that retention fix. Earlier output beyond that tail is reported as dropped.
Viewport resize requests are serialized; the terminal uses the host's agreed grid
without replacing its own viewport capacity. SSH processes survive page navigation
and can be reopened from the SSH sidebar group.

The native UI regression checks the production file-tree template and terminal
shrinking; the host regression checks replay after acknowledgement. The sidebar
keeps live row containers and pins Home, Insights and Devices above scrolling groups.

Windows chat now saves pending messages under LocalAppData/tokenstat/outbox, scoped
by account, owning workspace and conversation. It supports queuing during a turn,
editing, moving and removing waiting messages, and receipt checks for uncertain
sends. Delivery captures the host sendRevision and claims the exact saved payload
before sending with a stable clientMessageId. Waiting successors advance only after
a confirmed acceptance for that context. Navigation/restart pauses pending messages;
Use latest context explicitly resumes them. It does not yet run queues in the
background after leaving the conversation or automatically deliver on reconnection.
Do not describe that as complete Mac/iOS/Android queue parity.
