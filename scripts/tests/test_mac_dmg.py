#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the real packager with isolated build tools and interrupted installs."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DiskImageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-dmg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/package-mac-dmg.sh", self.root / "scripts")
        installer = self.root / "apps/mac/Installer"
        installer.mkdir(parents=True)
        self.requirements = installer / "requirements.txt"
        self.requirements.write_text("pinned-dependencies\n")
        self.venv = self.root / "target/dmgbuild-venv"
        self.bin = self.venv / "bin"
        self.bin.mkdir(parents=True)
        self.tool("python", "exit 0")
        self.tool("pip", 'echo install >> "$TEST_ROOT/installs"\n'
                  'test ! -f "$TEST_ROOT/install-fails"')
        self.tool("dmgbuild", 'for argument do output="$argument"; done\n'
                  'echo new-image > "$output"\n'
                  'test ! -f "$TEST_ROOT/build-fails"')
        self.tool("ditto", 'mkdir -p "$2"')
        self.tool("tiffutil", 'while [ "$1" != -out ]; do shift; done\nshift\ntouch "$1"')
        self.app = self.root / "App with spaces.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        (resources / "AppIcon.icns").touch()
        self.output = self.root / "previous image.dmg"
        self.output.write_text("previous-image\n")

    def tool(self, name, script):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + script + "\n")
        path.chmod(0o755)

    def package(self, succeeds):
        result = subprocess.run(
            ["bash", str(self.root / "scripts/package-mac-dmg.sh"), str(self.app), str(self.output)],
            env={**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                 "TEST_ROOT": str(self.root)}, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_failed_build_preserves_previous_image(self):
        failure = self.root / "build-fails"
        failure.touch()
        self.package(False)
        self.assertEqual(self.output.read_text(), "previous-image\n")
        failure.unlink()
        self.package(True)
        self.assertEqual(self.output.read_text(), "new-image\n")

    def test_partial_install_is_retried_even_with_executable_present(self):
        failure = self.root / "install-fails"
        failure.touch()
        self.package(False)
        self.assertFalse((self.venv / "installed-requirements.txt").exists())
        self.assertEqual(self.output.read_text(), "previous-image\n")
        failure.unlink()
        self.package(True)
        self.assertEqual((self.root / "installs").read_text().splitlines(), ["install", "install"])

    def test_changed_pins_refresh_cached_environment(self):
        self.package(True)
        self.package(True)
        self.assertEqual((self.root / "installs").read_text().splitlines(), ["install"])
        self.requirements.write_text("new-pinned-dependencies\n")
        self.package(True)
        self.assertEqual((self.root / "installs").read_text().splitlines(), ["install", "install"])
        self.assertEqual((self.venv / "installed-requirements.txt").read_bytes(), self.requirements.read_bytes())


if __name__ == "__main__":
    unittest.main()
