#!/usr/bin/env bash
#
# Flag dependency licence expressions outside the project allowlist.
#
# The repository uses a custom source-available licence. pueev OÜ distributes
# official builds using its own rights and the additional contributor grant.
# Dependencies must have terms compatible with this distribution model.
# The allowlist is a conservative screening policy; passing it does not remove
# third-party attribution, source-disclosure or other licence obligations.
#
# MPL-2.0 is deliberately allowed. Its copyleft is per file, and section 3.3
# explicitly permits combining into a "Larger Work" under other terms. Modified
# MPL files must still be published, which is a per-file obligation, not a
# reason to refuse the dependency.
#
# A dual licensed crate passes if any one of its alternatives is clean. A crate
# offered as "MIT OR Apache-2.0 OR LGPL-2.1-or-later" can be used under MIT.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Report metadata failures separately from licence-policy failures.
if ! metadata="$(cargo metadata --format-version 1 --all-features)"; then
    echo "error: cargo metadata failed, so no licence conclusion can be drawn" >&2
    exit 2
fi

report="$(printf '%s' "$metadata" | python3 -c '
import json, sys
sys.path.insert(0, "scripts")
from licence_rules import clean_license

meta = json.load(sys.stdin)
packages = {p["id"]: p for p in meta["packages"]}
nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}

# Every workspace member, not just the one the app links. The CLI, the daemon
# and the MCP server ship on the same terms as the app.
roots = list(meta["workspace_members"])

linked = set()
def walk(pid):
    if pid in linked:
        return
    linked.add(pid)
    for dep in nodes[pid]["deps"]:
        walk(dep["pkg"])
for r in roots:
    walk(r)

problems = []
for pid in sorted(linked):
    p = packages[pid]
    # Workspace members use the repository licence; review contributions separately.
    if pid in meta["workspace_members"]:
        continue
    lic = p.get("license") or ""
    if not lic:
        problems.append((p["name"], p.get("license_file") or "no licence declared"))
        continue
    # "A OR B" leaves the choice to us, so one clean alternative is enough.
    if clean_license(lic):
        continue
    problems.append((p["name"], lic))

print(f"linked:{len(linked)}")
for name, lic in problems:
    print(f"problem:{name}:{lic}")
')"

count="$(printf '%s\n' "$report" | sed -n 's/^linked://p')"
problems="$(printf '%s\n' "$report" | sed -n 's/^problem://p' || true)"

if [ -z "$count" ]; then
    echo "error: could not resolve the workspace dependency tree" >&2
    exit 2
fi

if [ -n "$problems" ]; then
    echo "error: dependencies requiring licence review:" >&2
    # Read line by line rather than expanding unquoted. An SPDX expression like
    # "Apache-2.0 OR MIT" contains spaces, and word splitting turns one finding
    # into three unreadable ones.
    printf '%s\n' "$problems" | while IFS=: read -r name lic; do
        [ -n "$name" ] || continue
        printf '  %-28s %s\n' "$name" "$lic" >&2
    done
    cat >&2 <<'MSG'

These dependencies need review for compatibility with tokenstat's custom
licence and official distribution terms. Their own licence obligations still
apply; repository ownership and contribution grants do not override them.

Review the applicable terms before release. Use a compatible dependency or
obtain the required permissions if the current terms do not allow distribution.
MSG
    exit 1
fi

echo "ok: $count packages checked; no licence expressions outside the allowlist"
