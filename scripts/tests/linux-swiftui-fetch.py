#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare original remote-fetch body with held synthetic transport/refresh."""
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
    original = contract.declaration("Features/Insights/InsightsModel.swift", "func fetchRemotes() async {")
    harness = (ROOT / "apps/linux/reference/FetchLifecycleReference.swift").read_text()
    assert harness.count("// ORIGINAL_FETCH_METHOD") == 1
    harness = harness.replace("// ORIGINAL_FETCH_METHOD", original)
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features", "--locked", "--example", "fetch-lifecycle-contract"])
    rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/fetch-lifecycle-contract")]))
    with tempfile.TemporaryDirectory(prefix="tokenstat-fetch-reference-") as temp:
        source = Path(temp) / "Reference.swift"
        binary = Path(temp) / "reference"
        source.write_text(harness)
        run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)])
        swift = json.loads(run([str(binary)]))
    assert rust == swift, f"Fetch lifecycle differs:\nSwift {swift}\nRust {rust}"
    print("PASS: original remote fetch lifecycle: 4 scenarios and held async checkpoints")

if __name__ == "__main__":
    main()
