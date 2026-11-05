# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Controlled Grok protocol substitute, run only by the native history fixture."""
import json
import pathlib
import sys
import time

if "-p" not in sys.argv:
    print("grok native-history QA 1.0")
    raise SystemExit(0)

root = pathlib.Path(__file__).resolve().parent.parent
print(json.dumps({"type": "text", "data": "network-start"}), flush=True)
with (root / "provider.ndjson").open() as commands:
    while not (root / "stop").exists():
        line = commands.readline()
        if not line:
            time.sleep(0.01)
            continue
        event = json.loads(line)
        if "splitText" in event:
            output = (json.dumps({"type": "text", "data": event["splitText"]}, ensure_ascii=False) + "\n").encode()
            split = output.index("🌍".encode()) + 2
            sys.stdout.buffer.write(output[:split])
            sys.stdout.buffer.flush()
            (root / "partial.ready").touch()
            while not (root / "partial.release").exists():
                if (root / "stop").exists():
                    raise SystemExit(0)
                time.sleep(0.01)
            sys.stdout.buffer.write(output[split:])
            sys.stdout.buffer.flush()
        else:
            print(json.dumps(event, ensure_ascii=False), flush=True)
        if event.get("type") == "end":
            break
