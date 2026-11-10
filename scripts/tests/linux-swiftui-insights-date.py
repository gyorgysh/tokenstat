#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare source InsightsModel's calendar query in isolated time zones."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

def run(args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=90, check=True)
    return result.stdout

def main():
    owner = contract.declaration("Features/Insights/InsightsModel.swift", "final class InsightsModel {")
    period = contract.declaration_text(owner, "enum Period: String, CaseIterable, Identifiable {")
    query = contract.declaration_text(owner, "var query: Query {").replace("Date()", "now")
    formatter = contract.declaration_text(owner, "private static let dateFormatter: DateFormatter = {") + "()"
    swift = f'''import Foundation
struct Query {{ var since: String? = nil; var until: String? = nil; var billing: String? = nil }}
final class Reference {{
{period}
var period: Period = .all
var focusedDay: String? = nil
var now = Date()
{query}
{formatter}
}}
let model = Reference()
let values = CommandLine.arguments.dropFirst().map {{ argument -> [String] in
    model.now = Date(timeIntervalSince1970: Double(argument)!)
    return [Reference.Period.week, .month, .quarter].map {{ model.period = $0; return model.query.since! }}
}}
let bytes = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
print(String(data: bytes, encoding: .utf8)!)
'''
    timestamps = ["1709163000", "1710055800", "1711845000", "1730611800", "1743291000", "1761442200"]
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features", "--locked", "--example", "insights-date-contract"])
    with tempfile.TemporaryDirectory(prefix="tokenstat-insights-calendar-") as temp:
        source, binary = Path(temp) / "Reference.swift", Path(temp) / "reference"
        source.write_text(swift)
        run(["xcrun", "swiftc", str(source), "-o", str(binary)])
        for zone in ["UTC", "Europe/Budapest", "America/New_York", "Australia/Sydney"]:
            env = {**os.environ, "TZ": zone}
            rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/insights-date-contract"), *timestamps], env))
            original = json.loads(run([str(binary), *timestamps], env))
            assert rust == original, f"{zone}: Rust {rust}, Swift {original}"
    print("PASS: 72 source calendar queries across UTC, Budapest, New York and Sydney")

if __name__ == "__main__":
    main()
