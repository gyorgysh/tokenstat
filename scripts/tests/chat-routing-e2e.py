#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production host/runner with controlled provider executables.

Build tokenstat-hostd first. This creates a private socket, data/identity roots,
workspace and PATH; fake providers never call a service or execute tools.
--serve retains a labelled limit fixture for native UI tests for at most 15 min.
Stop that fixture with target/routing-qa/native-fixture.stop.
"""
import argparse
import json
import os
import plistlib
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "target/routing-qa"
FAKE_PROVIDER = r'''#!/usr/bin/python3
import fcntl, json, os, pathlib, sys, time, uuid
root = pathlib.Path(__file__).resolve().parent.parent
backend = pathlib.Path(sys.argv[0]).name
# Catalog probes are separate from turns and must not consume a refusal.
if '--version' in sys.argv or '--help' in sys.argv or 'app-server' in sys.argv or sys.argv[1:] == ['models']:
    print(backend + ' QA 1.0')
    sys.exit(0)
with (root / 'control.json').open('r+') as file:
    fcntl.flock(file, fcntl.LOCK_EX)
    state = json.load(file)
    steps = state[backend]
    step = steps.pop(0) if steps else {'kind': 'ok'}
    file.seek(0)
    json.dump(state, file)
    file.truncate()
with (root / 'trace.ndjson').open('a') as file:
    file.write(json.dumps({'backend': backend, 'args': sys.argv[1:], 'cwd': os.getcwd(),
                           'step': step, 'desktopApp': os.environ.get('TOKENSTAT_DESKTOP_APP', ''), 'at': int(time.time() * 1000)}) + '\n')
def emit(value):
    print(json.dumps(value), flush=True)
if step['kind'] == 'quota':
    emit({'type': 'error', 'error': {'code': 'usage_limit_reached',
          'message': 'Controlled QA usage limit', 'resets_at': step['reset']}})
    sys.exit(1)
if backend == 'codex':
    emit({'type': 'thread.started', 'thread_id': str(uuid.uuid4())})
    emit({'type': 'item.completed', 'item': {'id': 'qa', 'type': 'agent_message', 'text': 'QA OK'}})
    emit({'type': 'turn.completed', 'usage': {'input_tokens': 10, 'output_tokens': 2}})
else:
    emit({'type': 'text', 'data': 'QA OK'})
    emit({'type': 'end', 'sessionId': str(uuid.uuid4()), 'requestId': str(uuid.uuid4())})
'''


def wait(predicate, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out awaiting routing state")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--fixture-only", action="store_true", help="Serve the native fixture after a separate E2E run")
    parser.add_argument("--host", type=Path, default=ROOT / "target/debug/tokenstat-hostd")
    parser.add_argument("--desktop-app", type=Path, help="Validate local agent targeting of this Mac bundle instead of a fixture")
    args = parser.parse_args()
    if args.fixture_only and not args.serve:
        parser.error("--fixture-only requires --serve")
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ts-route-") as temporary:
        root = Path(temporary)
        (root / "bin").mkdir()
        (root / "project").mkdir()
        (root / "home" / ".grok").mkdir(parents=True)
        (root / "home" / ".grok" / "auth.json").write_text("{}")
        (root / "home" / ".codex").mkdir()
        (root / "home" / ".codex" / "auth.json").write_text("{}")
        # macOS /etc/zshrc enables history for idle pooled shells. Keep those
        # writers out of the temporary home while the daemon is torn down.
        (root / "home" / ".zshrc").write_text("HISTFILE=/dev/null\nSAVEHIST=0\n")
        control = root / "control.json"
        control.write_text(json.dumps({"codex": [], "grok": []}))
        for backend in ("codex", "grok"):
            executable = root / "bin" / backend
            executable.write_text(FAKE_PROVIDER.replace("#!/usr/bin/python3", f"#!{sys.executable}", 1))
            executable.chmod(0o700)
        desktop_app = None
        if sys.platform == "darwin":
            desktop_app = args.desktop_app.resolve() if args.desktop_app else root / "Desktop QA space ü.app"
            if args.desktop_app is None:
                (desktop_app / "Contents/MacOS").mkdir(parents=True)
                (desktop_app / "Contents/MacOS/Tokenstat").write_text("fixture")
                (desktop_app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "ai.tokenstat.tokenstat"}))
            desktop_app = desktop_app.resolve()
        elif args.desktop_app:
            parser.error("--desktop-app requires macOS")
        socket_path = root / "host.sock"
        environment = dict(os.environ, TOKENSTAT_DATA_DIR=str(root / "data"),
                           TOKENSTAT_IDENTITY_DIR=str(root / "identity"),
                           HOME=str(root / "home"), ZDOTDIR=str(root / "home"),
                           HISTFILE=os.devnull,
                           PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
        environment.pop("CODEX_HOME", None)
        with (root / "host.log").open("w") as log:
            host = subprocess.Popen([str(args.host), "--socket", str(socket_path)],
                                    env=environment, stdout=log, stderr=log)
            try:
                def call(method, params):
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                        connection.settimeout(20)
                        connection.connect(str(socket_path))
                        request = {"id": str(uuid.uuid4()), "method": method, "params": params}
                        connection.sendall((json.dumps(request) + "\n").encode())
                        response = json.loads(connection.makefile().readline())
                        assert response.get("ok"), response
                        return response["result"]

                def host_ready():
                    if host.poll() is not None:
                        raise AssertionError("QA host exited before accepting requests")
                    try:
                        call("protocol", {})
                        return True
                    except (FileNotFoundError, ConnectionRefusedError):
                        # bind creates the socket path before listen is ready.
                        # Retry only the read-only startup probe, never actions.
                        return False

                wait(host_ready)
                workspace = call("workspace.add", {"path": str(root / "project")})["id"]

                def chat(identifier):
                    return next(row for row in call("chat.list", {"workspaceId": workspace})
                                if row["id"] == identifier)

                def traces():
                    path = root / "trace.ndjson"
                    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

                def setup(title, codex, grok, enabled=True, waiting=False, returning=False):
                    control.write_text(json.dumps({"codex": codex, "grok": grok}))
                    conversation = call("chat.create", {"workspaceId": workspace, "backend": "codex",
                        "model": "gpt-6.1-sol", "effort": "low", "personaId": "", "title": title,
                        "autonomy": "standard", "mode": "execute"})
                    identifier = conversation["id"]
                    call("chat.update", {"id": identifier, "systemPrompt": "QA_STANDING_INSTRUCTIONS: preserve context; do not run tools."})
                    conversation = chat(identifier)
                    call("chat.routing", {"id": identifier, "expectedRevision": conversation["sendRevision"],
                        "routing": {"enabled": enabled,
                            "routes": [{"backend": "grok", "model": "grok-4.7-build-fast", "effort": "high"}],
                            "waitForReset": waiting, "returnPreferred": returning,
                            "useAsDefault": False, "notify": False}})
                    return chat(identifier)

                def send(conversation, text):
                    params = {"id": conversation["id"], "text": text,
                        "expectedRevision": conversation["sendRevision"], "clientMessageId": str(uuid.uuid4()),
                        "clientMessageCreatedAtMs": int(time.time() * 1000)}
                    if desktop_app:
                        params["desktopApp"] = str(desktop_app)
                    call("chat.send", params)

                def completed(identifier, count):
                    return len(traces()) >= count and not chat(identifier)["running"]

                proofs = []
                if not args.fixture_only:
                    reset = int(time.time() * 1000) + 25000
                    conversation = setup("QA automatic failover", [{"kind": "quota", "reset": reset}],
                                         [{"kind": "ok"}], returning=True, waiting=True)
                    start = len(traces())
                    send(conversation, "QA_CONTEXT_MARKER: keep this task through automatic failover.")
                    wait(lambda: completed(conversation["id"], start + 2))
                    rows = traces()[start:]
                    current = chat(conversation["id"])
                    assert [row["backend"] for row in rows] == ["codex", "grok"], rows
                    assert rows[1]["at"] < reset, "Fallback must precede waiting for the first provider"
                    assert current["backend"] == "grok" and current["effort"] == "high"
                    assert current["model"] == "grok-4.7-build-fast" and current["autonomy"] == "standard"
                    assert all(row["cwd"] == workspace for row in rows)
                    prompt = " ".join(rows[1]["args"])
                    assert "QA_CONTEXT_MARKER" in prompt and "QA_STANDING_INSTRUCTIONS" in prompt
                    assert current["allowedTools"] == [] and current["allowedShellPrefixes"] == []
                    wait(lambda: int(time.time() * 1000) > reset)
                    assert len(traces()) == start + 2, "Reset must not interrupt the healthy fallback"
                    send(chat(conversation["id"]), "Next manual turn after reset.")
                    wait(lambda: completed(conversation["id"], start + 3))
                    assert traces()[-1]["backend"] == "codex" and chat(conversation["id"])["backend"] == "codex"
                    proofs.append("fallback before reset; context, workspace, model, effort and permissions preserved; preferred return only on next turn")

                    reset = int(time.time() * 1000) + 2500
                    conversation = setup("QA wait only", [{"kind": "quota", "reset": reset}, {"kind": "ok"}],
                                         [], enabled=False, waiting=True)
                    start = len(traces())
                    send(conversation, "QA wait only")
                    wait(lambda: completed(conversation["id"], start + 2))
                    assert [row["backend"] for row in traces()[start:]] == ["codex", "codex"]
                    assert traces()[-1]["at"] >= reset
                    proofs.append("wait without routing retries the same provider after its known reset")

                    reset = int(time.time() * 1000) + 30000
                    conversation = setup("QA all providers exhausted", [{"kind": "quota", "reset": reset}, {"kind": "ok"}],
                                         [{"kind": "quota", "reset": reset + 60000}], waiting=True)
                    start = len(traces())
                    send(conversation, "QA all providers exhausted")
                    wait(lambda: completed(conversation["id"], start + 2))
                    current = chat(conversation["id"])
                    assert current["routing"]["waiting"]
                    assert current["routing"]["nextReset"]["destination"]["backend"] == "codex"
                    assert current["routing"]["nextReset"]["atMs"] == reset
                    history = call("chat.routingHistory", {"id": current["id"]})["activity"]
                    assert sum(row["kind"] == "usage" for row in history) == 2
                    wait(lambda: completed(conversation["id"], start + 3))
                    assert [row["backend"] for row in traces()[start:]] == ["codex", "grok", "codex"]
                    assert traces()[-1]["at"] >= reset
                    proofs.append("both refusals logged; earliest preserved reset resumes one eligible provider")

                    reset = int(time.time() * 1000) + 20000
                    conversation = setup("QA cancel reset wait", [{"kind": "quota", "reset": reset}],
                                         [], enabled=False, waiting=True)
                    start = len(traces())
                    send(conversation, "QA cancel reset wait")
                    wait(lambda: completed(conversation["id"], start + 1) and chat(conversation["id"])["routing"]["waiting"])
                    current = chat(conversation["id"])
                    call("chat.routeAction", {"id": current["id"], "expectedRevision": current["sendRevision"], "choice": "cancel"})
                    assert not chat(current["id"])["routing"]["waiting"]
                    wait(lambda: int(time.time() * 1000) > reset + 10000)
                    assert len(traces()) == start + 1, "Cancelled wait must not launch after reset"
                    proofs.append("cancelled wait stays cancelled after reset and scheduler tick")

                    if desktop_app:
                        assert traces() and all(row["desktopApp"] == str(desktop_app) for row in traces()), "An agent or continuation lost its originating Mac app"
                        proofs.append("local Mac app origin preserved across manual turns and automatic routing continuations")

                    (OUT / "routing-e2e-proof.json").write_text(json.dumps({"proofs": proofs, "trace": traces()}, indent=2))
                    for proof in proofs:
                        print("PASS", proof, flush=True)
                if args.serve:
                    conversation = setup("Routing QA — simulated limit", [{"kind": "quota", "reset": int(time.time() * 1000) + 3600000}],
                                         [], enabled=False)
                    start = len(traces())
                    send(conversation, "QA limit screen; synthetic provider response, no real quota.")
                    wait(lambda: completed(conversation["id"], start + 1) and chat(conversation["id"])["routing"].get("limit"))
                    stop = OUT / "native-fixture.stop"
                    stop.unlink(missing_ok=True)
                    (OUT / "native-fixture.json").write_text(json.dumps({"socket": str(socket_path), "workspaceId": workspace,
                        "conversationId": conversation["id"], "root": str(root)}))
                    print("SERVING", OUT / "native-fixture.json", flush=True)
                    deadline = time.monotonic() + 900
                    while not stop.exists() and time.monotonic() < deadline:
                        time.sleep(0.5)
                    stop.unlink(missing_ok=True)
            except Exception:
                trace = root / "trace.ndjson"
                print("QA control:", control.read_text(), file=sys.stderr)
                print("QA trace:", trace.read_text()[-4000:] if trace.exists() else "<none>", file=sys.stderr)
                if "workspace" in locals():
                    try:
                        print("QA conversations:", json.dumps(call("chat.list", {"workspaceId": workspace}))[-4000:], file=sys.stderr)
                    except Exception as error:
                        print("QA conversation read failed:", error, file=sys.stderr)
                print("QA host log:", (root / "host.log").read_text()[-4000:], file=sys.stderr)
                raise
            finally:
                host.terminate()
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait(timeout=10)
                fixture = OUT / "native-fixture.json"
                if fixture.is_file():
                    try:
                        if json.loads(fixture.read_text()).get("socket") == str(socket_path):
                            fixture.unlink()
                    except (OSError, ValueError):
                        pass
                (OUT / "routing-e2e-host.log").write_text((root / "host.log").read_text())


if __name__ == "__main__":
    main()
