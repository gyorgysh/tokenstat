#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare source inspector empty/archive and project grouping logic."""
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
    owner = contract.declaration("Features/Insights/InsightsModel.swift", "final class InsightsModel {")
    grouping = contract.declaration_text(owner, "private static func buildProjectHarnesses(")
    lookup = contract.declaration_text(owner, "func harnesses(inProject key: String)")
    empty = contract.declaration("Features/Insights/InspectorView.swift", "private var isEmptyArchive: Bool {")
    source = f'''import Foundation
struct Counters {{ var total: UInt64 }}
struct Totals {{ var events: UInt64 }}
struct Bucket {{ var key: String; var counters: Counters }}
struct SplitBucket {{ var key: String; var split: String; var counters: Counters }}
struct ProjectHarnesses {{ var path: String; var harnesses: [SplitBucket]; var tokens: UInt64 }}
final class Model {{
    var totals: Totals?
    var errorMessage: String?
    var isLoading = false
    var projectHarnesses: [ProjectHarnesses] = []
    {grouping}
    {lookup}
    func setProjects(_ projects: [Bucket], _ split: [SplitBucket]) {{
        projectHarnesses = Self.buildProjectHarnesses(projects: projects, split: split)
    }}
}}
struct Inspector {{
    var model: Model
    {empty}
    var result: Bool {{ isEmptyArchive }}
}}
let model = Model()
let cases: [(UInt64?,Bool,Bool)] = [(nil,false,false),(0,false,false),(0,true,false),(0,false,true),(1,false,false)]
let emptyValues = cases.map {{ (events,loading,error) -> Bool in
    model.totals = events.map {{ Totals(events:$0) }}
    model.isLoading = loading; model.errorMessage = error ? "offline" : nil
    return Inspector(model:model).result
}}
let projects = [Bucket(key:"café",counters:Counters(total:5)), Bucket(key:"empty",counters:Counters(total:5))]
let splits = [SplitBucket(key:"cafe\\u{{301}}",split:"first",counters:Counters(total:5)), SplitBucket(key:"other",split:"ignored",counters:Counters(total:5)), SplitBucket(key:"café",split:"second",counters:Counters(total:5))]
model.setProjects(projects,splits)
let inputs: [(Bool,String?)] = [(true,"cafe\\u{{301}}"),(true,"empty"),(true,"other"),(false,"café"),(true,nil)]
let groups = inputs.map {{ projectsTab, key -> [String] in
    guard projectsTab, let key else {{ return [] }}
    return model.harnesses(inProject:key).map(\\.split)
}}
let result = try! JSONSerialization.data(withJSONObject:["empty":emptyValues,"groups":groups], options:[.sortedKeys])
print(String(decoding:result,as:UTF8.self))
'''
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features", "--locked", "--example", "insights-inspector-contract"])
    rust = json.loads(run([str(ROOT / "apps/linux/target/debug/examples/insights-inspector-contract")]))
    with tempfile.TemporaryDirectory(prefix="tokenstat-inspector-reference-") as temp:
        path, binary = Path(temp) / "Reference.swift", Path(temp) / "reference"
        path.write_text(source)
        run(["xcrun", "swiftc", str(path), "-o", str(binary)])
        swift = json.loads(run([str(binary)]))
    assert rust == swift, f"Inspector differs:\nSwift {swift}\nRust {rust}"
    print("PASS: original inspector empty-archive and project harness rules: 10 cases")

if __name__ == "__main__":
    main()
