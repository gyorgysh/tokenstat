#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Measure production chart preparation and hold WebKit completion callbacks."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="tokenstat-chart-updates-") as directory:
    app = pathlib.Path(directory) / "ChartUpdateQA.app"
    resources = app / "Contents/Resources"
    binary = app / "Contents/MacOS/ChartUpdateQA"
    resources.mkdir(parents=True)
    binary.parent.mkdir()
    shutil.copytree(root / "apps/localization", resources / "localization")
    shutil.copyfile(root / "apps/charts/examples.json", resources / "examples.json")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": binary.name, "CFBundleIdentifier": "ai.tokenstat.chart-updates-qa",
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    source = pathlib.Path(directory) / "ChartUpdateQA.swift"
    source.write_text((root / "apps/mac/Sources/Design/ChatChartView.swift").read_text()
                      + "\n" + (root / "scripts/tests/chart-update-qa.swift").read_text())
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-swift-version", "5", str(source),
                    str(root / "apps/mac/Sources/Design/ChartViewport.swift"),
                    str(root / "apps/mac/Sources/Design/L10n.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
