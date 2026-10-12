# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Installer regressions using only temporary files and extracted pure helpers."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PathExportTests(unittest.TestCase):
    def test_custom_directory_stays_literal_in_shell_profile(self):
        source = (ROOT / "scripts/install.sh").read_text()
        helper = source[source.index("path_export() {"):source.index("\nensure_path() {")]
        for directory in ["/tmp/with spaces", "/tmp/o'reilly", '/tmp/$(printf injected)/`printf injected`/"quoted"', "/tmp/line\nbreak"]:
            with self.subTest(directory=directory):
                result = subprocess.check_output([
                    "/bin/bash", "-c", helper + '\nline=$(path_export "$1"); PATH=sentinel; eval "$line"; printf %s "$PATH"',
                    "test", directory,
                ], text=True)
                self.assertEqual(result, directory + ":sentinel")

    @unittest.skipUnless(Path("/usr/bin/plutil").exists(), "macOS plutil")
    def test_always_on_update_preserves_other_host_settings(self):
        source = (ROOT / "scripts/install-host-agent.sh").read_text()
        start = source.index('if [ "$FORCE_ALWAYS_ON" -eq 1 ] || [ ! -f "$HOST_JSON" ]; then')
        block = source[start:source.index('\nmkdir -p "$(dirname "$PLIST")"', start)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host.json"
            path.write_text('{"alwaysOn":false,"port":42,"label":"Keep me"}')
            subprocess.run(["/bin/bash", "-euc", 'IDENTITY_DIR="$1"; HOST_JSON="$1/host.json"; FORCE_ALWAYS_ON=1; KEEP_ALIVE=true;\n' + block, "test", directory], check=True)
            import json
            self.assertEqual(json.loads(path.read_text()), {"alwaysOn": True, "port": 42, "label": "Keep me"})
            path.write_text("broken JSON")
            result = subprocess.run(["/bin/bash", "-euc", 'IDENTITY_DIR="$1"; HOST_JSON="$1/host.json"; FORCE_ALWAYS_ON=1; KEEP_ALIVE=true;\n' + block, "test", directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), "broken JSON")


class StoreProfileTests(unittest.TestCase):
    def test_store_profile_uses_capabilities_instead_of_display_name(self):
        source = (ROOT / "scripts/upload-ios-appstore.sh").read_text()
        helper = source[source.index("def is_store_profile("):source.index("def check_ipa(")]
        namespace = {}
        exec(helper, namespace)
        permits = namespace["is_store_profile"]
        profile = {"Name": "My manually created distribution profile", "Entitlements": {"beta-reports-active": True}}
        self.assertTrue(permits(profile))
        self.assertFalse(permits({"Name": "iOS Team Store Provisioning Profile spoof", "Entitlements": {}}))
        self.assertFalse(permits(dict(profile, ProvisionedDevices=[])))
        self.assertFalse(permits(dict(profile, ProvisionsAllDevices=True)))
        self.assertFalse(permits(dict(profile, Entitlements={"beta-reports-active": True, "get-task-allow": True})))


if __name__ == "__main__":
    unittest.main()
