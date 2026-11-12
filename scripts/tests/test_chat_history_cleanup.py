#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check native QA process ownership without launching either app."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("history_qa", Path(__file__).with_name("chat-history-native.py"))
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)


@unittest.skipUnless(sys.platform == "darwin", "The native app runner uses macOS process paths")
class HistoryCleanupTests(unittest.TestCase):
    def test_reopen_requires_the_only_matching_owned_process(self):
        executable = Path("/tmp/history qa/HistoryMac")
        sole = subprocess.CompletedProcess([], 0, stdout=f"42 {executable}\n")
        duplicate = subprocess.CompletedProcess([], 0, stdout=f"42 {executable}\n43 {executable}\n")
        with patch.object(history, "owns_desktop_process", return_value=True), \
             patch.object(history.subprocess, "run", return_value=sole):
            self.assertTrue(history.sole_owned_desktop(42, executable, "run"))
        with patch.object(history, "owns_desktop_process", return_value=True), \
             patch.object(history.subprocess, "run", return_value=duplicate):
            self.assertFalse(history.sole_owned_desktop(42, executable, "run"))
        with patch.object(history, "owns_desktop_process", return_value=False), \
             patch.object(history.subprocess, "run", return_value=sole) as listing:
            self.assertFalse(history.sole_owned_desktop(42, executable, "run"))
            listing.assert_not_called()

    def test_cleanup_requires_both_executable_and_current_run(self):
        executable = Path(sys.executable).resolve()
        marker = "--tokenstat-fixture-run=" + uuid.uuid4().hex
        worker = subprocess.Popen([str(executable), "-c",
            "import time; print('ready', flush=True); time.sleep(30)", marker],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(worker.stdout.readline().strip(), "ready")
            # Framework Python can exec Python.app after its launcher starts.
            executable = Path(subprocess.check_output(
                ["ps", "-ww", "-p", str(worker.pid), "-o", "comm="], text=True).strip()).resolve()
            self.assertFalse(history.owns_desktop_process(worker.pid, executable, marker + "-other"))
            history.stop_owned_desktop(worker.pid, executable, marker + "-other", signal.SIGTERM)
            self.assertIsNone(worker.poll(), "Another run's process must remain alive")
            self.assertFalse(history.owns_desktop_process(worker.pid, Path("/different/app"), marker))
            self.assertTrue(history.owns_desktop_process(worker.pid, executable, marker))
            history.stop_owned_desktop(worker.pid, executable, marker, signal.SIGTERM)
            self.assertEqual(worker.wait(timeout=5), -signal.SIGTERM)
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.wait()
            worker.stdout.close()


if __name__ == "__main__":
    unittest.main()
