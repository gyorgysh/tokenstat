#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise Mac packaging and release helper assembly with isolated build tools."""
from pathlib import Path
import io
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("aarch64-apple-darwin", "x86_64-apple-darwin")


class MacBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tokenstat-mac-build-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("build-mac-app.sh", "embed-mac-hostd.sh"):
            shutil.copy(ROOT / "scripts" / name, scripts)
        for name in ("build-ffi-xcframework.sh", "ensure-metal-toolchain.sh"):
            (scripts / name).write_text("#!/bin/sh\nexit 0\n")
            (scripts / name).chmod(0o755)
        (self.root / "apps/mac").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tool("xcodegen", "exit 0")
        self.tool("rustup", "printf '%s\\n' " + " ".join(TARGETS))
        self.tool("security", "exit 0")
        self.tool("ditto", 'cp -R "$1" "$2"')
        self.tool("xcodebuild", '''printf '%s\\n' "$@" > "$TEST_ROOT/xcode-args"
if [ -f "$TEST_ROOT/build-fails" ]; then echo 'compiler diagnostic'; exit 42; fi
app="$TEST_ROOT/target/xcode-release/Build/Products/Release/Tokenstat.app"
mkdir -p "$app/Contents/Resources"
echo stale > "$app/Contents/Resources/tokenstat-hostd"
echo 'Build Timing Summary' ''')
        self.tool("cargo", '''echo "$*" >> "$TEST_ROOT/cargo-args"
if [ "$1" = build ]; then
    while [ "$1" != --target ]; do shift; done
    target="$2"
    mkdir -p "$TEST_ROOT/target/$target/release"
    echo "$target" > "$TEST_ROOT/target/$target/release/tokenstat-hostd"
else
    while [ "$1" != notices ]; do shift; done
    echo notices > "$2"
fi''')
        self.tool("lipo", '''if [ "$1" = -create ]; then
    shift
    first="$1"; second="$2"; shift 2
    test "$1" = -output
    cat "$first" "$second" > "$2"
else
    test "$2" = -verify_arch
    case "$3" in
        arm64) grep -q aarch64-apple-darwin "$1" ;;
        x86_64) grep -q x86_64-apple-darwin "$1" ;;
        *) exit 1 ;;
    esac
fi''')
        self.app = self.root / "output app.app"
        (self.app / "Contents/Resources").mkdir(parents=True)
        self.helper = self.app / "Contents/Resources/tokenstat-hostd"
        self.helper.write_text("previous helper")
        self.archives = self.root / "archives"
        self.archives.mkdir()
        for target in TARGETS:
            self.archive(target)

    def tool(self, name, body):
        executable = self.bin / name
        executable.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        executable.chmod(0o755)

    def archive(self, target, helper=True):
        with tarfile.open(self.archives / f"tokenstat-1.2.3-{target}.tar.gz", "w:gz") as archive:
            name = "tokenstat-hostd" if helper else "tokenstat"
            content = (target + "\n").encode()
            entry = tarfile.TarInfo(f"tokenstat-1.2.3-{target}/{name}")
            entry.size = len(content)
            archive.addfile(entry, io.BytesIO(content))

    def run_script(self, script, *args, **environment):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / script), *map(str, args)],
            env={**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                 "TEST_ROOT": str(self.root), "TOKENSTAT_DEFER_HOSTD": "0",
                 "TOKENSTAT_SWIFT_COMPILATION_MODE": "incremental",
                 "GITHUB_STEP_SUMMARY": str(self.root / "step-summary"), **environment},
            capture_output=True, text=True)

    def test_local_build_embeds_both_helpers_and_retains_derived_data(self):
        cached = self.root / "target/xcode-release/cache-sentinel"
        cached.parent.mkdir(parents=True)
        cached.touch()
        result = self.run_script("build-mac-app.sh", "1.2.3", self.root / "dist")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        helper = self.root / "dist/Tokenstat.app/Contents/Resources/tokenstat-hostd"
        self.assertEqual(helper.read_text(), "\n".join(TARGETS) + "\n")
        self.assertTrue(cached.exists())
        self.assertIn("SWIFT_COMPILATION_MODE=incremental", (self.root / "xcode-args").read_text())

    def test_release_defers_helper_without_carrying_a_stale_copy(self):
        result = self.run_script("build-mac-app.sh", "1.2.3", self.root / "dist", TOKENSTAT_DEFER_HOSTD="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "dist/Tokenstat.app/Contents/Resources/tokenstat-hostd").exists())
        self.assertNotIn("build --release", (self.root / "cargo-args").read_text())

    def test_compiler_failure_preserves_output_and_keeps_diagnostics(self):
        previous = self.root / "dist/Tokenstat.app/Contents/Resources/tokenstat-hostd"
        previous.parent.mkdir(parents=True)
        previous.write_text("previous helper")
        (self.root / "build-fails").touch()
        result = self.run_script("build-mac-app.sh", "1.2.3", self.root / "dist", TOKENSTAT_DEFER_HOSTD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("compiler diagnostic", result.stderr)
        self.assertIn("compiler diagnostic", (self.root / "target/xcode-release.log").read_text())
        self.assertEqual(previous.read_text(), "previous helper")

    def test_release_assembly_embeds_both_same_version_helpers(self):
        result = self.run_script("embed-mac-hostd.sh", self.app, self.archives, "1.2.3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.helper.read_text(), "\n".join(TARGETS) + "\n")
        self.assertTrue(self.helper.stat().st_mode & 0o111)

    def test_missing_helper_preserves_previously_embedded_binary(self):
        self.archive(TARGETS[1], helper=False)
        result = self.run_script("embed-mac-hostd.sh", self.app, self.archives, "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no helper", result.stderr)
        self.assertEqual(self.helper.read_text(), "previous helper")

    def test_invalid_architecture_preserves_previously_embedded_binary(self):
        self.tool("lipo", 'if [ "$1" = -create ]; then cp "$2" "$5"; else echo invalid architecture >&2; exit 1; fi')
        result = self.run_script("embed-mac-hostd.sh", self.app, self.archives, "1.2.3")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.helper.read_text(), "previous helper")


if __name__ == "__main__":
    unittest.main()
