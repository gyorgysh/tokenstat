#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run shipping Mac/iPhone chat views through independent encrypted connections.

Prepare and build scripts/tests/prepare-history-apple-qa.py first. This owns a
new test root, producer process, two fragmenting TCP proxies and two QA apps.
Only fresh identities can use the producer. All traffic stays on this machine;
the local interface address lets the normal direct-candidate checks run.
--serve leaves the fixture available for inspection until its stop file exists.
"""
import argparse
import asyncio
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "target/chat-performance/history-encrypted-native"
PHONE = "ai.tokenstat.qa.history.phone"


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def atomic_json(path, value):
    staged = path.with_suffix(".tmp")
    staged.write_text(json.dumps(value, indent=2) + "\n")
    staged.replace(path)


async def command(*args, env=None, timeout=120):
    process = await asyncio.create_subprocess_exec(*map(str, args), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), timeout)
    except BaseException:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
        await process.wait()
        raise
    if process.returncode:
        raise RuntimeError(f"{args[0]} exited {process.returncode}: {output.decode(errors='replace')[-4000:]}")
    return output.decode()


class Proxy:
    def __init__(self):
        self.destination = None
        self.offline = False
        self.fragment = 512
        self.delay = 0.001
        self.connections = set()
        self.tasks = set()
        self.bytes_to_client = 0
        self.bytes_to_host = 0
        self.active_responses = 0
        self.cuts = 0
        self.partial_cuts = 0
        self.accepted = 0

    def set_offline(self, offline):
        self.offline = offline
        if offline:
            self.cuts += len(self.connections)
            self.partial_cuts += self.active_responses
            for pair in list(self.connections):
                for stream in pair:
                    stream.transport.abort()

    async def forward(self, reader, writer, response):
        while not self.offline:
            data = await reader.read(4096)
            if not data:
                return
            if response:
                self.active_responses += 1
            try:
                for start in range(0, len(data), self.fragment):
                    if self.offline:
                        return
                    chunk = data[start:start + self.fragment]
                    writer.write(chunk)
                    await writer.drain()
                    if response:
                        self.bytes_to_client += len(chunk)
                    else:
                        self.bytes_to_host += len(chunk)
                    await asyncio.sleep(self.delay)
            finally:
                if response:
                    self.active_responses -= 1

    async def handle(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        pair = (writer,)
        forwards = []
        try:
            self.accepted += 1
            if self.offline:
                return
            upstream, host_writer = await asyncio.open_connection(*self.destination)
            pair = (writer, host_writer)
            self.connections.add(pair)
            forwards = [asyncio.create_task(self.forward(reader, host_writer, False)),
                        asyncio.create_task(self.forward(upstream, writer, True))]
            await asyncio.wait(forwards, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ConnectionError):
            pass
        finally:
            self.connections.discard(pair)
            for stream in pair:
                stream.transport.abort()
            for forward in forwards:
                forward.cancel()
            await asyncio.gather(*forwards, return_exceptions=True)
            self.tasks.discard(task)

    async def close(self):
        self.set_offline(True)
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)

    def status(self):
        return {"accepted": self.accepted, "cuts": self.cuts,
            "partialCuts": self.partial_cuts, "bytesToClient": self.bytes_to_client,
            "bytesToHost": self.bytes_to_host, "activeResponses": self.active_responses}


def producer_binary(run_root):
    result = subprocess.run(["cargo", "test", "--locked", "-p", "tokenstat-host", "--lib",
        "remote::history_tests::native::serve_fixture", "--no-run", "--message-format=json"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    (run_root / "producer-build.log").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"Producer build failed: {result.stderr[-4000:]}")
    for line in result.stdout.splitlines():
        artifact = json.loads(line)
        if artifact.get("executable") and artifact.get("target", {}).get("name") == "tokenstat_host":
            return artifact["executable"]
    raise RuntimeError("Cargo did not report the native history test executable")


async def run(args):
    run_root = ROOT / "target/chat-performance" / f"history-encrypted-run-{uuid.uuid4().hex[:8]}"
    run_root.mkdir(mode=0o700)
    print("Fixture root:", run_root, flush=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("1.1.1.1", 443))  # Select a local route; sends no packet.
        address = sock.getsockname()[0]
    finally:
        sock.close()
    ip = ipaddress.ip_address(address)
    assert ip.is_private and not (ip.is_loopback or ip.is_link_local), "A private local interface is required"
    proxies = {role: Proxy() for role in ["desktop", "phone"]}
    listeners = {}
    producer = desktop = None
    phone_started = False
    booted_here = False
    handles = []
    commands = {"desktop": 0, "phone": 0}
    roles = ["desktop"] if args.desktop_only else list(proxies)
    proofs = []
    recovery_ms = {}

    def state(role):
        return read_json(run_root / role / "state.json")

    def live():
        for name, process in [("producer", producer), ("desktop", desktop)]:
            if process and process.poll() is not None:
                raise RuntimeError(f"The owned {name} exited; inspect {run_root}")

    async def wait(predicate, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            live()
            result = predicate()
            if result:
                return result
            await asyncio.sleep(0.02)
        raise TimeoutError(f"Native history fixture timed out; inspect {run_root}")

    async def native(role, action="snapshot", expected=None):
        commands[role] += 1
        number = commands[role]
        request = {"id": number, "action": action}
        if expected:
            request["expected"] = expected
        atomic_json(run_root / role / "command.json", request)
        result = await wait(lambda: read_json(run_root / role / f"result-{number}.json"), 30)
        assert result["ok"], (role, result)
        return result

    def emit(event):
        with (run_root / "provider.ndjson").open("a") as stream:
            stream.write(json.dumps(event, ensure_ascii=False) + "\n")

    async def visible(text):
        await asyncio.gather(*(native(role, expected=text) for role in roles))

    def prove(text):
        proofs.append(text)
        print("PASS", text, flush=True)

    try:
        client_addresses = {}
        for role, proxy in proxies.items():
            listeners[role] = await asyncio.start_server(proxy.handle, address, 0)
            port = listeners[role].sockets[0].getsockname()[1]
            client_addresses[role] = f"{address}:{port}"
        environment = dict(os.environ, TOKENSTAT_NATIVE_HISTORY_ROOT=str(run_root),
            TOKENSTAT_NATIVE_HISTORY_CLIENTS=json.dumps(client_addresses),
            TOKENSTAT_NATIVE_HISTORY_LISTEN=f"{address}:0",
            TOKENSTAT_NATIVE_HISTORY_PYTHON=sys.executable,
            TOKENSTAT_IDENTITY_DIR=str(run_root / "host-identity"),
            HOME=str(run_root / "home"), ZDOTDIR=str(run_root / "home"), HISTFILE=os.devnull,
            PATH=str(run_root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")
        log = (run_root / "producer.log").open("w"); handles.append(log)
        producer = subprocess.Popen([producer_binary(run_root), "--exact",
            "remote::history_tests::native::serve_fixture", "--ignored", "--nocapture"],
            cwd=ROOT, env=environment, stdout=log, stderr=log)
        fixture = await wait(lambda: read_json(run_root / "fixture.json"))
        host, port = fixture["address"].rsplit(":", 1)
        for proxy in proxies.values():
            proxy.destination = (host, int(port))

        def client_environment(role):
            client = run_root / role
            return dict(os.environ, TOKENSTAT_NATIVE_HISTORY_ROLE=role,
                TOKENSTAT_NATIVE_HISTORY_FIXTURE=str(run_root / "fixture.json"),
                TOKENSTAT_NATIVE_HISTORY_DESKTOP_LOCAL="1" if args.desktop_local else "0",
                TOKENSTAT_DATA_DIR=str(client / "data"), TOKENSTAT_IDENTITY_DIR=str(client / "identity"),
                HOME=str(client / "home"), ZDOTDIR=str(client / "home"), HISTFILE=os.devnull)

        probe = r'''
import ctypes,json,os
from pathlib import Path
root=Path(os.environ['TOKENSTAT_NATIVE_HISTORY_FIXTURE'])
fixture=json.loads(root.read_text())
library=ctypes.CDLL(os.environ['TOKENSTAT_NATIVE_HISTORY_FFI'])
library.tokenstat_ffi_call.argtypes=[ctypes.c_char_p,ctypes.c_char_p]
library.tokenstat_ffi_call.restype=ctypes.c_void_p
library.tokenstat_ffi_string_free.argtypes=[ctypes.c_void_p]
params={'peer':fixture['hostKey'],'method':'chat.eventPage','params':{'id':fixture['conversationId'],'limit':10,'stablePositions':True}}
pointer=library.tokenstat_ffi_call(b'remote.call',json.dumps(params).encode())
try: result=json.loads(ctypes.string_at(pointer))
finally: library.tokenstat_ffi_string_free(pointer)
assert result.get('ok'),result
assert result['result']['events'],result
print(json.dumps({'events':len(result['result']['events'])}))
'''
        for role in proxies:
            probe_environment = client_environment(role)
            probe_environment['TOKENSTAT_NATIVE_HISTORY_FFI'] = str(ROOT / 'target/aarch64-apple-darwin/release-ffi/libtokenstat_ffi.dylib')
            await command(sys.executable, '-c', probe, env=probe_environment)
        prove("Both fresh identities read history through the production FFI and pinned encrypted RPCs")
        if args.probe_only:
            atomic_json(run_root / "result.json", {"ok": True, "proofs": proofs,
                "proxies": {role: proxy.status() for role, proxy in proxies.items()}})
            return

        app = args.mac_app
        executable = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
        log = (run_root / "desktop.log").open("w"); handles.append(log)
        desktop = subprocess.Popen([str(app / "Contents/MacOS" / executable)],
            env=client_environment("desktop"), stdout=log, stderr=log)
        if not args.desktop_only:
            inventory = json.loads(await command("xcrun", "simctl", "list", "devices", "available", "--json"))
            device = next(device for devices in inventory["devices"].values()
                for device in devices if device["udid"] == args.simulator)
            if device["state"] != "Booted":
                await command("xcrun", "simctl", "boot", args.simulator)
                booted_here = True
                await command("xcrun", "simctl", "bootstatus", args.simulator, "-b")
            await command("xcrun", "simctl", "install", args.simulator, args.phone_app)
            launch_environment = dict(os.environ)
            for key, value in client_environment("phone").items():
                if key.startswith("TOKENSTAT_") or key in ["HOME", "ZDOTDIR", "HISTFILE"]:
                    launch_environment["SIMCTL_CHILD_" + key] = value
            phone_started = True
            await command("xcrun", "simctl", "launch", args.simulator, PHONE, env=launch_environment)
        print("Native QA apps launched:", ", ".join(roles), flush=True)
        await wait(lambda: all(state(role) and state(role)["loaded"] for role in roles), 180)
        await visible("network-start")
        if args.desktop_only:
            emit({"type": "text", "data": "\n\nnetwork-alpha"})
            await visible("network-alpha")
            prove("The native Mac view renders local history and follows a real provider update" if args.desktop_local else
                  "The native Mac view renders encrypted history and follows a real provider update")
            for marker in ["network-beta", "network-gamma"]:
                emit({"type": "text", "data": "\n\n" + "network padding " * 2000 + "\n\n" + marker})
                await visible(marker)
                await native("desktop", "hide")
                await native("desktop", "show", marker)
            emit({"type": "text", "data": "\n\nnetwork-finished"})
            emit({"type": "end", "stopReason": "end_turn"})
            await wait(lambda: state("desktop") and not state("desktop")["running"])
            await visible("network-finished")
            prove("The native Mac view follows two large replies through navigation and completion")
            atomic_json(run_root / "result.json", {"ok": True, "proofs": proofs, "states": {role: state(role) for role in roles}})
            return
        prove("Mac local view and encrypted iPhone render the same live chat" if args.desktop_local else
              "Mac and iPhone render the same live chat over distinct pinned encrypted connections")
        if args.serve:
            await wait(lambda: (run_root / "stop").exists(), 700)
            return

        emit({"type": "text", "data": "\n\nnetwork-alpha"})
        await visible("network-alpha")
        before = {role: state(role)["events"] for role in proxies}
        await native("desktop", "earlier", "network-alpha")
        await wait(lambda: state("desktop")["events"] > before["desktop"])
        assert state("phone")["events"] == before["phone"]
        prove("Earlier paging on the Mac preserves the iPhone's independent history window")

        faults = [("phone", "desktop", "network-beta")] if args.desktop_local else [
            ("desktop", "phone", "network-beta"), ("phone", "desktop", "network-gamma")]
        for role, other, marker in faults:
            proxy = proxies[role]
            proxy.delay = 0.005
            emit({"type": "text", "data": "\n\n" + "network padding " * 2000 + "\n\n" + marker})
            await wait(lambda: proxy.active_responses > 0)
            accepted = proxy.accepted
            proxy.set_offline(True)
            started = time.monotonic()
            recovered = marker + "-recovered"
            # This text does not exist until the connection is cut. Seeing it
            # after restoration proves a fresh read, rather than cached text.
            emit({"type": "text", "data": "\n\n" + recovered})
            await native(role, expected="network-")
            await native(other, expected=recovered)
            await asyncio.sleep(max(0, 2 - (time.monotonic() - started)))
            assert state(role)["events"] > 0 and state(role)["blankSamples"] == 0
            proxy.set_offline(False)
            proxy.delay = 0.001
            restored = time.monotonic()
            await visible(recovered)
            recovery_ms[role] = round((time.monotonic() - restored) * 1000)
            assert proxy.accepted > accepted
            prove(f"{role} keeps displayed history through a cut response and recovers while {other} keeps updating")

        before = {role: state(role)["lastSeq"] for role in proxies}
        emit({"splitText": "\n\nnetwork-unicode café 🌍"})
        await wait(lambda: (run_root / "partial.ready").exists())
        await asyncio.sleep(1)
        assert all(state(role)["lastSeq"] == before[role] for role in proxies)
        await visible(faults[-1][2] + "-recovered")
        (run_root / "partial.release").touch()
        await visible("network-unicode")
        prove("A provider record split inside UTF-8 does not replace displayed history or advance either reader early")

        for role in proxies:
            await native(role, "hide")
            await native(role, "show", "network-unicode")
        emit({"type": "text", "data": "\n\nnetwork-finished"})
        emit({"type": "end", "stopReason": "end_turn"})
        await wait(lambda: all(state(role) and not state(role)["running"] for role in proxies))
        await visible("network-finished")
        for role in proxies:
            current = state(role)
            assert current["blankSamples"] == 0 and current["uniqueSeq"] == current["events"], current
        prove("Both native views retain unique history through navigation and provider completion")
        assert all(proxies[role].partial_cuts > 0 and proxies[role].accepted > 1 for role, _, _ in faults)
        atomic_json(run_root / "result.json", {"ok": True, "proofs": proofs,
            "states": {role: state(role) for role in proxies},
            "recoveryMs": recovery_ms,
            "proxies": {role: proxy.status() for role, proxy in proxies.items()}})
    except Exception:
        if desktop and desktop.poll() is None:
            # Capture the owned app before cleanup, especially when its main
            # thread cannot service the fixture's snapshot command.
            with contextlib.suppress(Exception):
                await command("/usr/bin/sample", desktop.pid, "2", "-file",
                    run_root / "desktop-sample.txt", timeout=10)
        raise
    finally:
        cleanup_errors = []
        if phone_started:
            try:
                await command("xcrun", "simctl", "terminate", args.simulator, PHONE, timeout=15)
            except Exception as error:
                cleanup_errors.append(f"Phone termination: {type(error).__name__}: {error}")
        if desktop and desktop.poll() is None:
            desktop.terminate()
            try:
                await asyncio.to_thread(desktop.wait, timeout=10)
            except subprocess.TimeoutExpired:
                desktop.kill(); await asyncio.to_thread(desktop.wait)
        (run_root / "stop").touch()
        for proxy in proxies.values():
            await proxy.close()
        for listener in listeners.values():
            listener.close()
            await listener.wait_closed()
        if producer:
            try:
                await asyncio.to_thread(producer.wait, timeout=15)
            except subprocess.TimeoutExpired:
                producer.terminate()
                try:
                    await asyncio.to_thread(producer.wait, timeout=5)
                except subprocess.TimeoutExpired:
                    producer.kill(); await asyncio.to_thread(producer.wait)
        if booted_here:
            try:
                await command("xcrun", "simctl", "shutdown", args.simulator, timeout=30)
            except Exception as error:
                cleanup_errors.append(f"Simulator shutdown: {type(error).__name__}: {error}")
        atomic_json(run_root / "cleanup.json", {"ok": not cleanup_errors, "errors": cleanup_errors})
        for error in cleanup_errors:
            print(f"Cleanup failed: {error}", file=sys.stderr, flush=True)
        for handle in handles:
            handle.close()
        if not (run_root / "result.json").exists():
            atomic_json(run_root / "result.json", {"ok": False, "proofs": proofs,
                "states": {role: state(role) for role in proxies},
                "recoveryMs": recovery_ms,
                "proxies": {role: proxy.status() for role, proxy in proxies.items()}})
        print("Artifacts:", run_root, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Exact simulator UDID; never erased")
    parser.add_argument("--mac-app", type=Path, default=QA / "mac/Build/Products/Debug/HistoryMac.app")
    parser.add_argument("--phone-app", type=Path, default=QA / "phone/Build/Products/Debug-iphonesimulator/HistoryPhone.app")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--probe-only", action="store_true", help="Verify the producer and encrypted FFI setup before opening apps")
    parser.add_argument("--desktop-only", action="store_true", help="Verify the Mac view before the combined phone run")
    parser.add_argument("--desktop-local", action="store_true", help="Use the producer's local socket on Mac, with the iPhone still encrypted")
    asyncio.run(run(parser.parse_args()))
