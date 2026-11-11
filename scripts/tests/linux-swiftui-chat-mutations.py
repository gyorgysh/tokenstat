#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare unchanged Swift list/note owners and exercise its actual read actor.

All inputs/continuations are synthetic. This proves no GUI or native Linux gate.
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
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


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


def main():
    if sys.platform != "darwin":
        raise SystemExit("Run the original Swift reference on macOS; portable Rust tests also run on Linux.")
    assert sys.argv[1:] in [[], ["--compare-gpui"]], "Usage: linux-swiftui-chat-mutations.py [--compare-gpui]"
    compare_gpui = "--compare-gpui" in sys.argv
    output = ROOT / "target/linux-chat-mutation-reference"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    source = "apps/mac/Sources/Features/Workspaces/Chat/"
    inputs = [source + "ChatListMutations.swift", source + "ChatSteerOverlay.swift",
              "apps/mac/Sources/Bridge/ChatReadFlights.swift"]
    harness = "apps/linux/reference/ChatMutationsReference.swift"
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked",
         "--no-default-features", "--example", "chat-mutations-contract"])
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=output) as temporary:
        work = Path(temporary)
        rust = work / "chat-mutations-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/chat-mutations-contract", rust)
        swift = work / "reference"
        run(["xcrun", "swiftc", "-parse-as-library", *inputs, harness, "-o", swift])
        actual = json.loads(run([rust], capture_output=True, text=True).stdout)
        expected = json.loads(run([swift], input=json.dumps(actual), capture_output=True, text=True).stdout)
        for key in ["reads", "mutations"]:
            actual[key].sort()
        (output / "rust.json").write_text(json.dumps(actual, ensure_ascii=False, indent=2) + "\n")
        (output / "swift.json").write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n")
        contract.compare(expected, actual, "chat-mutations")
        # The actor is exercised with controllable continuations, not copied
        # behavior. It also checks type, cursor, owner and cancellation boundaries.
        actor = work / "original-read-tests"
        run(["xcrun", "swiftc", "-parse-as-library", inputs[2],
             "scripts/tests/ChatReadFlightsTests.swift", "-o", actor])
        actor_result = run([actor], capture_output=True, text=True).stdout.strip()
    if compare_gpui:
        run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked",
             "--example", "chat-transport-executor"])
        transport = json.loads(run([ROOT / "apps/linux/target/debug/examples/chat-transport-executor"],
                                   capture_output=True, text=True, timeout=60).stdout)
        assert transport == {
            "deferredMountedRead": True, "deferredRetiredBeforeAdmission": True, "sharedPages": True, "immutableReplies": True, "codedRefusal": True,
            "windowIsolation": True, "rawRowsAtomic": True,
            "bothInvalidationBranches": True, "sameDomainReadTypes": 3,
            "cancelledWaiter": True, "successorSlot": True,
            "batchedLeaseCancellation": True, "batchedEntityRelease": True,
            "noCompletedCache": True, "retiredBeforeIo": True,
            "deferredRetirement": True, "ownProducerBoundary": True, "cancelBeforeRetry": True,
            "scopeRetirement": True, "asyncSharedReplies": True, "asyncViewRelease": True,
            "retainedReaders": True, "readerMetadataObserver": True, "readerReadOverlap": True,
            "readerResetOpeningShare": True, "readerDeferredCleanup": True, "readerSelectionFence": True,
            "readerOwnerLifetime": True, "readerNoopInvalidation": True, "readerLegacyFallback": True,
            "readerReadingScope": True,
            "readerHelperFallback": True, "readerHostIdentity": True,
            "foregroundResume": True, "windowsOpened": 0, "productionHostOrStoreOpened": False,
        }
        (output / "gpui-transport.json").write_text(json.dumps(transport, indent=2) + "\n")
    tracked = [Path(__file__).relative_to(ROOT), Path(harness), *map(Path, inputs),
               Path("scripts/tests/ChatReadFlightsTests.swift"), Path("scripts/tests/linux-swiftui-contract.py"),
               Path("apps/linux/examples/chat-mutations-contract.rs"), Path("apps/linux/src/chat.rs"),
               *[path.relative_to(ROOT) for path in sorted((ROOT / "apps/linux/src/chat").glob("*.rs"))],
               Path("apps/linux/Cargo.toml"), Path("apps/linux/Cargo.lock")]
    tracked += [Path("apps/linux/src/work.rs"), Path("apps/linux/src/work/text.rs"),
                Path("apps/linux/src/work/destination.rs"), Path("apps/linux/src/client.rs"),
                Path("crates/tokenstat-core/src/host_rpc.rs")]
    if compare_gpui:
        tracked += [Path("apps/linux/examples/chat-transport-executor.rs"),
                    Path("apps/linux/src/chat/paging/publication.rs"),
                    *[path.relative_to(ROOT) for path in sorted((ROOT / "apps/linux/src/chat/polling").glob("*.rs"))]]
    manifest = {"purpose": "original-source list/note state comparison and read actor; no GUI signoff",
                "cases": len(actual["cases"]), "checkpoints": sum(len(case["rows"]) for case in actual["cases"]),
                "substitutions": ["minimal ChatConversation carries only fields read by the original owners",
                                  "read/mutation classifications compared as sorted sets", "synthetic inputs only",
                                  "native retained timeline entities are not the complete ChatModel/load/reveal/helper-adoption or mounted ChatView",
                                  "native FIFO foreground barrier enrolls a same-owner opening waiter while reset-page IO remains held"],
                "originalActor": actor_result,
                "inputs": {str(path): hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in tracked},
                "outputs": {name: hashlib.sha256((output / name).read_bytes()).hexdigest()
                            for name in ["rust.json", "swift.json", *(["gpui-transport.json"] if compare_gpui else [])]},
                "swift": run(["xcrun", "swiftc", "--version"], capture_output=True, text=True).stdout.strip(),
                "rust": run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {manifest['cases']} original list/note traces / {manifest['checkpoints']} checkpoints; "
          f"{len(actual['reads'])} read / {len(actual['mutations'])} mutation methods")
    print(actor_result)
    if compare_gpui:
        print("PASS: actual GPUI typed read transport, owned fake host, exact leases and immutable replies; no product window or Linux signoff")


if __name__ == "__main__":
    main()
