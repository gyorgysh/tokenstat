#!/usr/bin/env bash
#
# Fail if a dependency would make the desktop app undistributable.
#
# The apps in `apps/` are source-available, not open source: pueev OÜ ships the
# only builds. That works because pueev owns every `tokenstat-*` crate and can
# license its own combined work however it likes. It stops working the moment a
# *third party* copyleft dependency appears in the link tree, because then the
# combined binary could only ever be conveyed under that party's terms.
#
# The failure mode is silent and late: everything builds, tests pass, and the
# problem only surfaces when someone reads the licence of a transitive crate
# picked up months earlier. So it is checked here instead.
#
# MPL-2.0 is deliberately allowed. Its copyleft is per file, and section 3.3
# explicitly permits combining into a "Larger Work" under other terms. Modified
# MPL files must still be published, which is a per-file obligation, not a
# reason to refuse the dependency.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Everything the app links, walked from the crate the app actually depends on.
ROOT_CRATE="tokenstat-ffi"

# Resolved first, and checked, rather than piped straight into python. When
# `cargo metadata` fails the pipeline would otherwise surface as a decode error
# and exit 1, which reads exactly like a licence violation and sends whoever is
# debugging it in precisely the wrong direction.
if ! metadata="$(cargo metadata --format-version 1 --filter-platform aarch64-apple-darwin)"; then
    echo "error: cargo metadata failed, so no licence conclusion can be drawn" >&2
    exit 2
fi

report="$(printf '%s' "$metadata" | python3 -c '
import json, sys

meta = json.load(sys.stdin)
packages = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}

root = next(p["id"] for p in meta["packages"] if p["name"] == "'"$ROOT_CRATE"'")

linked = set()
def walk(pid):
    if pid in linked:
        return
    linked.add(pid)
    for dep in nodes[pid]["deps"]:
        walk(dep["pkg"])
walk(root)

# Blocks shipping a proprietary binary built on top.
BLOCKING = ("GPL", "AGPL", "LGPL", "EUPL", "CDDL", "OSL", "SSPL", "CC-BY-SA")
# Fine to link into a closed binary. MPL is per-file copyleft; see the header.
ALLOWED_COPYLEFT = ("MPL-2.0",)

problems = []
for pid in sorted(linked):
    p = packages[pid]
    # pueev owns these, so their GPL grant to the public does not bind pueev.
    if p["name"].startswith("tokenstat-"):
        continue
    lic = p.get("license") or ""
    if not lic:
        problems.append((p["name"], p.get("license_file") or "no licence declared"))
        continue
    upper = lic.upper()
    if any(a.upper() in upper for a in ALLOWED_COPYLEFT):
        continue
    if any(b in upper for b in BLOCKING):
        problems.append((p["name"], lic))

print(f"linked:{len(linked)}")
for name, lic in problems:
    print(f"problem:{name}:{lic}")
')"

count="$(printf '%s\n' "$report" | sed -n 's/^linked://p')"
problems="$(printf '%s\n' "$report" | sed -n 's/^problem://p' || true)"

if [ -z "$count" ]; then
    echo "error: could not resolve the dependency tree for $ROOT_CRATE" >&2
    exit 2
fi

if [ -n "$problems" ]; then
    echo "error: dependencies that would make the app undistributable:" >&2
    # Read line by line rather than expanding unquoted. An SPDX expression like
    # "Apache-2.0 OR MIT" contains spaces, and word splitting turns one finding
    # into three unreadable ones.
    printf '%s\n' "$problems" | while IFS=: read -r name lic; do
        [ -n "$name" ] || continue
        printf '  %-28s %s\n' "$name" "$lic" >&2
    done
    cat >&2 <<'MSG'

The apps in apps/ are shipped only by pueev OÜ, which works because pueev owns
every tokenstat crate. A third party copyleft dependency removes that: the
combined binary could then only be conveyed under that party's terms.

Either drop the dependency, or move whatever needs it behind a boundary the
app does not link.
MSG
    exit 1
fi

echo "ok: $count linked packages, none block shipping the app"
