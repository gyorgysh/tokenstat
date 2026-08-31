#!/usr/bin/env bash
#
# Chrome rows meet at a shared optical baseline.
#
# A 40pt header with a 3pt bottom inset centres its contents 1.5pt above a
# plain 40pt header. `chromeBarMetrics()` owns those values so a destination
# cannot quietly recreate one half of the equation. This inexpensive source
# gate catches the only hand-written height that would make adjacent headers
# drift again.
set -euo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path("apps/mac/Sources")
HEIGHT = re.compile(r"\.frame\(height:\s*DetailChromeBarHeight\)")

problems = []
for path in ROOT.rglob("*.swift"):
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        if not HEIGHT.search(line):
            continue
        nearby = "\n".join(lines[max(0, index - 4):index + 1])
        # The modifier is the one owner of the literal height. Every caller
        # must use it instead of recreating this frame locally.
        owns_metric = path.name == "Theme.swift" and "struct ChromeBarMetrics" in "\n".join(lines[:index])
        if ".chromeBarMetrics()" not in nearby and not owns_metric:
            problems.append((path, index + 1, line.strip()))

if not problems:
    print("Every fixed-height chrome row uses the shared metrics.")
    raise SystemExit(0)

for path, line, source in problems:
    print(f"{path}:{line}  {source}")
    print("    ^ use .chromeBarMetrics() so adjacent headers share a baseline")
print()
print(f"{len(problems)} chrome row(s) bypass the shared metric.")
raise SystemExit(1)
PY
