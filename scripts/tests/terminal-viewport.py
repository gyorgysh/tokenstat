#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production UIKit terminal against long history and caret scrolling.

Requires an already booted iOS simulator and a simulator build of SwiftTerm.
No account, connection, terminal process or model is used by the harness.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", default="booted")
parser.add_argument("--products", type=Path, default=root / "target/xcode-ios-sim/Build/Products/Debug-iphonesimulator")
parser.add_argument("--source-ref", help="Use TerminalSelectionView.swift from a Git ref for a regression comparison")
args = parser.parse_args()
products = args.products.resolve()
if not (products / "SwiftTerm.o").is_file():
    parser.error("Build Tokenstat for the iOS simulator first, or pass --products.")

def sim(*arguments, **kwargs):
    return subprocess.run(["xcrun", "simctl", *arguments], check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix="tokenstat-terminal-viewport-") as directory:
    work = Path(directory)
    app = work / "ViewportCheck.app"
    app.mkdir()
    keys = (root / "apps/mac/Sources/Client/ClientTerminalKeys.swift").read_text()
    (work / "Keys.swift").write_text(keys[:keys.index("#if !os(macOS)")])
    relative = "apps/mac/Sources/Features/Terminals/TerminalSelectionView.swift"
    source = (subprocess.check_output(["git", "show", args.source_ref + ":" + relative], cwd=root, text=True)
              if args.source_ref else (root / relative).read_text())
    (work / "TerminalSelectionView.swift").write_text(source)
    sdk = subprocess.check_output(["xcrun", "-sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "-sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-sdk", sdk,
                    "-target", "arm64-apple-ios18.0-simulator", "-I", str(products),
                    str(root / "scripts/tests/terminal-viewport.swift"), str(work / "Keys.swift"),
                    str(work / "TerminalSelectionView.swift"), str(products / "SwiftTerm.o"),
                    "-o", str(app / "ViewportCheck")], check=True)
    bundle = "ai.tokenstat.viewport-check"
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "ViewportCheck", "CFBundleIdentifier": bundle,
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
        "UILaunchScreen": {},
    }))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sim("install", args.device, str(app))
    container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, bundle, "data"], text=True).strip())
    result = container / "Documents/viewport-results.txt"
    result.unlink(missing_ok=True)
    try:
        sim("launch", args.device, bundle)
        deadline = time.monotonic() + 30
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        if not result.exists():
            raise SystemExit("Terminal viewport harness did not complete.")
        report = result.read_text()
        print(report, end="")
        if "FAIL " in report or report.count("PASS ") != 11:
            raise SystemExit(1)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
