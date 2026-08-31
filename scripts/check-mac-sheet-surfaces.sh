#!/usr/bin/env bash
#
# App-owned Mac task sheets share one surface.
#
# A new `.sheet` in the Mac app that is not a large viewer or a native
# platform prompt must present `ThemedSheet` (or `ModalHeader` /
# `modalFrame`). This is the cheap source gate for the anatomy in
# `apps/mac/Sources/Design/ThemedSheet.swift`. 32pt body padding is the
# air; hugging copy with 0pt inset is the failure this exists to catch.
#
#   scripts/check-mac-sheet-surfaces.sh
set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path("apps/mac/Sources")
THEME = ROOT / "Design" / "Theme.swift"

# Large viewers and native iOS-only surfaces. Task sheets do not belong here.
VIEWERS = {
    "ScreenViewerView",
}

SURFACE = re.compile(r"ThemedSheet\s*\(|ModalHeader\s*\(|\.modalFrame\s*\(")
SHEET_CALL = re.compile(r"\.sheet\s*(?=\()")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
KEYWORDS = {
    "if", "let", "var", "guard", "switch", "for", "while", "return", "self",
    "true", "false", "nil", "in", "as", "try", "await", "Some", "Any", "View",
    "Binding", "Text", "Image", "EmptyView", "Group", "VStack", "HStack",
    "NavigationStack", "Spacer",
}

problems = []


def blank_line(line: str) -> str:
    if line.endswith("\n"):
        return " " * (len(line) - 1) + "\n"
    return " " * len(line)


def eval_platform(cond: str) -> bool | None:
    cond = cond.strip()
    if cond == "os(iOS)" or cond == "!os(macOS)":
        return False
    if cond == "os(macOS)" or cond == "!os(iOS)":
        return True
    return None


def macos_source(src: str) -> str:
    """Keep regions the Mac compile sees. Blank iOS-only branches."""
    lines = src.splitlines(keepends=True)
    out = []
    # Each frame: parent_active, then_keep (bool or None for unknown).
    stack: list[tuple[bool, bool | None]] = []
    emitting = True

    def parent_active() -> bool:
        return all(frame[0] for frame in stack) if stack else True

    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("#if"):
            cond = stripped[3:].strip()
            keep = eval_platform(cond)
            parent = emitting
            if keep is None:
                child = parent
            else:
                child = parent and keep
            stack.append((child, keep))
            emitting = child
            out.append(line if emitting else blank_line(line))
        elif stripped.startswith("#else"):
            if stack:
                child, then_keep = stack[-1]
                parent = parent_active() if len(stack) == 1 else stack[-2][0] if len(stack) > 1 else True
                # Reconstruct parent from the stack without the current frame.
                parent = all(frame[0] for frame in stack[:-1]) if len(stack) > 1 else True
                if then_keep is None:
                    child = parent
                else:
                    child = parent and not then_keep
                stack[-1] = (child, then_keep)
                emitting = child
            out.append(line if emitting else blank_line(line))
        elif stripped.startswith("#endif"):
            out.append(line if emitting else blank_line(line))
            if stack:
                stack.pop()
            emitting = all(frame[0] for frame in stack) if stack else True
        else:
            out.append(line if emitting else blank_line(line))
    return "".join(out)


def skip_ws_and_comments(src: str, i: int) -> int:
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


def consume_string(src: str, i: int) -> int:
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


def consume_balanced(src: str, i: int, open_ch: str, close_ch: str) -> int:
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


def consume_trailing_closures(src: str, i: int) -> int:
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


def line_number(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def first_view_name(closure: str) -> str | None:
    rest = closure[closure.find("{") + 1 :] if "{" in closure else closure
    # Prefer a constructed type (`SSHConnectForm(`) over a local binding
    # (`if let recovery`).
    for name in re.findall(r"\b([A-Z][A-Za-z0-9_]*)\s*[\({]", rest):
        if name not in KEYWORDS:
            return name
    for name in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*Sheet)\b", rest):
        return name
    rest = rest.strip()
    param = re.match(
        r"^[A-Za-z_][A-Za-z0-9_]*(\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*\s+in\b", rest
    )
    if param:
        rest = rest[param.end() :]
    for m in IDENT.finditer(rest):
        name = m.group()
        if name in KEYWORDS:
            continue
        return name
    return None


def find_definition(name: str, files: list[tuple[Path, str]]) -> str | None:
    struct = re.compile(rf"\bstruct\s+{re.escape(name)}\b")
    var = re.compile(rf"\bvar\s+{re.escape(name)}\b")
    for path, src in files:
        for pat in (struct, var):
            m = pat.search(src)
            if not m:
                continue
            brace = src.find("{", m.end())
            if brace < 0:
                continue
            end = consume_balanced(src, brace, "{", "}")
            return src[m.start() : end]
    return None


theme = THEME.read_text()
if "static let bodyPadding: CGFloat = 32" not in theme:
    problems.append(
        f"{THEME}: Theme.Modal.bodyPadding must stay 32 so task sheets keep their air"
    )

swift_files: list[tuple[Path, str]] = []
for path in sorted(ROOT.rglob("*.swift")):
    if "Client" in path.parts:
        continue
    text = path.read_text()
    if "sshSheetFrame" in text:
        for index, line in enumerate(text.splitlines(), 1):
            if "sshSheetFrame" in line and not line.strip().startswith("//"):
                problems.append(
                    f"{path}:{index}  leftover sshSheetFrame. Use modalFrame / ThemedSheet."
                )
    swift_files.append((path, text))

for path, original in swift_files:
    src = macos_source(original)
    i = 0
    while True:
        m = SHEET_CALL.search(src, i)
        if not m:
            break
        j = skip_ws_and_comments(src, m.end())
        if j < len(src) and src[j] == "(":
            j = consume_balanced(src, j, "(", ")")
        end = consume_trailing_closures(src, j)
        block = src[m.start() : end]
        i = max(end, m.end())
        if SURFACE.search(block):
            continue
        name = first_view_name(block[block.find("{") :] if "{" in block else block)
        if name is None:
            problems.append(
                f"{path}:{line_number(src, m.start())}  sheet has no identifiable content"
            )
            continue
        if name in VIEWERS:
            continue
        definition = find_definition(name, swift_files)
        if definition and SURFACE.search(definition):
            continue
        problems.append(
            f"{path}:{line_number(src, m.start())}  .{name} sheet is not on ThemedSheet. "
            "Use ThemedSheet / ModalHeader, or add it to VIEWERS if it is a large viewer."
        )

if not problems:
    print("Every Mac task sheet uses the shared modal surface.")
    raise SystemExit(0)

for item in problems:
    print(item)
print()
print(f"{len(problems)} sheet surface problem(s).")
raise SystemExit(1)
PY
