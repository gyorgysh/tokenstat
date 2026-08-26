#!/usr/bin/env bash
# Every font in the app comes from the type scale, not from the system.
#
# The app is drawn in Manrope and JetBrains Mono, bundled and registered at
# launch (apps/mac/Sources/Design/AppFonts.swift). A `.font(.caption)` or a
# `.system(size: 13)` left in a view is a control drawn in a different typeface
# from the one beside it, which is the same class of bug as a `Color.blue` in a
# purple app and is caught the same way.
#
# Use `Theme.caption`, `Theme.callout`, `Theme.font(13, weight: .medium)`,
# `Theme.fit(13)` for the Mac's window-scaled chrome, `Theme.mono` and
# `Theme.monoText` for anything read character by character, and
# `Theme.numeric` for a column of figures. On the client, `ClientType`.
#
#   scripts/check-fonts.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib, re, sys

SRC = pathlib.Path("apps/mac/Sources")

# The two files that are allowed to name a system font: the type scale itself,
# and the fallback used when the bundled faces fail to register.
ALLOWED = {"Design/Theme.swift", "Design/AppFonts.swift"}

STYLES = ("largeTitle", "title", "title2", "title3", "headline", "subheadline",
          "body", "callout", "footnote", "caption", "caption2")

BARE_STYLE = re.compile(r"\.font\(\.(" + "|".join(STYLES) + r")\b")
SYSTEM = re.compile(r"(?<!TransportFailure)\.system\(\s*(size:|\.)")

bad = []
for path in sorted(SRC.rglob("*.swift")):
    rel = str(path.relative_to(SRC))
    if rel in ALLOWED:
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if BARE_STYLE.search(line):
            bad.append((rel, number, line.strip(), "use Theme's text style"))
        elif SYSTEM.search(line):
            bad.append((rel, number, line.strip(), "use Theme.font / Theme.fit / Theme.monoText"))

if bad:
    print("Fonts must come from the type scale:\n")
    for rel, number, line, hint in bad:
        print(f"  apps/mac/Sources/{rel}:{number}")
        print(f"    {line}")
        print(f"    -> {hint}\n")
    sys.exit(1)

print("Every font comes from the type scale.")
PY
