#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare synthetic UTC day positions against the original Swift axis."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def run(args, data=None):
    result = subprocess.run(args, cwd=ROOT, input=data, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stderr}")
    return result.stdout

def main():
    run(["cargo","build","--manifest-path","apps/linux/Cargo.toml","--no-default-features","--locked","--example","insight-axis-contract"])
    rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/insight-axis-contract")]))
    with tempfile.TemporaryDirectory(prefix="tokenstat-insight-axis-") as temp:
        binary = Path(temp) / "reference"
        run(["xcrun","swiftc","-parse-as-library","apps/mac/Sources/Features/Insights/InsightDayAxis.swift","apps/linux/reference/InsightAxisReference.swift","-o",str(binary)])
        swift = json.loads(run([str(binary)], json.dumps(rust)))
    assert rust == swift, f"Day axis differs:\nSwift {swift}\nRust {rust}"
    print(f"PASS: original InsightDayAxis positions for {len(rust)} synthetic dates")

if __name__ == "__main__":
    main()
