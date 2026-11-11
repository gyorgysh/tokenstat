#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare local Gregorian timeline days across real timezone transitions."""
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
SWIFT = '''import Foundation
struct Fixture: Decodable { let now_ms: Int64; let timestamps_ms: [Int64] }
let fixture = try JSONDecoder().decode(Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: CommandLine.arguments[1])!
let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(fixture.now_ms) / 1000))
let values = fixture.timestamps_ms.map { timestamp -> [Int64] in
    let start = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(timestamp) / 1000))
    let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
    return [Int64(start.timeIntervalSince1970), Int64(min(7, max(0, days)))]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: values))
'''


def main():
    subprocess.run(["cargo", "build", "--quiet", "--manifest-path", str(ROOT / "apps/linux/Cargo.toml"), "--no-default-features", "--example", "sidebar-calendar-contract", "--locked"], cwd=ROOT, check=True)
    binary = ROOT / "apps/linux/target/debug/examples/sidebar-calendar-contract"
    scenarios = [("America/New_York", 2024, 3, 11), ("America/New_York", 2024, 11, 4),
                 ("Europe/Budapest", 2024, 4, 1), ("Australia/Lord_Howe", 2024, 10, 7),
                 ("Pacific/Apia", 2012, 1, 2), ("America/Sao_Paulo", 2018, 11, 5),
                 ("America/Havana", 2024, 11, 4), ("America/Santiago", 2024, 9, 9)]
    count = 0
    cases = []
    (ROOT / "target").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "target") as tmp:
        path = Path(tmp)
        (path / "Reference.swift").write_text(SWIFT)
        subprocess.run(["swiftc", str(path / "Reference.swift"), "-o", str(path / "reference")], check=True)
        for zone, year, month, day in scenarios:
            now = datetime(year, month, day, 12, tzinfo=ZoneInfo(zone))
            dates = [now + timedelta(days=offset, hours=hour) for offset in range(-8, 3) for hour in (-10, 0, 10)]
            fixture = json.dumps({"now_ms": int(now.timestamp() * 1000), "timestamps_ms": [int(date.timestamp() * 1000) for date in dates]}).encode()
            swift = json.loads(subprocess.check_output([str(path / "reference"), zone], input=fixture))
            env = os.environ.copy()
            env["TZ"] = zone
            rust = json.loads(subprocess.check_output([str(binary)], input=fixture, env=env))
            if swift != rust:
                for date, expected, actual in zip(dates, swift, rust):
                    if expected != actual:
                        raise AssertionError(f"{zone} {date}: Swift {expected}, Rust {actual}")
                raise AssertionError(f"{zone}: different result counts")
            cases.append({"zone": zone, "fixture": json.loads(fixture), "expected": swift})
            count += len(dates)
    reference = ROOT / "apps/linux/reference/sidebar-calendar.json"
    if "--write-fixture" in sys.argv:
        reference.write_text(json.dumps(cases, indent=2) + "\n")
    elif json.loads(reference.read_text()) != cases:
        raise AssertionError("Swift calendar fixture changed; review and regenerate the portable reference")
    print(f"PASS: {count} local calendar cases across DST and date-line transitions")


if __name__ == "__main__":
    main()
