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
Browser, and Legend screen share (JPEG stills) are in this cut. The canvas
editor is not. The boards and reports are.

## Icon

`Assets/tokenstat.ico` is generated from the Mac light app icon:

```
python3 scripts/generate-windows-icon.py
```
