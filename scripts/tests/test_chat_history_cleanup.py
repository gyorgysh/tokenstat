#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check native QA process ownership without launching either app."""
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys
import unittest
import uuid

spec = importlib.util.spec_from_file_location("history_qa", Path(__file__).with_name("chat-history-native.py"))
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)


@unittest.skipUnless(sys.platform == "darwin", "The native app runner uses macOS process paths")
class HistoryCleanupTests(unittest.TestCase):
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
