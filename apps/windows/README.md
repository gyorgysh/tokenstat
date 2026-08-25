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

1. Copies the folder to `%LOCALAPPDATA%\Programs\tokenstat`
2. Writes a Start Menu shortcut
3. Writes `HKCU\...\Uninstall\ai.tokenstat.tokenstat`
4. Registers the per-user host task `ai.tokenstat.hostd`
5. Relaunches from the install directory

`--install` does that without opening a window. `--uninstall` reverses it.
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

Needs the Windows App SDK targeting pack, .NET 8, and a Rust MSVC toolchain.

```powershell
scripts/build-windows-app.ps1 -Version 0.6.8 -Rid win-x64 -Out dist
```

Produces `dist/tokenstat-<version>-windows-x64/` with `Tokenstat.exe` and
`tokenstat-hostd.exe`. Zip that folder for GitHub Actions.

Do not put the CLI in the same folder as `Tokenstat.exe`. Windows paths are
case-insensitive, and `tokenstat.exe` would overwrite the app.

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
