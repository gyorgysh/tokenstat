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
    # The branch chip/card and each branch are whole-surface controls. Their
    # labels already carry the branch/check glyph; another action glyph would
    # duplicate the mark instead of clarifying the action.
    ("Features/Workspaces/BranchPicker.swift", "Button { isPresented = true } label:"),
    ("Features/Workspaces/BranchPicker.swift", "Task { await checkout(branch) }"),
    ("Features/Automations/AutomationsView.swift", "Button(action, action: perform)"),
    ("Features/Workflows/WorkflowsView.swift", "Button(action: onSelect)"),
    ("Features/Workflows/WorkflowsView.swift", "onSelect?(node.id)"),
    ("Features/Workflows/WorkflowsEditor.swift", "model.addNode(kind:"),
    ("Features/Workflows/WorkflowCanvas.swift", "model.addNode(kind:"),
    ("Features/Workflows/WorkflowCanvas.swift", "onPick()"),
    ("Features/Workflows/WorkflowRecipes.swift", "onPick(recipe)"),
    ("Features/Automations/AutomationsView.swift", "Text(dayShort[bit])"),
    ("Features/Automations/AutomationsView.swift", "scheduleKind = kind"),
    ("Features/Automations/AutomationsView.swift", "intervalMinutes = String(minutes)"),
    ("Features/Automations/AutomationsView.swift", "scheduleWeekday = day.0"),
    ("Features/Terminals/TerminalPane.swift", "start(profile)"),
    # A menu row inside content. The platform draws the menu and its
    # selection mark, exactly as it does for the main menu, so an action
    # glyph on each conversation would be a second mark competing with it.
    ("Features/Workspaces/Chat/ChatView.swift", "await model.select(conversation)"),
    # Whole-surface controls: the tag is the label. A starting point fills the
    # field it sits under, and "Show more" reveals the rows below it, so in
    # both cases a glyph would name an action the surface already is.
    ("Features/Workspaces/Chat/PersonaEditor.swift", "draft.systemPrompt = point.1"),
    ("App/RootView.swift", "expandedChatHistories"),
    # The busy variant of the editor footer's action. It carries a glyph when
    # it is idle; while a request is in flight the spinner stands in for it.
    ("Features/Machines/SSHLibraryEditors.swift", "ProgressView().controlSize(.small)"),
    # A segmented tab. The whole surface is the label, like a sidebar row.
    ("Design/Theme.swift", "withAnimation(.snappy(duration: 0.22)) { selection = option }"),
    ("Client/AvatarButton.swift", "Button(action: action)"),
    ("Client/ClientHostWorkspacesView.swift", "model.open(session, peer: peerKey)"),
    ("Client/ClientLaunchTile.swift", "Button(action: action)"),
    ("Client/ClientLoginView.swift", "Button(title) {"),
    ("Client/ClientOnboarding.swift", 'Button("Skip")'),
    # Billing interval is a two-option segmented pill. The text is the whole
    # label, as with the shared segmented control allowlisted above.
    ("Client/ClientPaywallView.swift", "bill = value"),
    # The rail's step button. The glyph is an ActionIcon like everywhere else,
    # it just arrives as the step's own field rather than spelled at the call
    # site, because one component draws every step.
    ("Design/GettingStartedRail.swift", "Button(title, icon, action: action)"),
    ("Client/ClientSecurityCard.swift", "UIPasteboard.general.string = key"),
    ("Client/ClientStates.swift", 'Button(showingDetail ?'),
    ("Client/ClientWorkspaceDetailView.swift", "openExisting(session)"),
    # A launcher destination tile. The browser glyph is inside the shared
    # `ClientLauncherDestinationTile`, so adding another to the Button would
    # draw the same symbol twice.
    ("Client/ClientWorkspaceDetailView.swift", "Button { showPort = true } label:"),
    # Keycaps on the terminal accessory bar: the label is the key, and a
    # glyph beside "esc" or "⇧⇥" would be a second symbol for one keystroke.
    ("Client/ClientTerminalKeys.swift", "Button(action: action) {"),
    # Keycaps on the screen viewer's accessory bar, same as the terminal's:
    # the label is the key, and a glyph beside "cmd" would be a second symbol
    # for one keystroke.
    ("Features/Machines/ScreenInputSurface.swift", "modifiers ^= flag"),
    # The pointer keycaps in the same strip, beside ctrl and cmd. "click" and
    # "drag" are keys on that bar and read as keys: a glyph on one of them
    # would be a second symbol for one press, in a row that is all text.
    ("Features/Machines/ScreenInputSurface.swift", "pointer.click(0, 1)"),
    ("Features/Machines/ScreenInputSurface.swift", "pointer.click(0, 2)"),
    ("Features/Machines/ScreenInputSurface.swift", "pointer.click(1, 1)"),
    ("Features/Machines/ScreenInputSurface.swift", "pointer.toggleDrag()"),
    ("Features/Machines/ScreenInputSurface.swift", "pointer.toggleFine()"),
    ("Features/Machines/ScreenInputSurface.swift", "pointer.resetZoom()"),
    # A session tab on the phone's SSH terminal. The whole button is the
    # session's name and its live dot, and every tab carrying the same glyph
    # would be one symbol repeated across a strip that is already a strip.
    ("Features/Machines/SSHLiveTerminal.swift", "sessions.select(other)"),
    # A colour swatch. The whole button is the colour, and a glyph on top of it
    # would hide the one thing it is showing.
    ("Features/Machines/SSHLibraryEditors.swift", "selection = selection == name ? nil : name"),

    # A toast's inline way to the thing it just named. Same class as an
    # alert action: the platform's own convention is text.
    ("Design/Theme.swift", "Button(actionLabel) {"),

    # Invisible carriers for the iPad's keyboard shortcuts. They are never
    # drawn, and their titles are what the system lists when Command is held.
    ("Client/ClientShortcuts.swift", "Button(command.title) {"),

    # A whole row is the target: the section list on the phone, and the
    # sidebar group heading on the Mac, where the label is the button.
    ("Client/ClientWorkspaceSections.swift", "showPort = true"),
    ("Client/ClientFolderSplit.swift", "section = item"),
    ("Client/ClientWorkflowWorkspace.swift", "session.selectGraph"),
    ("Client/ClientWorkflowWorkspace.swift", "session.selectRun"),
    ("Client/ClientAutomationWorkspace.swift", "session.selectJob"),
    ("Client/ClientAutomationWorkspace.swift", "session.selectRun"),
    ("Client/ClientWorkflowRunView.swift", "session.selectNode"),
    ("App/RootView.swift", "Button(action: toggle) {"),
    ("Client/ClientWorkspacesView.swift", "model.openSession(session)"),
    ("Client/ClientWorkspaceNotesView.swift", "startEditing(note)"),
    # The iPad sidebar's tree. A folder, one of its sections and a session in
    # it are each a whole row: the glyph is inside the label the row draws,
    # and a second one on the button would be the same mark twice.
    ("Client/ClientSidebarRoot.swift", "folderLabel(folder)"),
    ("Client/ClientSidebarRoot.swift", "sectionLabel(section, in: folder)"),
    ("Client/ClientSidebarRoot.swift", "sessionLabel(session)"),
    ("Client/PhoneHeatmap.swift", "onSelect?(day)"),
    # Whole-row launch into the SSH library. The terminal glyph is already
    # inside the label, and a second one on the button would duplicate it.
    ("Features/Machines/MachinesView.swift", "onNavigate?(.ssh)"),
    # The vault screen's one decision row. The glyph is the `icon` parameter,
    # typed as ActionIcon, so the compiler already enforces what this script
    # checks; it just cannot read a glyph it is handed rather than told.
    ("Features/Machines/SSHVaultView.swift", "Button(button, icon, action: perform)"),
    ("Design/Theme.swift", "Button(title) { isOn.toggle() }"),
    ("Design/Theme.swift", "Button(title) { action() }"),
    ("Design/Theme.swift", "selection = option.value"),
    # Composer plan / execute / ask / bypass pills. The whole surface is the
    # word, like the segmented tabs in Theme.swift. A glyph on Plan would be
    # a second mark next to a control that is already a pill.
    ("Features/Workspaces/Chat/ChatSetupHeader.swift", "selection = option.value"),
    # Whole-row persona pick. The ActionSeat already carries the glyph.
    ("Features/Workspaces/Chat/PersonaEditor.swift", "draft = persona"),
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
