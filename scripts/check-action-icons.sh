#!/usr/bin/env bash
# Every button in the app's own content carries a glyph from the vocabulary.
#
# The vocabulary is apps/mac/Sources/Design/ActionIcon.swift, the twin of
# `shared/web/actionIcons.js` on the website. A new `Button("Do it") { … }` in a
# card, form or empty state should be `Button("Do it", .someAction) { … }`.
#
# Deliberately not checked, because the platform draws these itself and a glyph
# on them is wrong rather than missing: alerts, confirmation dialogs, toolbars,
# swipe actions, and the macOS main menu.
#
#   scripts/check-action-icons.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re, sys

SRC = "apps/mac/Sources"
skip_ctx = re.compile(r'\.alert\(|\.confirmationDialog\(|ToolbarItem|\.toolbar\s*[({]|CommandGroup|CommandMenu|\.swipeActions')
has_glyph = re.compile(
    r'systemImage|ActionIcon|Image\(systemName|, \.\w+[,)]|icon\.label|\.label\('
    r'|,\s*\w*[Aa]ctionIcon|,\s*\w+\.actionIcon|,\s*actionIcon'
)

# Buttons whose whole surface is the label — sidebar rows, launch tiles,
# heatmap cells, day chips, the avatar — plus the handful of caption-size text
# buttons that read as links. A glyph inside one of these is wrong, not
# missing. Matched on the file and a snippet rather than a line number so the
# list survives the code moving.
ALLOWED = [
    ("App/RootView.swift", "Button(action: action) {"),              # sidebar rows
    ("App/TokenstatApp.swift", 'Button("About tokenstat")'),         # app menu
    ("Features/Home/HeatmapView.swift", "Button {"),                 # heatmap cell
    ("Features/Terminals/TerminalPane.swift", "Button {"),           # session tile
    ("Features/Terminals/TerminalPane.swift", "Button(action: onBegin)"),
    ("Features/Terminals/TerminalPane.swift", "Button(action: onInstall)"),
    ("Features/Workspaces/WorkspaceInspector.swift", "Button(action: action) {"),
    ("Features/Workspaces/WorkspacesView.swift", 'Button(all ? "Clear all"'),
    ("Features/Workspaces/WorkspacesView.swift", "Button(action: onOpen)"),
    ("Features/Automations/AutomationsView.swift", "Button {"),      # expander rows, day chips
    ("Features/Automations/AutomationsView.swift", "Button(action, action: perform)"),
    ("Client/AvatarButton.swift", "Button(action: action)"),
    ("Client/ClientHostWorkspacesView.swift", "Button {"),           # session rows
    ("Client/ClientLaunchTile.swift", "Button(action: action)"),
    ("Client/ClientLoginView.swift", "Button(title) {"),             # Terms / Privacy links
    ("Client/ClientOnboarding.swift", 'Button("Skip")'),             # onboarding convention
    ("Client/ClientSecurityCard.swift", "Button {"),                 # key row copies itself
    ("Client/ClientStates.swift", 'Button(showingDetail ?'),         # "Details" link
    ("Client/ClientWorkspaceDetailView.swift", "Button {"),          # file and session rows
    ("Client/ClientWorkspacesView.swift", "Button {"),               # host rows
    ("Client/PhoneHeatmap.swift", "Button {"),                       # heatmap cell
    ("Features/Machines/MachinesView.swift", "Button {"),            # pair row wrapper
    ("Design/Theme.swift", "Button(title) { isOn.toggle() }"),       # two-state chip
]


def allowed(path, line):
    return any(path.endswith(f) and snip in line for f, snip in ALLOWED)

vocab = set(re.findall(r'^\s{4}case (\w+)$', open(f"{SRC}/Design/ActionIcon.swift").read(), re.M))
bad = []
used = set()

for root, _, files in os.walk(SRC):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        p = os.path.join(root, f)
        lines = open(p).read().split("\n")
        for i, line in enumerate(lines):
            for m in re.finditer(r'Button\("[^"]*",\s*\.(\w+)', line):
                used.add(m.group(1))
            for m in re.finditer(r'ActionIcon\.(\w+)', line):
                used.add(m.group(1))
            if not re.search(r'\bButton\s*[({]', line):
                continue
            if has_glyph.search("\n".join(lines[i:i + 18])):
                continue
            indent = len(line) - len(line.lstrip())
            excluded = False
            for j in range(i - 1, max(-1, i - 50), -1):
                if not lines[j].strip():
                    continue
                k = len(lines[j]) - len(lines[j].lstrip())
                if k >= indent:
                    continue
                if skip_ctx.search(lines[j]):
                    excluded = True
                    break
                if k == 0:
                    break
            if not excluded and not allowed(p, line):
                bad.append(f"{p}:{i + 1}  {line.strip()[:88]}")

unknown = sorted(used - vocab)
for u in unknown:
    bad.append(f"{SRC}/Design/ActionIcon.swift  no case for \".{u}\"")

if bad:
    print("\n".join(bad))
    print(f"\n{len(bad)} button(s) with no glyph — give each one an ActionIcon, or,")
    print("if it is a tappable row or tile, add it to ALLOWED in this script.")
    sys.exit(1)
print("Every content button carries a glyph from the vocabulary.")
PY
