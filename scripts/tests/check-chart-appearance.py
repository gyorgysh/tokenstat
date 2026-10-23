#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise initial WK painting independently of the chart runtime's render."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="tokenstat-chart-appearance-") as directory:
    app = pathlib.Path(directory) / "ChartAppearanceQA.app"
    resources = app / "Contents/Resources"
    binary = app / "Contents/MacOS/ChartAppearanceQA"
    resources.mkdir(parents=True)
    binary.parent.mkdir()
    for name, source in [("runtime", root / "apps/charts/runtime"), ("localization", root / "apps/localization")]:
        shutil.copytree(source, resources / name)
    shutil.copyfile(root / "apps/charts/examples.json", resources / "examples.json")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": binary.name, "CFBundleIdentifier": "ai.tokenstat.chart-appearance-qa",
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    # Only the fixture's bundled copy is changed. Defer the native render call
    # so its document-start appearance cannot pass due to later runtime work.
    with (resources / "runtime/chart.js").open("a") as script:
        script.write("""
;(function () {
    const runtime = window.TokenstatChart;
    const fixture = { pending: null };
    fixture.release = () => {
        window.TokenstatChart = runtime;
        if (fixture.pending) runtime.render(...fixture.pending);
    };
    window.__chartAppearanceFixture = fixture;
    window.TokenstatChart = Object.freeze({
        ...runtime,
        render: (input, settings) => { fixture.pending = [input, settings]; }
    });
})();
""")
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-D", "DEBUG",
                    str(root / "apps/mac/Sources/Design/ChatChartView.swift"),
                    str(root / "apps/mac/Sources/Design/ChartViewport.swift"),
                    str(root / "apps/mac/Sources/Design/L10n.swift"),
                    str(root / "scripts/tests/chart-appearance-qa.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
