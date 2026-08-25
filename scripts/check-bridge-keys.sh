#!/usr/bin/env bash
#
# A bridge model spells its ids the way the host does.
#
# The host derives its JSON keys with `#[serde(rename_all = "camelCase")]`, so
# `folder_id` goes on the wire as `folderId`. Swift synthesizes its keys from
# the property name, so a property called `folderID` asks for a key nothing
# sends. Nothing at runtime reports the mismatch:
#
#   - an optional field arrives as nil, so a save appears to succeed while the
#     host writes nothing. Saved servers forgot their folder and their key on
#     every write for as long as this went unnoticed.
#   - a non-optional field throws, and `try?` at the call site turns the whole
#     list into an empty one. Snippets and trusted servers were always empty.
#
# So: any stored property whose name ends in `ID` or `IDs` needs an explicit
# CodingKeys entry, and that entry may not map it to an `…ID` key. Explicit is
# the whole point. `Machine.machineID = "id"` is right and `folderID` with no
# entry at all is wrong, and the difference is whether anybody decided.
# Computed properties are not on the wire and are skipped.
#
# `record_wire_keys_are_the_ones_clients_expect` in `ssh_records.rs` pins the
# same contract from the host's side. This one is the client's side.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import os
import re
import sys

ROOT = "apps/mac/Sources"

# Types whose `…ID` property is never on the wire, with the reason.
ALLOWED = {
    # Set by the app after the daemon answers, to record which peer a folder
    # came from. The daemon has no such field and never sends one.
    ("WorkspaceFolder", "machineID"),
}

DECL = re.compile(
    r"^\s*(?:public\s+)?(?:struct|final class|class)\s+(\w+)\s*:([^{]*)\{", re.M
)
# A stored property: `var name: Type`. A computed one is `var name: Type {`,
# and a `=` default still stores. The trailing brace is what separates them.
PROPERTY = re.compile(r"^\s*(?:var|let)\s+(\w+)\s*:\s*([^={]+?)\s*(?:=[^{]*)?$")
CODABLE = re.compile(r"\b(Codable|Decodable|Encodable)\b")


def bodies(source):
    """Yield (name, body) for every Codable type declared in `source`."""
    for match in DECL.finditer(source):
        name, conformances = match.group(1), match.group(2)
        if not CODABLE.search(conformances):
            continue
        index, depth = match.end(), 1
        while index < len(source) and depth:
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
            index += 1
        yield name, source[match.end() : index], source.count("\n", 0, match.start()) + 1


def wanted(name):
    """The wire spelling for a property name, or None when it needs no map."""
    if name.endswith("IDs"):
        return name[:-3] + "Ids"
    if name.endswith("ID"):
        return name[:-2] + "Id"
    return None


def main():
    problems = []
    for base, _, names in os.walk(ROOT):
        for filename in sorted(names):
            if not filename.endswith(".swift"):
                continue
            path = os.path.join(base, filename)
            source = open(path).read()
            for name, body, line in bodies(source):
                keys = body[body.index("CodingKeys") :] if "CodingKeys" in body else ""
                for raw in body.splitlines():
                    stripped = raw.strip()
                    if stripped.startswith("//") or stripped.startswith("case "):
                        continue
                    match = PROPERTY.match(raw)
                    if not match:
                        continue
                    prop = match.group(1)
                    spelling = wanted(prop)
                    if spelling is None or (name, prop) in ALLOWED:
                        continue
                    mapped = re.search(rf'\b{re.escape(prop)}\s*=\s*"([^"]*)"', keys)
                    if mapped is None:
                        problems.append((path, line, name, prop, spelling, "has no CodingKeys entry"))
                    elif wanted(mapped.group(1)) is not None:
                        problems.append((
                            path, line, name, prop, spelling,
                            f'is mapped to "{mapped.group(1)}", which the host never sends',
                        ))

    if not problems:
        print("Every bridge model spells its ids the way the host does.")
        return 0

    for path, line, name, prop, spelling, why in problems:
        print(f"{path}:{line}  {name}.{prop} {why}")
        print(f'    ^ add  case {prop} = "{spelling}"  (or the key the host really sends)')
    print()
    print(f"{len(problems)} propert(ies) asking the host for a key it does not send.")
    print("Add the CodingKeys entry, or, if the field is never on the wire, add")
    print("it to ALLOWED here with the reason.")
    return 1


sys.exit(main())
PY
