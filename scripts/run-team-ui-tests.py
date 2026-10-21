#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the fictional Teams app on a new, separately owned iOS Simulator."""

import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent


def output(*arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True, timeout=60).strip()


def selection():
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    types = json.loads(output("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    preferred = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro", "iPhone 14 Pro"]
    choices = []
    for runtime in runtimes:
        version = tuple(int(part) for part in runtime["version"].split("."))
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"] or version < (17,):
            continue
        supported = {item["identifier"] for item in runtime.get("supportedDeviceTypes", [])}
        encoded_version = sum(part << shift for part, shift in zip((version + (0, 0))[:3], (16, 8, 0)))
        for device in types:
            if not device["name"].startswith("iPhone "):
                continue
            if supported:
                if device["identifier"] not in supported:
                    continue
            elif not device.get("minRuntimeVersion", 0) <= encoded_version <= device.get("maxRuntimeVersion", 0xFFFFFFFF):
                continue
            rank = preferred.index(device["name"]) if device["name"] in preferred else len(preferred)
            choices.append(((rank, tuple(-part for part in version), device["name"]), runtime, device))
    if not choices:
        raise RuntimeError("No installed, compatible iPhone runtime supports the Teams fixture (iOS 17 or later).")
    _, runtime, device = min(choices, key=lambda choice: choice[0])
    return {"runtime": runtime["identifier"], "version": runtime["version"], "type": device["identifier"], "name": device["name"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--select-only", action="store_true", help="Report a compatible installed runtime without creating or changing a device.")
    parser.add_argument("--only-test", action="append", default=[], help="Run a named XCTest method for a focused local check; omit for the full CI suite.")
    args = parser.parse_args()
    if len(set(args.only_test)) != len(args.only_test) or any(not name.startswith("test") or not name.isalnum() for name in args.only_test):
        parser.error("Use distinct XCTest method names beginning with test.")
    selected = selection()
    if args.select_only:
        print(json.dumps(selected))
        return 0
    unique = uuid.uuid4().hex
    name = "tokenstat Teams CI " + unique[:12]
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
    result_root = ROOT / "target" / "teams-ui-ci" / (stamp + "-" + unique[:8])
    result_root.mkdir(parents=True, exist_ok=False)
    bundle = result_root / "Tests.xcresult"
    owned_device = None
    try:
        # No existing device identifier is accepted. Cleanup can affect only
        # the device this invocation created, never a person's simulator.
        created = output("xcrun", "simctl", "create", name, selected["type"], selected["runtime"])
        uuid.UUID(created)
        owned_device = created
        subprocess.run(["xcrun", "simctl", "boot", owned_device], check=True, timeout=60)
        subprocess.run(["xcodegen", "generate", "--spec", "scripts/qa/teams/project.yml"], cwd=ROOT, check=True, timeout=60)
        print(f"Testing fictional Teams views on {selected['name']} / iOS {selected['version']}", flush=True)
        with (result_root / "build.log").open("w") as log:
            result = subprocess.run([
                "xcodebuild", "-project", "scripts/qa/teams/TeamUIFixture.xcodeproj", "-scheme", "TeamUIFixture",
                "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=" + owned_device,
                "-derivedDataPath", str(result_root / "DerivedData"), "-resultBundlePath", str(bundle),
                "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "test",
                *["-only-testing:TeamFixtureUITests/TeamFixtureUITests/" + name for name in args.only_test],
            ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        if result.returncode:
            print((result_root / "build.log").read_text()[-5000:], file=sys.stderr)
            return result.returncode
        summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"))
        (result_root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        required = len(args.only_test) if args.only_test else 15
        if summary.get("result") != "Passed" or summary.get("passedTests", 0) < required or summary.get("skippedTests", 0):
            raise RuntimeError("Teams UI checks did not run and pass every required scenario.")
        print(f"Teams UI: {summary['passedTests']} passed. Results: {bundle}")
        return 0
    finally:
        if owned_device:
            # Never `shutdown all`; nothing outside this disposable simulator
            # is installed, launched, stopped or removed.
            subprocess.run(["xcrun", "simctl", "shutdown", owned_device], capture_output=True, timeout=60)
            removed = subprocess.run(["xcrun", "simctl", "delete", owned_device], capture_output=True, timeout=60)
            if removed.returncode:
                raise RuntimeError("Could not remove the disposable Teams simulator: " + owned_device)


if __name__ == "__main__":
    sys.exit(main())
