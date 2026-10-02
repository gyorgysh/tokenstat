#!/usr/bin/env bash
#
# One accent, and it is the app's own.
#
# The app has an AccentColor colorset and a `.tint(Theme.accent)` at each root,
# so a control inherits the accent rather than remembering it. What this guard
# stops is the drift back: the state it was in before, where eight call sites
# set the accent by hand and everything else was system blue.
#
# Fails on:
#   - `Color.blue` and `.accentColor`, which are the system's colour, not ours
#   - a `.tint(…)` modifier whose argument is not a `Theme.` colour
#   - `Divider()`, whose line colour comes from the platform material rather
#     than the app palette. Use `ThemeRule` instead.
#   - `.roundedBorder`, AppKit's bezel and UIKit's, which resolves to a flat
#     mid grey on a dark panel. Use `.themed`, `.themedSmall`, or
#     `.themedMultiline` for a field that grows.
#   - `(.bar)`, the system's grey bar material. A terminal key bar wore it
#     below a themed screen. Use `TerminalPalette.surface` or a `Theme.`
#     colour instead. If a surface is genuinely the platform's (a Menu, an
#     alert, a toolbar), add it to ALLOWED here rather than working around
#     the guard.
#
# The action-icon guard is the precedent. A convention nobody can enforce by
# remembering is a convention that comes back.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import os
import re
import sys

ROOT = "apps/mac/Sources"

# (path suffix, snippet) pairs that are allowed to say what they say.
ALLOWED = [
    # A harness names its own colour and the app draws it. This is a vendor's
    # blue, not a control that forgot the accent.
    ("Bridge/Models.swift", 'case "blue": Color.blue'),
    # A status row's spinner, tinted with the colour of the status it reports.
    # Every caller in both files passes a Theme colour; the parameter is what
    # this script cannot read, not the value.
    ("App/SyncCard.swift", ".tint(tint)"),
    ("App/UpdateCard.swift", ".tint(tint)"),
    # Separators inside a pull-down Menu. The menu itself is the platform's
    # surface, as with alerts and toolbars: a ThemeRule rectangle there would
    # be a full-bleed custom view where the system draws an inset separator.
    ("Features/Automations/AutomationsView.swift", "Divider()"),
    ("Features/Todo/NotesView.swift", "Divider()"),
    ("Features/Machines/MachinesView.swift", "Divider()"),
]

# These menus are mixed with app-owned panel content in these files.
# Permit only the known native menu separators, identified by both adjacent
# menu statements; a Divider added elsewhere in the file must still fail.
MENU_SEPARATORS = [
    ("Client/ClientChatMenu.swift", "if onSetup != nil || onHandoff != nil {", "if let onSetup {"),
    ("Client/ClientChatMenu.swift", "if onDelete != nil {", "Button(L10n.text(\"apple.clientchatview.delete_chat.93291d9c\"), .delete, role: .destructive) {"),
    ("Features/Terminals/ChatTerminalPane.swift", "if !ssh.hosts.isEmpty {", "Menu(L10n.text(\"apple.rootview.servers.68d7beb6\")) {"),
    ("Features/Terminals/ChatTerminalPane.swift", "if layout.isSplit {", "TerminalSwapButton(layout: layout) { terminals.swapPanes(in: folder.id) }"),
    ("Features/Terminals/TerminalPane.swift", "if splitLayout.isSplit {", "TerminalSwapButton(layout: splitLayout) { terminals.swapPanes(in: folder.id) }"),
    ("Features/Machines/SSHTerminalPane.swift", "if layout.isSplit {", "TerminalSwapButton(layout: layout) { sessions.swapPanes(in: host.id) }"),
]

# `.tint(` at the start of a line is the view modifier. `RunOutcome.tint(…)`
# and `Avatar.tint(for:)` are functions that happen to share the name, and are
# preceded by an identifier rather than by the start of a line.
TINT = re.compile(r"^\s*\.tint\(([^)]*)\)")
BANNED = [
    ("Color.blue", "system blue"),
    (".accentColor", "the system accent"),
    ("Divider()", "a system divider"),
    (".roundedBorder", "the platform's field bezel"),
    ("(.bar)", "the system's bar material"),
]


def allowed(path, line, previous, following):
    if any(path.endswith(f) and snip in line for f, snip in ALLOWED):
        return True
    return line.strip() == "Divider()" and any(
        path.endswith(f) and previous.strip() == before and following.strip() == after
        for f, before, after in MENU_SEPARATORS
    )


def main():
    problems = []
    for base, _, names in os.walk(ROOT):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            lines = open(path).readlines()
            for number, line in enumerate(lines, start=1):
                text = line.rstrip("\n")
                stripped = text.strip()
                if stripped.startswith("//"):
                    continue
                previous = lines[number - 2] if number > 1 else ""
                following = lines[number] if number < len(lines) else ""
                if allowed(path, text, previous, following):
                    continue
                for needle, what in BANNED:
                    if needle in text:
                        problems.append((path, number, stripped, what))
                match = TINT.match(text)
                if match and "Theme." not in match.group(1):
                    problems.append(
                        (path, number, stripped, "a tint that is not Theme.")
                    )

    if not problems:
        print("Every control takes its colour from the theme.")
        return 0

    for path, number, text, what in problems:
        print(f"{path}:{number}  {text}")
        print(f"    ^ {what}")
    print()
    print(f"{len(problems)} place(s) not on the app's own surface. Use Theme.accent")
    print("or a themed control, or, if it is genuinely somebody else's, add it")
    print("to ALLOWED here.")
    return 1


sys.exit(main())
PY
