#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Generate desktop/phone apps for encrypted history tests, outside shipping targets.

Build current arm64 macOS and iOS-simulator FFI slices with release-ffi first.
This packages only those two slices and chooses the real in-process transport
for both apps. Process environments select private data and identity roots.
"""
import json
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "target/chat-performance/history-encrypted-native"
OUT.mkdir(parents=True, exist_ok=True)
framework = OUT / "HistoryFFI.xcframework"
libraries = {
    "macos": ROOT / "target/aarch64-apple-darwin/release-ffi/libtokenstat_ffi.a",
    "ios": ROOT / "target/aarch64-apple-ios-sim/release-ffi/libtokenstat_ffi.a",
}

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()

if framework.exists():
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    for item in info["AvailableLibraries"]:
        packaged = framework / item["LibraryIdentifier"]
        source = libraries[item["SupportedPlatform"]]
        same_headers = all((packaged / item["HeadersPath"] / header.name).read_bytes() == header.read_bytes()
            for header in (ROOT / "crates/tokenstat-ffi/include").iterdir() if header.is_file())
        if not same_headers or digest(packaged / item["LibraryPath"]) != digest(source):
            shutil.rmtree(framework)  # This generator owns only its QA artifact.
            break
if not framework.exists():
    subprocess.run([
    "xcodebuild", "-create-xcframework",
    "-library", str(ROOT / "target/aarch64-apple-darwin/release-ffi/libtokenstat_ffi.a"),
    "-headers", str(ROOT / "crates/tokenstat-ffi/include"),
    "-library", str(ROOT / "target/aarch64-apple-ios-sim/release-ffi/libtokenstat_ffi.a"),
    "-headers", str(ROOT / "crates/tokenstat-ffi/include"),
    "-output", str(framework),
    ], check=True)

bridge = (ROOT / "apps/mac/Sources/Bridge/Bridge.swift").read_text()
needle = "    static func connect() {"
assert bridge.count(needle) == 1
start = bridge.index(needle)
end = bridge.index("\n    }\n", start) + len("\n    }")
bridge = bridge[:start] + """    static func connect() {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["TOKENSTAT_NATIVE_HISTORY_DESKTOP_LOCAL"] == "1",
           let path = ProcessInfo.processInfo.environment["TOKENSTAT_NATIVE_HISTORY_FIXTURE"],
           let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let fixture = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let socket = fixture["socket"] as? String {
            adopt(Route(transport: SocketTransport(path: socket), isHosted: true))
            return
        }
        #endif
        adopt(Route(transport: InProcessTransport(), isHosted: false))
    }""" + bridge[end:]
# A private fixture socket must never manage the installed launch agent.
needle = "    private static func repairHost() -> Bool {"
assert bridge.count(needle) == 1
start = bridge.index(needle)
end = bridge.index("\n    }\n", start) + len("\n    }")
bridge = bridge[:start] + needle + "\n        false\n    }" + bridge[end:]
(OUT / "Bridge.swift").write_text(bridge)
sources = [
    {"path": str(ROOT / "apps/mac/Sources"), "excludes": ["Bridge/Bridge.swift"]},
    {"path": str(OUT / "Bridge.swift")},
    {"path": str(ROOT / "scripts/qa/chat-history/HistoryQA.swift")},
    {"path": str(ROOT / "apps/localization"), "type": "folder", "buildPhase": "resources"},
    {"path": str(ROOT / "apps/mac/Resources"), "buildPhase": "resources"},
    {"path": str(ROOT / "apps/mac/BrandResources"), "buildPhase": "resources"},
]
targets = {}
for name, platform, bundle in [
    ("HistoryMac", "macOS", "ai.tokenstat.qa.history.desktop"),
    ("HistoryPhone", "iOS", "ai.tokenstat.qa.history.phone"),
]:
    targets[name] = {
        "type": "application", "platform": platform, "sources": sources,
        "dependencies": [{"framework": str(framework), "embed": False}, {"package": "SwiftTerm"}],
        "settings": {"base": {
            "PRODUCT_BUNDLE_IDENTIFIER": bundle, "PRODUCT_MODULE_NAME": "Tokenstat",
            "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGNING_ALLOWED": "NO",
            "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
            "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "Connect to this test's temporary encrypted history host.",
        }},
    }
    if platform == "macOS":
        targets[name]["settings"]["base"].update(CODE_SIGNING_ALLOWED="YES", CODE_SIGN_IDENTITY="-",
            SWIFT_OBJC_BRIDGING_HEADER=str(ROOT / "apps/mac/Sources/Bridge/Tokenstat-Bridging-Header.h"))
project = {
    "name": "HistoryQA", "options": {"deploymentTarget": {"iOS": "17.0", "macOS": "14.0"}},
    "packages": {"SwiftTerm": {"url": "https://github.com/migueldeicaza/SwiftTerm.git", "exactVersion": "1.99.2"}},
    "settings": {"base": {"SWIFT_VERSION": "5.0", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG WORKBENCH_QA"}},
    "targets": targets,
}
spec = OUT / "project.json"
spec.write_text(json.dumps(project, indent=2) + "\n")
subprocess.run(["xcodegen", "generate", "--spec", str(spec)], check=True)
print(OUT / "HistoryQA.xcodeproj")
