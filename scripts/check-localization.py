#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Validate native language catalogs and every literal resource reference."""
import json
import re
import sys
from pathlib import Path

from localization_rules import technical_uses

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "apps/localization"
PLATFORMS = {
    "apple": (ROOT / "apps/mac/Sources", "*.swift"),
    "android": (ROOT / "apps/android/app/src/main/java", "*.kt"),
    "windows": (ROOT / "apps/windows", "*.cs"),
}
errors = []


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


def read(path):
    try:
        values = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
        if not isinstance(values, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in values.items()):
            raise ValueError("expected an object of string keys and string values")
        return values
    except (ValueError, OSError) as error:
        errors.append(f"{path.relative_to(ROOT)}: {error}")
        return {}


def placeholders(value):
    # Includes native printf/.NET formatting still used by existing number helpers,
    # and workflow tokens embedded in app-owned starting prompts.
    return set(re.findall(r"\{\d+(?:,[+-]?\d+)?(?::[^{}]+)?\}|%[-+0-9.#]*[a-zA-Z]|\{\{[A-Za-z_][^{}]*\}\}", value))


english = {table: read(RESOURCES / "en" / f"{table}.json") for table in ("common", *PLATFORMS)}
used = {table: set() for table in english}
for platform, (directory, pattern) in PLATFORMS.items():
    available = english["common"] | english[platform]
    for path in directory.rglob(pattern):
        if any(part in {"obj", "bin"} for part in path.parts):
            continue
        source = path.read_text(encoding="utf-8")
        for offset, key in technical_uses(source):
            line = source.count("\n", 0, offset) + 1
            errors.append(f"{path.relative_to(ROOT)}:{line}: keep stable values separate from display copy ({key})")
        for match in re.finditer(r'L10n\.(?:text|Text)\s*\(\s*"([^"\n]+)"', source):
            key = match[1]
            line = source.count("\n", 0, match.start()) + 1
            if key not in available:
                errors.append(f"{path.relative_to(ROOT)}:{line}: missing English key {key}")
            else:
                used["common" if key.startswith("common.") else platform].add(key)
    for key in english[platform]:
        if re.match(r'^[a-z][A-Za-z0-9._-]*[:.-]\{\d+\}', english[platform][key]):
            errors.append(f"{platform}.json: identifier template must stay in code ({key})")
        if not key.startswith(platform + "."):
            errors.append(f"{platform}.json: incorrect key namespace {key}")
        if key not in used[platform] and not key.startswith("apple.enum."):
            errors.append(f"{platform}.json: unused key {key}")
for key in english["common"]:
    if not key.startswith("common.") or key not in used["common"]:
        errors.append(f"common.json: unused or incorrectly named key {key}")
for folder in RESOURCES.iterdir():
    if not folder.is_dir() or folder.name == "en":
        continue
    if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", folder.name):
        errors.append(f"{folder.relative_to(ROOT)}: use a BCP 47 language tag")
    for path in folder.glob("*.json"):
        if path.stem not in english:
            errors.append(f"{path.relative_to(ROOT)}: unknown platform table")
            continue
        for key, value in read(path).items():
            original = english[path.stem].get(key)
            if original is None:
                errors.append(f"{path.relative_to(ROOT)}: unknown key {key}")
            elif placeholders(value) != placeholders(original):
                errors.append(f"{path.relative_to(ROOT)}: changed placeholders for {key}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Native localization: {sum(map(len, english.values())):,} English entries and all source references passed.")
