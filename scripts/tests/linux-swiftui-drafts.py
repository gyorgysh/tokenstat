#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare real Swift/Rust draft stores using isolated files and owned children.

This is storage/state evidence, not rendered UI or native Linux acceptance.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def run(command, **kwargs):
    return subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True, timeout=300, **kwargs)


def output(command, **kwargs):
    return json.loads(run(command, capture_output=True, text=True, **kwargs).stdout)


def participants(work, rust, swift):
    results = []
    for holder, contender, name in [(swift, rust, "swift"), (rust, swift, "rust")]:
        root = work / (name + "-participant")
        root.mkdir(mode=0o700)
        with (work / (name + "-participant.log")).open("w") as log:
            child = subprocess.Popen([str(holder), "participant", str(root)], cwd=ROOT,
                                     stdin=subprocess.PIPE, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not (root / ("ready-" + name)).exists():
                    assert child.poll() is None, f"{name} participant exited before readiness"
                    assert time.monotonic() < deadline, f"{name} participant timed out"
                    time.sleep(0.02)
                assert output([contender, "sole", root]) == {"allowed": False}
                # A terminated owner's kernel lock must disappear; only that
                # explicitly owned child's PID is ever signalled.
                child.terminate()
                child.wait(timeout=15)
                assert output([contender, "sole", root]) == {"allowed": True}
                # The contender's own now-dead lease remains until the next
                # scan. Every earlier dead lease must already be gone.
                assert len(list((root / ".original-file-owners").glob("*.lease"))) == 1
                results.append({"holder": name, "liveRefused": True, "terminatedReleased": True,
                                "staleLeasesPruned": True})
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=15)
                child.stdin.close()
    return results


def concurrent_writers(work, rust, swift):
    root = work / "concurrent"
    root.mkdir(mode=0o700)
    children, logs = [], []
    try:
        for binary, author in [(rust, "rust"), (swift, "swift")]:
            log = (work / (author + "-writer.log")).open("w")
            logs.append(log)
            children.append(subprocess.Popen([str(binary), "writer", str(root), author], cwd=ROOT,
                                             stdout=log, stderr=log))
        for child in children:
            assert child.wait(timeout=45) == 0, "Concurrent writer failed"
        disk = json.loads((root / "drafts.v1.json").read_bytes())
        expected = {f"{author}-{index}" for author in ["rust", "swift"] for index in range(25)}
        assert len(disk) == 50 and {row["text"] for row in disk.values()} == expected
        for binary in [rust, swift]:
            contract.compare(disk, output([binary, "read", root]), "concurrent.reopened")
        lock = (root / "drafts.lock").stat().st_ino
        run([rust, "writer", root, "rust"], capture_output=True)
        assert (root / "drafts.lock").stat().st_ino == lock
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        assert stat.S_IMODE((root / "drafts.v1.json").stat().st_mode) == 0o600
        assert stat.S_IMODE((root / "drafts.lock").stat().st_mode) == 0o600
        return {"writers": 2, "records": 50, "bothReopened": True, "privateModes": True,
                "stableLockInode": True}
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=15)
        for log in logs:
            log.close()


def main():
    if sys.platform != "darwin":
        raise SystemExit("The unchanged Swift store uses Darwin; run this reference on macOS.")
    destination = ROOT / "target/linux-draft-reference"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "manifest.json").unlink(missing_ok=True)
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked",
         "--no-default-features", "--example", "draft-contract"])
    sources = ["apps/mac/Sources/Features/Work/WorkReference.swift",
               "apps/mac/Sources/Features/Work/OriginalFileCoordination.swift",
               "apps/mac/Sources/Features/Work/ChatDraftStore.swift"]
    harness = "apps/linux/reference/DraftStoreReference.swift"
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=destination) as temporary:
        work = Path(temporary)
        rust = work / "draft-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/draft-contract", rust)
        swift = work / "draft-reference"
        attachment = work / "Attachment.swift"
        attachment.write_text("import Foundation\n" + contract.declaration("Bridge/Models.swift", "struct ChatAttachment:"))
        run(["xcrun", "swiftc", "-parse-as-library", *sources, harness, attachment, "-o", swift])
        rust_rows = output([rust])
        swift_rows = output([swift], input=json.dumps(rust_rows))
        (destination / "rust.json").write_text(json.dumps(rust_rows, ensure_ascii=False, indent=2) + "\n")
        (destination / "swift.json").write_text(json.dumps(swift_rows, ensure_ascii=False, indent=2) + "\n")
        contract.compare(swift_rows, rust_rows, "drafts")
        processes = {"concurrent": concurrent_writers(work, rust, swift),
                     "participants": participants(work, rust, swift)}
    inputs = [Path(__file__).relative_to(ROOT), Path(harness),
              Path("scripts/tests/linux-swiftui-contract.py"),
              Path("apps/mac/Sources/Bridge/Models.swift"), *map(Path, sources),
              Path("apps/linux/examples/draft-contract.rs"), Path("apps/linux/src/drafts.rs"),
              *[path.relative_to(ROOT) for path in sorted((ROOT / "apps/linux/src/drafts").glob("*.rs"))],
              *[path.relative_to(ROOT) for path in sorted((ROOT / "apps/linux/src/work").glob("*.rs"))],
              Path("apps/linux/src/work.rs"),
              Path("apps/linux/Cargo.toml"), Path("apps/linux/Cargo.lock")]
    manifest = {"purpose": "original-source draft storage and process coordination; no GUI signoff",
                "cases": len(rust_rows), "checkpoints": sum(len(row["rows"]) for row in rust_rows),
                "substitutions": ["ChatAttachment extracted unchanged from Models.swift",
                                  "L10n returns keys; errors compared as failure state",
                                  "explicit temporary directories only; shared singleton unused",
                                  "generated UUIDs normalized in first observed sorted-key order"],
                "processes": processes,
                "inputs": {str(path): hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in inputs},
                "outputs": {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                            for name in ["rust.json", "swift.json"]},
                "swift": run(["xcrun", "swiftc", "--version"], capture_output=True, text=True).stdout.strip(),
                "rust": run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {manifest['cases']} original draft traces / {manifest['checkpoints']} checkpoints; "
          "50 concurrent Swift/Rust records, private modes, stable lock and two-way live/dead leases")


if __name__ == "__main__":
    main()
