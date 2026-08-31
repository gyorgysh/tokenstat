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
]

# `.tint(` at the start of a line is the view modifier. `RunOutcome.tint(…)`
# and `Avatar.tint(for:)` are functions that happen to share the name, and are
# preceded by an identifier rather than by the start of a line.
TINT = re.compile(r"^\s*\.tint\(([^)]*)\)")
BANNED = [
    ("Color.blue", "system blue"),
    (".accentColor", "the system accent"),
    ("Divider()", "a system divider"),
]


def allowed(path, line):
    return any(path.endswith(f) and snip in line for f, snip in ALLOWED)


def main():
    problems = []
    for base, _, names in os.walk(ROOT):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            for number, line in enumerate(open(path), start=1):
                text = line.rstrip("\n")
                stripped = text.strip()
                if stripped.startswith("//"):
                    continue
                if allowed(path, text):
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
    print(f"{len(problems)} place(s) not using the app's accent. Use Theme.accent,")
    print("or, if the colour is genuinely somebody else's, add it to ALLOWED here.")
    return 1


sys.exit(main())
PY
