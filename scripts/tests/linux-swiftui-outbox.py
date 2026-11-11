#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the original Swift outbox and Rust store over one private file."""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
def run(args):
    return subprocess.run([str(arg) for arg in args], cwd=root, text=True, capture_output=True, check=True, timeout=300).stdout
if sys.platform != "darwin":
    raise SystemExit("The original outbox uses Darwin; run the cross-language fixture on macOS.")
run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "outbox-contract"])
with tempfile.TemporaryDirectory(prefix="tokenstat-outbox-") as tmp:
    tmp = Path(tmp)
    attachment = tmp / "Attachment.swift"
    attachment.write_text("import Foundation\n" + contract.declaration("Bridge/Models.swift", "struct ChatAttachment:"))
    swift = tmp / "reference"
    run(["xcrun", "swiftc", "-parse-as-library", "apps/mac/Sources/Features/Work/WorkReference.swift", "apps/mac/Sources/Features/Work/OriginalFileCoordination.swift", "apps/mac/Sources/Features/Work/ChatOutboxStore.swift", "apps/linux/reference/OutboxStoreReference.swift", attachment, "-o", swift])
    rust = root / "apps/linux/target/debug/examples/outbox-contract"
    for order in [(rust, swift), (swift, rust)]:
        directory = tmp / ("rust-first" if order[0] == rust else "swift-first")
        directory.mkdir(mode=0o700)
        for binary in order:
            run([binary, "write", directory])
        rust_result = json.loads(run([rust, "read", directory]))
        swift_result = json.loads(run([swift, "read", directory]))
        def without_nulls(value):
            if isinstance(value, dict):
                return {key: without_nulls(item) for key, item in value.items() if item is not None}
            if isinstance(value, list):
                return [without_nulls(item) for item in value]
            return value
        assert without_nulls(rust_result) == without_nulls(swift_result), (rust_result, swift_result)
        assert {item["id"] for item in rust_result} == {"rust", "swift"}
        assert {item["delivery"] for item in rust_result} == {"sending", "deliveryUnknown"}
    results = []
    for binary, name in [(rust, "rust-accept"), (swift, "swift-accept")]:
        directory = tmp / name
        directory.mkdir(mode=0o700)
        run([rust, "write", directory])
        run([swift, "write", directory])
        run([rust, "waiting", directory])
        run([binary, "accept", directory])
        results.append(without_nulls(json.loads(run([rust, "read", directory]))))
    assert results[0] == results[1], results
    assert results[0][1]["id"] == "waiting" and results[0][1]["expectedRevision"] == 8
    assert results[0][0]["id"] == "swift" and results[0][0]["expectedRevision"] == 7
print("PASS: original Swift and Rust outboxes interoperate in both orders and advance the same accepted context")
