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

SKIP_STARTERS = (
    ".alert",
    ".confirmationDialog",
    ".swipeActions",
    ".contextMenu",
    ".toolbar",
    "ToolbarItem",
    "CommandGroup",
    "CommandMenu",
)

# Buttons whose whole surface is the label (rows, tiles, chips, links).
# Snippet must uniquely identify that one button, not every Button in the file.
ALLOWED = [
    ("App/RootView.swift", "Button(action: action) {"),
    ("App/TokenstatApp.swift", 'Button("About tokenstat")'),
    ("Features/Home/HeatmapView.swift", "onSelect?(item.day)"),
    ("Features/Terminals/TerminalPane.swift", "Button(action: onBegin)"),
    ("Features/Terminals/TerminalPane.swift", "Button(action: onInstall)"),
    ("Features/Workspaces/WorkspaceInspector.swift", "Button(action: action) {"),
    ("Features/Workspaces/WorkspacesView.swift", 'Button(all ? "Clear all"'),
    ("Features/Workspaces/WorkspacesView.swift", "Button(action: onOpen)"),
    ("Features/Automations/AutomationsView.swift", "Button(action, action: perform)"),
    ("Features/Automations/AutomationsView.swift", "Text(dayShort[bit])"),
    ("Features/Automations/AutomationsView.swift", "scheduleKind = kind"),
    ("Features/Automations/AutomationsView.swift", "intervalMinutes = String(minutes)"),
    ("Features/Automations/AutomationsView.swift", "scheduleWeekday = day.0"),
    ("Features/Terminals/TerminalPane.swift", "start(profile)"),
    ("Client/AvatarButton.swift", "Button(action: action)"),
    ("Client/ClientHostWorkspacesView.swift", "model.open(session, peer: peerKey)"),
    ("Client/ClientLaunchTile.swift", "Button(action: action)"),
    ("Client/ClientLoginView.swift", "Button(title) {"),
    ("Client/ClientOnboarding.swift", 'Button("Skip")'),
    ("Client/ClientSecurityCard.swift", "UIPasteboard.general.string = key"),
    ("Client/ClientStates.swift", 'Button(showingDetail ?'),
    ("Client/ClientWorkspaceDetailView.swift", "openExisting(session)"),
    ("Client/ClientWorkspaceDetailView.swift", "showFiles = true"),
    ("Client/ClientWorkspaceDetailView.swift", "showPort = true"),
    ("Client/ClientWorkspacesView.swift", "model.openSession(session)"),
    ("Client/PhoneHeatmap.swift", "onSelect?(day)"),
    ("Design/Theme.swift", "Button(title) { isOn.toggle() }"),
    ("Design/Theme.swift", "selection = option.value"),
]

GLYPH = re.compile(
    r"systemImage|ActionIcon|Image\(\s*systemName|, \.\w+[,)]|\.label\("
    r"|actionIcon"
)
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def allowed(path, snippet):
    return any(path.endswith(f) and snip in snippet for f, snip in ALLOWED)


def skip_ws_and_comments(src, i):
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c in " \t\r\n":
            i += 1
            continue
        if c == "/" and nxt == "/":
            i = src.find("\n", i)
            if i < 0:
                return n
            continue
        if c == "/" and nxt == "*":
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        return i
    return i


def consume_string(src, i):
    quote = src[i]
    i += 1
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i + 1
        i += 1
    return n


def consume_balanced(src, i, open_ch, close_ch):
    assert src[i] == open_ch
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c in "\"'":
            i = consume_string(src, i)
            continue
        if c == "/" and nxt == "/":
            i = src.find("\n", i)
            if i < 0:
                return n
            continue
        if c == "/" and nxt == "*":
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def consume_trailing_closures(src, i):
    n = len(src)
    while True:
        j = skip_ws_and_comments(src, i)
        if j >= n:
            return i
        if src[j] == "{":
            return consume_trailing_closures(src, consume_balanced(src, j, "{", "}"))
        m = IDENT.match(src, j)
        if m:
            k = skip_ws_and_comments(src, m.end())
            if k < n and src[k] == ":":
                k = skip_ws_and_comments(src, k + 1)
                if k < n and src[k] == "{":
                    return consume_trailing_closures(
                        src, consume_balanced(src, k, "{", "}")
                    )
        return i


def consume_call(src, i):
    """i points at the start of `Button`. Return the index after the whole call."""
    j = skip_ws_and_comments(src, i + len("Button"))
    n = len(src)
    if j < n and src[j] == "(":
        j = consume_balanced(src, j, "(", ")")
    return consume_trailing_closures(src, j)


def match_skip(src, i):
    for starter in SKIP_STARTERS:
        if not src.startswith(starter, i):
            continue
        end = i + len(starter)
        if starter[-1].isalpha() and end < len(src) and (src[end].isalnum() or src[end] == "_"):
            continue
        return end
    return None


def skip_ranges(src):
    """Character ranges of trailing closures on alerts, toolbars, menus, …"""
    ranges = []
    n = len(src)
    i = 0
    in_str = None
    escape = False
    line_comment = False
    block_comment = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if c == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == in_str:
                in_str = None
            i += 1
            continue
        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if c in "\"'":
            in_str = c
            i += 1
            continue
        end = match_skip(src, i)
        if end is not None:
            j = skip_ws_and_comments(src, end)
            if j < n and src[j] == "(":
                j = consume_balanced(src, j, "(", ")")
            after = consume_trailing_closures(src, j)
            if after > j:
                ranges.append((j, after))
                i = after
            else:
                i = max(end, j)
            continue
        i += 1
    return ranges


def in_skip(ranges, pos):
    return any(a <= pos < b for a, b in ranges)


def line_number(src, pos):
    return src.count("\n", 0, pos) + 1


def button_starts(src):
    """`Button(` / `Button {` in code, not comments, strings, or type names."""
    n = len(src)
    i = 0
    in_str = None
    escape = False
    line_comment = False
    block_comment = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if c == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == in_str:
                in_str = None
            i += 1
            continue
        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if c in "\"'":
            in_str = c
            i += 1
            continue
        if src.startswith("Button", i):
            prev = src[i - 1] if i > 0 else ""
            if not (prev.isalnum() or prev == "_"):
                j = skip_ws_and_comments(src, i + len("Button"))
                if j < n and src[j] in "({":
                    yield i
                    i = j
                    continue
        i += 1


vocab = set(
    re.findall(r"^\s{4}case (\w+)$", open(f"{SRC}/Design/ActionIcon.swift").read(), re.M)
)
bad = []
used = set()

for root, _, files in os.walk(SRC):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        p = os.path.join(root, f)
        src = open(p).read()
        ranges = skip_ranges(src)
        for start in button_starts(src):
            end = consume_call(src, start)
            snippet = src[start:end]
            for um in re.finditer(r'Button\("[^"]*",\s*\.(\w+)', snippet):
                used.add(um.group(1))
            for um in re.finditer(r"ActionIcon\.(\w+)", snippet):
                used.add(um.group(1))
            if in_skip(ranges, start):
                continue
            if GLYPH.search(snippet):
                continue
            if allowed(p, snippet):
                continue
            first = snippet.split("\n", 1)[0].strip()[:88]
            bad.append(f"{p}:{line_number(src, start)}  {first}")

unknown = sorted(used - vocab)
for u in unknown:
    bad.append(f'{SRC}/Design/ActionIcon.swift  no case for ".{u}"')

if bad:
    print("\n".join(bad))
    print(f"\n{len(bad)} button(s) with no glyph — give each one an ActionIcon, or,")
    print("if it is a tappable row or tile, add it to ALLOWED in this script.")
    sys.exit(1)
print("Every content button carries a glyph from the vocabulary.")
PY
