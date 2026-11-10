#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare original SwiftUI first-scan step choices against Linux state.

Synthetic states only; no window, host, account, archive or preferences.
This is a state comparison, not a visual or native Linux acceptance test.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def run(args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stderr}")
    return result.stdout

def main():
    source = (ROOT / "apps/mac/Sources/Features/Home/GettingStartedCard.swift").read_text()
    before = "private var steps: [GettingStartedStep]"
    assert source.count(before) == 1
    source = source.replace(before, "var steps: [GettingStartedStep]")
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features",
         "--locked", "--example", "getting-started-contract"])
    rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/getting-started-contract")]))
    with tempfile.TemporaryDirectory(prefix="tokenstat-getting-started-") as temp:
        temp = Path(temp)
        card = temp / "GettingStartedCard.swift"
        card.write_text(source)
        binary = temp / "reference"
        run(["xcrun", "swiftc", "-parse-as-library", str(card),
             "apps/linux/reference/GettingStartedReference.swift", "-o", str(binary)])
        swift = json.loads(run([str(binary)]))
    assert rust == swift, f"First-scan state differs:\nSwift {swift}\nRust {rust}"
    print("PASS: original SwiftUI first-scan card: 8 states / 24 steps and action closures")

if __name__ == "__main__":
    main()
