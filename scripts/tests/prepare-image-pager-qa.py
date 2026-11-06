#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Generate an offline native image-pager gesture fixture outside shipping targets."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "target/chat-performance/image-pager-native"
OUT.mkdir(parents=True, exist_ok=True)
fixture = ROOT / "scripts/qa/image-pager"
chat = ROOT / "apps/mac/Sources/Features/Workspaces/Chat"
project = {
    "name": "ImagePagerQA",
    "options": {"deploymentTarget": {"iOS": "17.0"}},
    "settings": {"base": {"SWIFT_VERSION": "5.0", "CODE_SIGNING_ALLOWED": "NO"}},
    "targets": {
        "ImagePagerQA": {
            "type": "application", "platform": "iOS",
            "sources": [str(fixture / "ImagePagerQA.swift")] + [str(chat / name) for name in (
                "ChatImagePager.swift", "ChatImageViewport.swift", "ChatImageViewerGeometry.swift")],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "ai.tokenstat.qa.imagepager",
                "GENERATE_INFOPLIST_FILE": "YES", "TARGETED_DEVICE_FAMILY": "1,2",
                "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"}},
        },
        "ImagePagerUITests": {
            "type": "bundle.ui-testing", "platform": "iOS",
            "sources": [str(fixture / "ImagePagerUITests.swift")],
            "dependencies": [{"target": "ImagePagerQA"}],
            "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "ai.tokenstat.qa.imagepager.tests",
                "GENERATE_INFOPLIST_FILE": "YES"}},
        },
    },
}
spec = OUT / "project.json"
spec.write_text(json.dumps(project, indent=2) + "\n")
subprocess.run(["xcodegen", "generate", "--spec", str(spec), "--project", str(OUT)], check=True)
