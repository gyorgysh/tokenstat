#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare the live sidebar collation adapter to Foundation's source APIs."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SWIFT = '''import Foundation
let names = ["alpha", "Alpha", "file2", "file10", "café", "cafe", "café", "Straße", "strasse", "æther", "Œuvre", "istanbul", "İstanbul", "東京", "🐧", "a-b", "a b", "file02", "Γειά", "γειά", "नमस्ते", "नमसत", "résumé", "resume", "🧑‍💻", "中文", "file٢", "file٠٢", "file２"]
let queries = ["", "A", "CAFE", "strasse", "ae", "oe", "istanbul", "-", "東京", "🐧", "ss", "ΓΕΙΑ", "नमस्ते", "नमसत", "resume", "中文", "2"]
let order = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
let matches = queries.map { q in names.map { $0.range(of:q,options:[.caseInsensitive,.diacriticInsensitive]) != nil } }
let result: [String:Any] = ["locale":Locale.current.identifier, "names":names, "queries":queries, "order":order, "matches":matches]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
'''

def main():
    (ROOT / "target").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "target") as tmp:
        path = Path(tmp)
        (path / "Reference.swift").write_text(SWIFT)
        subprocess.run(["swiftc", str(path / "Reference.swift"), "-o", str(path / "reference")], check=True)
        swift = json.loads(subprocess.check_output([str(path / "reference")]))
    output = subprocess.check_output(["cargo", "run", "--quiet", "--manifest-path", str(ROOT / "apps/linux/Cargo.toml"), "--no-default-features", "--example", "sidebar-collation-contract", "--locked"], input=json.dumps(swift).encode(), cwd=ROOT)
    rust = json.loads(output)
    if swift["order"] != rust["order"]:
        raise AssertionError(f"ordering for {swift['locale']}: Swift {swift['order']!r} != Rust {rust['order']!r}")
    for query, expected, actual in zip(swift["queries"], swift["matches"], rust["matches"]):
        if expected != actual:
            raise AssertionError(f"query {query!r}: Swift {expected!r} != Rust {actual!r}")
    print(f"PASS: actual sidebar collation matches Foundation for {len(swift['names'])} names and {len(swift['queries'])} queries in {swift['locale']}")

if __name__ == "__main__":
    main()
