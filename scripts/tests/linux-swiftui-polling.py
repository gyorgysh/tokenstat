#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Execute original retained async owners and compare the complete cadence.

All continuations are synthetic. No window, host, account, archive or store.
"""
from pathlib import Path
import hashlib
import itertools
import json
import math
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(command, **kwargs):
    try:
        return subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True,
                              timeout=kwargs.pop("timeout", 300), **kwargs)
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, file=sys.stderr)
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        raise


def compare(expected, actual, path="polling"):
    assert type(expected) is type(actual), (path, type(expected), type(actual))
    if isinstance(expected, dict):
        assert expected.keys() == actual.keys(), path
        for key in expected:
            compare(expected[key], actual[key], path + "." + key)
    elif isinstance(expected, list):
        assert len(expected) == len(actual), path
        for index, (one, two) in enumerate(zip(expected, actual)):
            compare(one, two, f"{path}[{index}]")
    else:
        assert expected == actual, (path, expected, actual)


def cases():
    traces = []
    for quiet, failures, progress in itertools.product(range(6), range(7), [False, True]):
        actions = []
        if progress:
            actions.append({"op": "note", "now": 10, "success": True, "changed": True})
        actions += [{"op": "note", "now": 10, "success": True, "changed": False}] * quiet
        actions += [{"op": "note", "now": 10, "success": False, "changed": True}] * failures
        for now, busy, attachments in itertools.product(
                [10, 11.199, math.nextafter(11.2, 0), 11.2, math.nextafter(11.2, math.inf), 12],
                [False, True], [False, True]):
            actions.append({"op": "interval", "now": now, "busy": busy, "attachments": attachments})
        actions += [{"op": "note", "now": 13, "success": True, "changed": False},
                    {"op": "interval", "now": 13, "busy": True, "attachments": False},
                    {"op": "note", "now": 14, "success": True, "changed": True},
                    {"op": "interval", "now": 14, "busy": False, "attachments": False}]
        traces.append(actions)
    for status_force, approval_force in itertools.product([False, True], repeat=2):
        actions = []
        for now in [0, 0.99, math.nextafter(1, 0), 1, math.nextafter(1, math.inf), 1.99, 2, 3, 3]:
            actions += [{"op": "status", "now": now, "force": status_force},
                        {"op": "approvals", "now": now, "force": approval_force},
                        {"op": "status", "now": now, "force": False}]
        traces.append(actions)
    # These are monotonic clock arguments, not host wire numbers. Decimal
    # strings avoid serde_json's default non-roundtrip numeric parser changing
    # a boundary by one ULP; both drivers also return the exact Double bits.
    return {"traces": [[{**action, "now": repr(action["now"])} for action in trace]
                       for trace in traces]}


def main():
    if sys.platform != "darwin":
        raise SystemExit("Run original Swift task/cadence evidence on macOS; portable Rust tests run on Linux.")
    assert sys.argv[1:] in [[], ["--compare-gpui"]], "Usage: linux-swiftui-polling.py [--compare-gpui]"
    native = "--compare-gpui" in sys.argv
    output = ROOT / "target/linux-polling-reference"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    original = Path("apps/mac/Sources/Features/Workspaces/Chat/ChatPolling.swift")
    harness = Path("apps/linux/reference/PollingReference.swift")
    actor_tests = Path("scripts/tests/ChatPollingTests.swift")
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--no-default-features", "--locked", "--example", "polling-contract"])
    data = cases()
    payload = json.dumps(data)
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=output) as temporary:
        work = Path(temporary)
        binary = work / "polling-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/polling-contract", binary)
        swift = work / "reference"
        run(["xcrun", "swiftc", "-parse-as-library", original, harness, "-o", swift])
        actual = json.loads(run([binary], input=payload, capture_output=True, text=True).stdout)
        expected = json.loads(run([swift], input=payload, capture_output=True, text=True).stdout)
        compare(expected, actual)
        for name, value in [("input.json", data), ("swift.json", expected), ("rust.json", actual)]:
            (output / name).write_text(json.dumps(value, indent=2) + "\n")
        actor = work / "original-tasks"
        run(["xcrun", "swiftc", "-parse-as-library", original, actor_tests, "-o", actor])
        task_report = run([actor], capture_output=True, text=True, timeout=30).stdout
        assert task_report.splitlines() == [
            "Polling: bounded refresh/share, exact owner/leases, cancellation, adaptive cadence",
            "Opening: 30 shared callers, waiter cancellation, cooperative producer cancellation and successor isolation",
        ]
        (output / "original-tasks.txt").write_text(task_report)
    outputs = ["input.json", "swift.json", "rust.json", "original-tasks.txt"]
    if native:
        run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--example", "polling-executor"])
        actual = json.loads(run([ROOT / "apps/linux/target/debug/examples/polling-executor"], capture_output=True, text=True, timeout=30).stdout)
        compare({key: True for key in ["openingShared", "openingWaiterDrop", "openingOwnerCancellation", "openingSuccessor",
                                      "boundedRefresh", "pollOwnerCancellation", "pollSuccessor", "exactWatchLeases",
                                      "watchSuccessor", "actualTimerCycle", "cancelledEntry", "ownerLifetimes", "foregroundResume"]}
                | {"windowsOpened": 0, "hostOrStoreOpened": False}, actual)
        (output / "gpui.json").write_text(json.dumps(actual, indent=2) + "\n")
        outputs.append("gpui.json")
    inputs = [Path(__file__).relative_to(ROOT), original, harness, actor_tests,
              Path("apps/linux/src/chat.rs"), Path("apps/linux/src/chat/polling.rs"),
              *[path.relative_to(ROOT) for path in sorted((ROOT / "apps/linux/src/chat/polling").glob("*.rs"))],
              Path("apps/linux/examples/polling-contract.rs"), Path("apps/linux/Cargo.toml"), Path("apps/linux/Cargo.lock")]
    if native:
        inputs.append(Path("apps/linux/examples/polling-executor.rs"))
    manifest = {"purpose": "original cadence and async owner checks plus optional actual GPUI; no full reader/view/Linux acceptance",
                "traces": len(data["traces"]), "checkpoints": sum(map(len, data["traces"])),
                "substitutions": ["synthetic suspended operations and finite monotonic clock inputs",
                                  "clock arguments use decimal strings and compare exact IEEE bits before policy outputs",
                                  "original async assertions and Rust/GPUI assertions are complementary cases, not full ChatModel execution",
                                  "explicit Rust cooperative cancellation replaces ambient Swift Task.isCancelled"],
                "inputs": {str(path): hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in inputs},
                "outputs": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in outputs},
                "swift": run(["xcrun", "swiftc", "--version"], capture_output=True, text=True).stdout.strip(),
                "rust": run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {manifest['traces']} original cadence traces / {manifest['checkpoints']} checkpoints; original async task owners")
    if native:
        print("PASS: actual GPUI opening, bounded lanes, exact watcher leases, timer cycle and foreground resumption; no window/host/store")


if __name__ == "__main__":
    main()
