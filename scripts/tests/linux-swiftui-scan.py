#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare suspended original InsightsModel.scan against Linux scan phases.

The original scan body runs with synthetic Bridge, refresh and timer stubs.
No host, archive, account, preferences or GUI is opened.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

def run(args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stderr}")
    return result.stdout

def main():
    original = contract.declaration("Features/Insights/InsightsModel.swift", "func scan() async {")
    harness = (ROOT / "apps/linux/reference/ScanLifecycleReference.swift").read_text()
    assert harness.count("// ORIGINAL_SCAN_METHOD") == 1
    harness = harness.replace("// ORIGINAL_SCAN_METHOD", original)
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features", "--locked", "--example", "scan-lifecycle-contract"])
    rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/scan-lifecycle-contract")]))
    with tempfile.TemporaryDirectory(prefix="tokenstat-scan-reference-") as temp:
        source = Path(temp) / "Reference.swift"
        binary = Path(temp) / "reference"
        source.write_text(harness)
        run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)])
        swift = json.loads(run([str(binary)]))
    assert rust == swift, f"Scan lifecycle differs:\nSwift {swift}\nRust {rust}"
    print("PASS: original InsightsModel.scan: success, scan error, refresh error and held checkpoints")

if __name__ == "__main__":
    main()
