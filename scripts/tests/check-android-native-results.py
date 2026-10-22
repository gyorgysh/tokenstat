#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Fail when a selected native suite was omitted by the test runner."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root, expected = Path(sys.argv[1]), sys.argv[2]
matched = 0
for path in root.rglob("*.xml"):
    tree = ET.parse(path)
    for case in tree.iter("testcase"):
        if case.attrib.get("classname") != expected:
            continue
        if any(case.find(tag) is not None for tag in ("failure", "error", "skipped")):
            raise SystemExit(f"Native suite did not pass: {expected}")
        matched += 1
if matched == 0:
    raise SystemExit(f"Native suite did not run: {expected}")
print(f"Native suite verified: {expected} ({matched} tests)")
