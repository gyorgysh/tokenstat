#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise agent profiles through a disposable host and native-shaped CLI fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
from threading import Thread
import time
import uuid

CODEX = '''import json, os, pathlib, sys, uuid
home = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex"))
args = sys.argv[1:]
def trace(kind):
    path = pathlib.Path(__file__).resolve().parents[1] / f"{kind}.json"
    pending = path.with_suffix(".pending")
    pending.write_text(json.dumps({"home": str(home), "hasSystemKey": bool(os.getenv("OPENAI_API_KEY"))}))
    pending.replace(path)
if args == ["--fixture-profile-terminal"] or ("exec" in args and "--json" in args):
    kind = "terminal" if args == ["--fixture-profile-terminal"] else "chat"
    trace(kind)
    if kind == "chat":
        for event in [
            {"type": "thread.started", "thread_id": str(uuid.uuid4())},
            {"type": "item.completed", "item": {"id": "qa", "type": "agent_message", "text": "Profile test turn"}},
            {"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 2}},
        ]:
            print(json.dumps(event), flush=True)
elif args == ["login", "status"]:
    print("Logged in using ChatGPT" if (home / "auth.json").is_file() or os.getenv("OPENAI_API_KEY")
        else "Not logged in")
elif args[:1] == ["login"]:
    home.mkdir(parents=True, exist_ok=True)
    (home / "auth.json").write_text("{}")
    print("Signed in")
elif args == ["app-server"]:
    percent = 70 if os.getenv("OPENAI_API_KEY") else 25
    for request in map(json.loads, sys.stdin):
        if request.get("id") == 2:
            print(json.dumps({"id": 2, "result": {"rateLimits": {"primary": {
                "usedPercent": percent, "windowDurationMins": 300}}}}), flush=True)
elif "app-server" in args:
    # Live chat turns run through the host's chat-live helper, which drives
    # `codex app-server --stdio` over JSON-RPC. Answer just enough of that
    # handshake to complete one fixture turn on this login.
    trace("chat")
    thread, turn = str(uuid.uuid4()), str(uuid.uuid4())
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        rid = request.get("id")
        if rid == "initialize":
            print(json.dumps({"id": "initialize", "result": {}}), flush=True)
        elif rid == "thread":
            print(json.dumps({"id": "thread", "result": {
                "thread": {"id": thread}, "model": "gpt-qa"}}), flush=True)
        elif rid == "turn":
            print(json.dumps({"id": "turn", "result": {
                "turn": {"id": turn}}}), flush=True)
            print(json.dumps({"method": "item/completed", "params": {
                "threadId": thread, "turnId": turn, "item": {
                    "id": "qa", "type": "agentMessage",
                    "text": "Profile test turn"}}}), flush=True)
            print(json.dumps({"method": "turn/completed", "params": {
                "threadId": thread,
                "turn": {"id": turn, "status": "completed"}}}), flush=True)
            break
else:
    print("codex-cli 1.0.0")
'''


class LimitsEndpoint(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/v1/limits" or self.headers.get("Authorization") != "Bearer fixture-only":
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.received.append(body)
        legacy_error = self.server.legacy_error
        rejected = legacy_error and any("profile_id" in row for row in body["providers"])
        self.send_response(400 if rejected else 200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(legacy_error if rejected else {"accepted": len(body["providers"])}).encode())

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=Path("target/debug/tokenstat-hostd"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]

    with (tempfile.TemporaryDirectory(prefix="ts-profile-", dir="/tmp") as directory,
          ThreadingHTTPServer(("127.0.0.1", 0), LimitsEndpoint) as service):
        scratch = Path(directory)
        service.received = []
        service.legacy_error = None
        origin = f"http://127.0.0.1:{service.server_port}"
        data, home, bin_dir, project = (scratch / name for name in ("data", "home", "bin", "project"))
        for path in (data, home, bin_dir, project):
            path.mkdir()
        sources = ["claude_code", "cursor", "grok", "muse", "opencode", "antigravity"]
        (data / "config.json").write_text(json.dumps({"sync": {"limits_skip": sources}}))
        (home / ".zshrc").write_text("HISTFILE=/dev/null\nSAVEHIST=0\n")
        codex = bin_dir / "codex"
        codex.write_text(f"#!{sys.executable}\n" + CODEX)
        codex.chmod(0o700)
        env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                   TOKENSTAT_DATA_DIR=str(data), TOKENSTAT_IDENTITY_DIR=str(scratch / "identity"),
                   TOKENSTAT_API_BASE=origin,
                   OPENAI_API_KEY="machine-fixture-only")
        env.pop("CODEX_HOME", None)
        # Match the host's file naming for its origin-scoped sync bearer.
        origin_hash = 0xcbf29ce484222325
        for byte in origin.encode():
            origin_hash = ((origin_hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff
        token = data / "credentials" / "sync" / f"{origin_hash:016x}.token"
        token.parent.mkdir(parents=True, mode=0o700)
        token.touch(mode=0o600)
        token.write_text("fixture-only")
        address = scratch / "host.sock"

        def call(method, params=None, *, succeeds=True):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(60)
                connection.connect(str(address))
                request = {"id": uuid.uuid4().hex, "method": method, "params": params or {}}
                connection.sendall((json.dumps(request) + "\n").encode())
                response = json.loads(connection.makefile().readline())
                assert response["ok"] == succeeds, (method, response)
                return response["result"] if succeeds else response["error"]["message"]

        def wait_for(check):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    if check():
                        return
                except (FileNotFoundError, ConnectionRefusedError):
                    pass
                time.sleep(0.05)
            raise AssertionError("the disposable host or agent did not become ready")

        with (scratch / "host.log").open("w") as log:
            listener = Thread(target=service.serve_forever, daemon=True)
            listener.start()
            host = subprocess.Popen([str(args.host.resolve()), "--socket", str(address)], env=env,
                                    stdout=log, stderr=log)
            try:
                wait_for(lambda: str(call("protocol")["protocolVersion"]) == "58")
                workspace = call("workspace.add", {"path": str(project)})["id"]
                assert call("profiles.list")["default"] == "system"
                work = call("profiles.create", {"name": "Work"})["id"]
                call("profiles.setAgent", {"id": work, "agent": "codex", "own": True})

                assert call("launcher.checkSignIn", {"id": "codex"})["readiness"] == "signedIn"
                assert call("launcher.checkSignIn", {"id": "codex", "profile": work})["readiness"] == "needsSignIn"
                pty = call("launcher.signIn", {"id": "codex", "profile": work})["id"]
                login = data / "profiles" / work / "codex" / "auth.json"
                wait_for(login.is_file)
                call("pty.close", {"id": pty})
                assert call("launcher.checkSignIn", {"id": "codex", "profile": work})["readiness"] == "signedIn"
                assert not (home / ".codex" / "auth.json").exists()

                legacy = call("chat.create", {"workspaceId": workspace, "backend": "codex"})
                assert legacy.get("profileId") is None
                call("profiles.setDefault", {"id": work})
                created = call("chat.create", {"workspaceId": workspace, "backend": "codex"})
                assert created["profileId"] == work
                changed = call("chat.update", {"id": created["id"], "profileId": "system"})
                assert changed.get("profileId") is None
                call("profiles.setWorkspaceLock", {"workspaceId": workspace, "profileId": work})
                assert "locked" in call("chat.create", {
                    "workspaceId": workspace, "backend": "codex", "profileId": "system",
                }, succeeds=False).lower()
                assert "locked" in call("chat.send", {"id": legacy["id"], "text": "must not launch"}, succeeds=False).lower()
                assert "repositories" in call("profiles.delete", {"id": work}, succeeds=False).lower()
                continued = call("chat.continueInNew", {"id": legacy["id"], "profileId": work})
                assert continued["profileId"] == work
                assert continued["continuedFrom"] == legacy["id"]
                again = call("chat.continueInNew", {"id": legacy["id"], "profileId": work})
                assert again["id"] == continued["id"], (again, continued)

                terminal = call("pty.spawn", {"workspaceId": workspace, "command": "codex",
                                               "args": ["--fixture-profile-terminal"], "hidden": True})
                terminal_trace = scratch / "terminal.json"
                wait_for(terminal_trace.is_file)
                run = json.loads(terminal_trace.read_text())
                assert Path(run["home"]).samefile(login.parent) and not run["hasSystemKey"], run
                call("pty.close", {"id": terminal["id"]})

                call("chat.send", {"id": continued["id"], "text": "Run on the Work login",
                                   "expectedRevision": continued["sendRevision"],
                                   "clientMessageId": str(uuid.uuid4()),
                                   "clientMessageCreatedAtMs": int(time.time() * 1000)})
                chat_trace = scratch / "chat.json"
                wait_for(chat_trace.is_file)
                run = json.loads(chat_trace.read_text())
                assert (Path(run["home"]) / "auth.json").samefile(login) and not run["hasSystemKey"], run
                wait_for(lambda: any("Profile test turn" in json.dumps(event)
                                     for event in call("chat.events", {"id": continued["id"]})["events"]))

                call("config.limitsSync", {"enabled": False, "skip": sources})
                limits = [row for row in call("usage.limits", {"force": True}) if row["source"] == "codex"]
                observed = {row.get("profileId"): row["windows"][0]["percent"] for row in limits}
                assert observed == {None: 70.0, work: 25.0}, observed
                assert not service.received

                call("config.limitsSync", {"enabled": True})
                call("usage.limits", {"force": True})
                posted, = service.received
                uploaded = {row.get("profile_id"): row["windows"][0]["percent"] for row in posted["providers"]}
                assert uploaded == observed, posted
                assert "Work" not in json.dumps(posted) and "fixture-only" not in json.dumps(posted), posted

                for error in [
                    {"error": "unknown_field", "message": "Unknown provider field: profile_id"},
                    {"error": "invalid_schema", "message": "providers must be an array of at most 32."},
                ]:
                    service.received.clear()
                    service.legacy_error = error
                    call("usage.limits", {"force": True})
                    attempted, fallback = service.received
                    assert any(row.get("profile_id") == work for row in attempted["providers"]), attempted
                    assert [
                        (row.get("profile_id"), row["windows"][0]["percent"]) for row in fallback["providers"]
                    ] == [(None, 70.0)], fallback
                call("config.limitsSync", {"enabled": False})

                fixtures = root / "fixtures/claude_code/resume-duplicates"
                system = home / ".claude/projects/project"
                profile = data / "profiles" / work / "claude_code/projects/project"
                system.mkdir(parents=True)
                profile.mkdir(parents=True)
                shutil.copy(fixtures / "session-000.jsonl", system)
                shutil.copy(fixtures / "session-004.jsonl", profile)
                call("scan")
                by_profile = call("insights.snapshot")["byProfile"]
                assert {row["key"] for row in by_profile} == {"system", work}, by_profile

                call("profiles.setWorkspaceLock", {"workspaceId": workspace})
                call("profiles.delete", {"id": work})
                assert not login.exists()
                assert "removed" in call("launcher.checkSignIn", {"id": "codex", "profile": work}, succeeds=False).lower()
                assert call("profiles.list")["default"] == "system"
            finally:
                service.shutdown()
                listener.join()
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()

    print("Agent profiles: login isolation, defaults and locks, continuation, limits, opt-in uploads, and archive attribution passed")


if __name__ == "__main__":
    main()
