#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Execute original fork task/model/bridge/root bodies with owned continuations.

This compares state and route effects, not actual SwiftUI observation or pixels.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def run(command, **kwargs):
    return subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True, timeout=180, **kwargs)


def main():
    if sys.platform != "darwin":
        raise SystemExit("Run the unchanged Swift fork reference on macOS.")
    output = ROOT / "target/linux-fork-reference"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    reference = ROOT / "apps/linux/reference/ForkReference.swift"
    text = reference.read_text()
    extracted = []
    for token, file, marker in [
        ("FEATURE", "Client/ClientRemoteFeatureGate.swift", "enum RemoteHostFeature:"),
        ("ROUTE_RECORD", "Features/Work/WorkDestinationResolver.swift", "struct Route:"),
        ("ROUTE", "Features/Work/WorkDestinationResolver.swift", "static func route(folderID:"),
        ("BRIDGE_ROUTE", "Bridge/Bridge.swift", "static func chatRoute("),
        ("BRIDGE_FORK", "Bridge/Bridge.swift", "static func forkChat("),
        ("MODEL_FORK", "Features/Workspaces/Chat/ChatModel.swift", "func fork("),
    ]:
        text = text.replace(f"/* SOURCE_{token} */", c.declaration(file, marker))
        extracted.append(c.SOURCES / file)
    row = c.declaration("App/RootView.swift", "private struct ChatSidebarConversationRow:")
    task = row[row.index("            guard !copying else"):row.index("        })\n        items.append(.separator)")]
    text = text.replace("/* SOURCE_TASK */", task)
    callback = c.declaration_text(c.declaration("App/RootView.swift", "private func chatHistoryList("), "fork: {")
    callback = callback.removeprefix("fork: ")
    text = text.replace("/* SOURCE_CALLBACK */", callback.replace("{", "{ [self] in", 1))
    assert "/* SOURCE_" not in text
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "fork-contract"])
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=output) as temporary:
        work = Path(temporary)
        rust = work / "fork-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/fork-contract", rust)
        source = work / "Reference.swift"
        source.write_text(text)
        binary = work / "reference"
        run(["xcrun", "swiftc", "-parse-as-library", c.SOURCES / "App/Route.swift", source, "-o", binary])
        actual = json.loads(run([rust], capture_output=True, text=True).stdout)
        expected = json.loads(run([binary], input=json.dumps(actual), capture_output=True, text=True).stdout)
        (output / "rust.json").write_text(json.dumps(actual, ensure_ascii=False, indent=2) + "\n")
        (output / "swift.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n")
        c.compare(expected, actual, "fork")
    inputs = [Path(__file__).resolve(), reference, *extracted, c.SOURCES / "App/RootView.swift", c.SOURCES / "App/Route.swift",
              ROOT / "scripts/tests/linux-swiftui-contract.py", ROOT / "apps/linux/examples/fork-contract.rs",
              ROOT / "apps/linux/src/chat.rs", ROOT / "apps/linux/src/chat/actions.rs", ROOT / "apps/linux/src/chat/directory.rs",
              ROOT / "apps/linux/src/chat/list_mutations.rs", ROOT / "apps/linux/src/chat/steer_overlay.rs",
              ROOT / "apps/linux/src/navigation.rs", ROOT / "apps/linux/src/work.rs", ROOT / "apps/linux/src/work/destination.rs", ROOT / "apps/linux/src/work/text.rs",
              ROOT / "apps/linux/Cargo.toml", ROOT / "apps/linux/Cargo.lock"]
    manifest = {"cases": len(actual["cases"]), "routePairs": len(actual["routePairs"]), "minimumProtocol": actual["minimum"],
                "substitutions": ["owned continuations replace actual transport", "row state fields represent separate mount lifetimes; observation is unverified",
                                  "minimal consumed conversation fields", "scope strings stand for distinct account contexts", "explicit class self capture around unchanged root callback body", "L10n returns keys; error presence compared"],
                "inputs": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(set(inputs))},
                "harnessSha256": hashlib.sha256(text.encode()).hexdigest(),
                "outputs": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in ["rust.json", "swift.json"]},
                "swift": run(["swiftc", "--version"], capture_output=True, text=True).stdout.strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {manifest['cases']} original fork task/model/capability/root outcomes, {manifest['routePairs']} actual Swift route equality/hash pairs; protocol {manifest['minimumProtocol']}")


if __name__ == "__main__":
    main()
