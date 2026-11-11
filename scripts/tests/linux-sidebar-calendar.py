#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run Swift-derived calendar fixtures on Linux or macOS, without Swift."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    subprocess.run(["cargo", "build", "--quiet", "--manifest-path", str(ROOT / "apps/linux/Cargo.toml"), "--no-default-features", "--example", "sidebar-calendar-contract", "--locked"], cwd=ROOT, check=True)
    binary = ROOT / "apps/linux/target/debug/examples/sidebar-calendar-contract"
    cases = json.loads((ROOT / "apps/linux/reference/sidebar-calendar.json").read_text())
    count = 0
    for case in cases:
        env = os.environ.copy()
        env["TZ"] = case["zone"]
        result = json.loads(subprocess.check_output([str(binary)], input=json.dumps(case["fixture"]).encode(), env=env))
        if result != case["expected"]:
            for timestamp, expected, actual in zip(case["fixture"]["timestamps_ms"], case["expected"], result):
                if expected != actual:
                    raise AssertionError(f"{case['zone']} {timestamp}: expected {expected}, got {actual}")
            raise AssertionError(f"{case['zone']}: different result counts")
        count += len(result)
    print(f"PASS: {count} Swift-derived local calendar cases")


if __name__ == "__main__":
    main()
