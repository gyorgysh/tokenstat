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
        process = subprocess.Popen(
            [str(hostd), "--socket", str(endpoint)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 20
            while not endpoint.exists():
                if process.poll() is not None:
                    raise AssertionError(f"hostd exited: {process.stderr.read()}")
                assert time.monotonic() < deadline, "hostd did not bind its socket"
                time.sleep(0.05)

            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(20)
                connection.connect(str(endpoint))
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
                    assert protocol["protocolVersion"] == "34", protocol

                    info = call("info", {})
                    require_fields(info, [
                        "protocolVersion", "coreVersion", "dbPath", "hasArchive", "timezone",
                        "priceBookEffectiveFrom", "hasPrices",
                    ], "info")
                    assert info["protocolVersion"] == "34" and info["hasArchive"] is True

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
            print("1.5.0 client wire compatibility: protocol, info, workspaces, chats OK")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
