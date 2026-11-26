#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check local-model recovery over a disposable Unix host and loopback provider."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import uuid


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        assert self.path == "/api/tags", self.path
        body = b'{"models":[{"name":"fixture:latest"}]}'
        self.send_response(200 if self.server.available else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        assert self.path == "/v1/messages", self.path
        self.send_error(400)


def until(callback, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if result := callback():
            return result
        time.sleep(.05)
    raise AssertionError("Fixture did not complete")


CLAUDE_FIXTURE = """import os, pathlib, sys, time
if "--version" in sys.argv:
    print("2.1.1")
    raise SystemExit(0)
if "fixture:latest" not in sys.argv or "--output-format" not in sys.argv:
    raise SystemExit(0)
root = pathlib.Path(os.environ["FIXTURE_DIR"])
(root / "started").touch()
for _ in range(200):
    if (root / "server-gone").exists():
        raise SystemExit(1)
    time.sleep(.03)
raise SystemExit(2)
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=Path("target/debug/tokenstat-hostd"))
    host_binary = parser.parse_args().host.resolve()
    with (tempfile.TemporaryDirectory(prefix="ts-model-offline-", dir="/tmp") as temporary,
          ThreadingHTTPServer(("127.0.0.1", 0), Provider) as provider):
        root = Path(temporary)
        home, repo, bin_path = (root / name for name in ("home", "project", "bin"))
        for directory in (home, repo, bin_path):
            directory.mkdir()
        cli = bin_path / "claude"
        cli.write_text(f"#!{sys.executable}\n" + CLAUDE_FIXTURE)
        cli.chmod(0o700)
        address = root / "host.sock"

        def rpc(method, **params):
            with socket.socket(socket.AF_UNIX) as sock:
                sock.settimeout(10)
                sock.connect(str(address))
                sock.sendall((json.dumps({"id": uuid.uuid4().hex, "method": method, "params": params}) + "\n").encode())
                return json.loads(sock.makefile().readline())

        def call(method, **params):
            response = rpc(method, **params)
            assert response["ok"], (method, response)
            return response["result"]

        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("TOKENSTAT_", "ANTHROPIC_", "CLAUDE_"))}
        env.update(HOME=str(home), ZDOTDIR=str(home), TOKENSTAT_DATA_DIR=str(root / "data"),
                   TOKENSTAT_IDENTITY_DIR=str(root / "identity"), TOKENSTAT_API_BASE="http://127.0.0.1:9",
                   FIXTURE_DIR=str(root), PATH=f"{bin_path}{os.pathsep}{env['PATH']}")
        provider.available = True
        thread = Thread(target=provider.serve_forever, daemon=True)
        thread.start()
        with (root / "host.log").open("w") as log:
            host = subprocess.Popen([str(host_binary), "--socket", str(address)], env=env, stdout=log, stderr=log)
            try:
                until(address.is_socket)
                call("local.provider.set", id="ollama", port=provider.server_port)
                work = call("workspace.add", path=str(repo))
                chat = call("chat.create", workspaceId=work["id"], backend="claude",
                            model="local:ollama/fixture:latest", autonomy="bypass")
                def message():
                    return dict(id=chat["id"], text="Fixture prompt", expectedRevision=chat["sendRevision"],
                                clientMessageId=str(uuid.uuid4()), clientMessageCreatedAtMs=int(time.time() * 1000))
                provider.available = False
                result = rpc("chat.send", **message())
                assert not result["ok"] and "Start it" in result["error"]["message"], result
                assert not (root / "started").exists()
                provider.available = True
                call("chat.send", **message())
                until((root / "started").exists)
                provider.available = False
                (root / "server-gone").touch()

                def completion():
                    rows = call("chat.events", id=chat["id"])["events"]
                    events = [row.get("event", row) for row in rows]
                    return events if any(event["kind"] == "done" for event in events) else None

                events = until(completion)
                assert any(event["kind"] == "failed" and "Start it" in event["text"] for event in events), events
                assert events[-1]["kind"] == "done" and events[-1]["status"] == "error", events
                print("Local provider loss before sending and during a running turn produced recovery guidance")
            finally:
                host.terminate()
                host.wait(timeout=10)
                provider.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    main()
