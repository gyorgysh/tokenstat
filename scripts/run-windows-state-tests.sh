#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
# Run portable client state regressions without the Windows UI runtime.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

projects=(
  windows-chat/WindowsChatTests.csproj
  windows-notes/WindowsNoteTests.csproj
  windows-board/WindowsBoardTests.csproj
  windows-devices/WindowsDeviceTests.csproj
  windows-persona/WindowsPersonaTests.csproj
  windows-shell/WindowsShellTests.csproj
  windows-automations/WindowsAutomationTests.csproj
)
for project in "${projects[@]}"; do
  dotnet run --project "scripts/tests/$project" -c Release
done
