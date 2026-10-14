#!/usr/bin/env python3
"""Exercise 1.5.0 client wire requests against the current host daemon.

The request shapes and required response fields come from v1.5.0's Apple
Bridge/Models and Windows HostClient. Android uses the same remote dispatch.
Keep this fixture when changing the host: protocol 34 clients are already in
the field and must continue to speak to newer hosts.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def require_fields(value, fields, method):
    assert isinstance(value, dict), (method, value)
    missing = set(fields) - value.keys()
    assert not missing, f"{method} dropped 1.5.0 fields: {sorted(missing)}"


def main():
    hostd = Path(sys.argv[1] if len(sys.argv) > 1 else "target/debug/tokenstat-hostd").resolve()
    with tempfile.TemporaryDirectory(prefix="tokenstat-client-150-") as temporary:
        root = Path(temporary)
        data = root / "data"
        work = Path(__file__).resolve().parents[2]
        data.mkdir()
        endpoint = root / "host.sock"
        environment = os.environ.copy()
        environment["TOKENSTAT_DATA_DIR"] = str(data)
        # Exercise quota decoding without contacting vendors or using the
        # developer's installed OAuth login. Muse falls back to a dated cache.
        environment["XDG_CONFIG_HOME"] = str(root / "config")
        (data / "limits-cache.json").write_text(json.dumps({"muse": {
            "source": "muse", "plan": "Muse Code Everyday Usage",
            "windows": [
                {"label": "5-hour", "scope": None, "percent": 4.0,
                 "resetsAtMs": 1791847496000, "severity": "normal"},
                {"label": "weekly", "scope": None, "percent": 1.0,
                 "resetsAtMs": 1792368000000, "severity": "normal"},
            ],
            "observedAtMs": 1791829616048, "note": None, "stale": False,
        }}))
        process = subprocess.Popen(
            [str(hostd), "--socket", str(endpoint)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 20
            while True:
                if process.poll() is not None:
                    raise AssertionError(f"hostd exited: {process.stderr.read()}")
                connection = socket.socket(socket.AF_UNIX)
                connection.settimeout(20)
                try:
                    connection.connect(str(endpoint))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    connection.close()
                    assert time.monotonic() < deadline, "hostd did not listen on its socket"
                    time.sleep(0.05)

            with connection:
                with connection.makefile("rwb", buffering=0) as stream:
                    request_id = 0

                    def call(method, params):
                        nonlocal request_id
                        request_id += 1
                        # v1.5.0 SocketTransport and HostClient use this line
                        # framing and require an echoed id and ok/result envelope.
                        request = {"id": request_id, "method": method, "params": params}
                        stream.write((json.dumps(request, separators=(",", ":")) + "\n").encode())
                        line = stream.readline()
                        assert line, f"hostd closed the connection on {method}"
                        answer = json.loads(line)
                        assert answer.get("id") == request_id, (method, answer)
                        assert answer.get("ok") is True, (method, answer)
                        return answer["result"]

                    protocol = call("protocol", {})
                    require_fields(protocol, ["protocolVersion", "coreVersion"], "protocol")
                    # New host capabilities raise the protocol without
                    # changing these older clients' request/response shapes.
                    assert int(protocol["protocolVersion"]) >= 34, protocol

                    info = call("info", {})
                    require_fields(info, [
                        "protocolVersion", "coreVersion", "dbPath", "hasArchive", "timezone",
                        "priceBookEffectiveFrom", "hasPrices",
                    ], "info")
                    assert info["protocolVersion"] == protocol["protocolVersion"] and info["hasArchive"] is True

                    folder = call("workspace.add", {"path": str(work)})
                    require_fields(folder, ["id", "path", "name", "addedAtMs", "exists"], "workspace.add")
                    workspace_id = folder["id"]
                    assert isinstance(workspace_id, str) and workspace_id
                    folders = call("workspace.list", {})
                    assert isinstance(folders, list) and any(row["id"] == workspace_id for row in folders)

                    # This is the v1.5.0 Bridge.createChat payload, including
                    # its omitted optional model/persona fields.
                    chat = call("chat.create", {
                        "workspaceId": workspace_id,
                        "backend": "codex",
                        "title": "Legacy client fixture",
                        "mode": "execute",
                        "autonomy": "standard",
                    })
                    required_chat = ["id", "workspaceId", "title", "backend"]
                    require_fields(chat, required_chat, "chat.create")
                    assert chat["workspaceId"] == workspace_id
                    chats = call("chat.list", {"workspaceId": workspace_id})
                    assert isinstance(chats, list) and any(row["id"] == chat["id"] for row in chats)
                    for row in chats:
                        require_fields(row, required_chat, "chat.list")
                    assert isinstance(call("chat.recent", {"limit": 50}), list)
                    call("config.limitsSync", {"enabled": False, "skip": [
                        "codex", "claude_code", "cursor", "grok", "opencode", "antigravity",
                    ]})
                    limits = call("usage.limits", {})
                    assert isinstance(limits, list) and len(limits) == 1, limits
                    muse = limits[0]
                    require_fields(muse, [
                        "source", "plan", "windows", "observedAtMs", "note", "stale",
                    ], "usage.limits")
                    assert muse["source"] == "muse" and muse["stale"] is True, muse
                    assert len(muse["windows"]) == 2
                    for window in muse["windows"]:
                        require_fields(window, [
                            "label", "scope", "percent", "resetsAtMs", "severity",
                        ], "usage.limits window")
                        assert window["severity"] == "normal"
            print("1.5.0 client wire compatibility: protocol, info, workspaces, chats, limits OK")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
