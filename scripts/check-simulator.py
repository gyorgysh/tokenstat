#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compile the native macOS simulator boundary and exercise production models.

Does not boot a device, install an SDK, access an account or write preferences
outside its temporary test domain. Live device acceptance is a separate check.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
sources = root / "apps/mac/Sources/Features/Simulator"
with tempfile.TemporaryDirectory(prefix="tokenstat-simulator-") as temporary:
    work = Path(temporary)
    target = f"{platform.machine()}-apple-macosx14.0"
    native = work / "NativeSimulatorConnection.o"
    subprocess.run(["xcrun", "clang", "-target", target, "-fobjc-arc", "-fmodules", "-c",
                    str(sources / "NativeSimulatorConnection.m"), "-o", str(native)], check=True)
    swift = sorted(str(path) for path in sources.glob("*.swift") if path.name != "SimulatorInspector.swift")
    subprocess.run(["xcrun", "swiftc", "-target", target, "-swift-version", "5", "-D", "TOKENSTAT_TEST",
                    "-parse-as-library", "-module-cache-path", str(work / "ModuleCache"),
                    "-import-objc-header", str(sources / "NativeSimulatorConnection.h"),
                    str(root / "scripts/tests/SimulatorNativeCheck.swift"), *swift,
                    str(root / "apps/mac/Sources/Design/L10n.swift"), str(native),
                    "-framework", "AppKit", "-framework", "IOSurface", "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check")], check=True)
    subprocess.run(["xcrun", "clang", "-target", target, "-fobjc-arc", "-fmodules", "-Wall", "-Wextra", "-Werror",
                    str(root / "scripts/tests/SimulatorNativeOwnershipCheck.m"), str(native), "-framework", "AppKit",
                    "-framework", "IOSurface", "-o", str(work / "ownership")], check=True)
    subprocess.run([str(work / "ownership")], check=True)
