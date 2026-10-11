#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Generate an isolated iPhone UI-test app using unchanged production views.

Requires a disposable routing host's target/routing-qa/native-fixture.json and
an iOS simulator FFI slice. No QA entry point or transport enters shipping builds.
Run xcodegen with the emitted spec, then xcodebuild test on one booted simulator.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--platform", choices=("iOS", "macOS"), default="iOS")
platform = parser.parse_args().platform
OUT = ROOT / ("target/routing-qa/apple" if platform == "iOS" else "target/routing-qa/apple-mac")
OUT.mkdir(parents=True, exist_ok=True)
fixture = ROOT / "target/routing-qa/native-fixture.json"
if not fixture.is_file():
    raise SystemExit("Start chat-routing-e2e.py --serve before generating native QA.")
bridge = (ROOT / "apps/mac/Sources/Bridge/Bridge.swift").read_text()
needle = "    static func connect() {"
assert bridge.count(needle) == 1
start = bridge.index(needle)
end = bridge.index("\n    }\n", start) + len("\n    }")
bridge = bridge[:start] + """    static func connect() {
        let url = Bundle.main.url(forResource: "native-fixture", withExtension: "json")!
        let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        adopt(Route(transport: SocketTransport(path: fixture["socket"]!), isHosted: true))
    }""" + bridge[end:]
(OUT / "Bridge.swift").write_text(bridge)
sources = [
    {"path": str(ROOT / "apps/mac/Sources"), "excludes": ["Bridge/Bridge.swift"]},
    {"path": str(OUT / "Bridge.swift")},
    {"path": str(ROOT / "apps/mac/Tests/Routing/RoutingQAApp.swift")},
    {"path": str(ROOT / "apps/localization"), "type": "folder", "buildPhase": "resources"},
    {"path": str(ROOT / "apps/mac/Resources"), "buildPhase": "resources"},
    {"path": str(ROOT / "apps/mac/BrandResources"), "buildPhase": "resources"},
    {"path": str(fixture), "buildPhase": "resources"},
]
project = {
    "name": "RoutingQA", "options": {"deploymentTarget": {"iOS": "17.0", "macOS": "14.0"}},
    "packages": {"SwiftTerm": {"url": "https://github.com/migueldeicaza/SwiftTerm.git", "exactVersion": "1.11.2"}},
    "settings": {"base": {"SWIFT_VERSION": "5.0", "CODE_SIGNING_ALLOWED": "NO",
                          "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG WORKBENCH_QA"}},
    "targets": {
        "RoutingQA": {
            "type": "application", "platform": platform, "sources": sources,
            "dependencies": [
                {"framework": str(ROOT / "apps/mac/Vendor/TokenstatFFI.xcframework"), "embed": False},
                {"package": "SwiftTerm"},
            ],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "ai.tokenstat.routingqa",
                                  "GENERATE_INFOPLIST_FILE": "YES",
                                  "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                                  "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES"}},
        },
        "RoutingUITests": {
            "type": "bundle.ui-testing", "platform": platform,
            "sources": [str(ROOT / ("apps/mac/Tests/Routing/RoutingUITests.swift" if platform == "iOS" else "apps/mac/Tests/Routing/RoutingMacUITests.swift"))],
            "dependencies": [{"target": "RoutingQA"}],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "ai.tokenstat.routingqa.tests",
                                  "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "RoutingQA"}},
        },
    },
    "schemes": {"RoutingQA": {"build": {"targets": {"RoutingQA": "all", "RoutingUITests": "test"}},
                              "test": {"targets": ["RoutingUITests"]}}},
}
if platform == "macOS":
    # Some desktop terminal types use the shipping module's explicit namespace.
    project["targets"]["RoutingQA"]["settings"]["base"]["PRODUCT_MODULE_NAME"] = "Tokenstat"
    project["settings"]["base"]["CODE_SIGNING_ALLOWED"] = "YES"
    project["settings"]["base"]["CODE_SIGN_IDENTITY"] = "-"
(OUT / "project.json").write_text(json.dumps(project, indent=2))
print(OUT / "project.json")
