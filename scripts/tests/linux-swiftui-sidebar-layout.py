#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare portable sidebar layout against the current Swift source in UTC.

The fixture collation covers a small set of Latin names; full locale-specific
sorting, calendar transitions, GPUI rendering and input remain separate gates.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", ROOT / "scripts/tests/linux-swiftui-contract.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def main():
    rust = json.loads(subprocess.check_output([
        "cargo", "run", "--quiet", "--manifest-path", str(ROOT / "apps/linux/Cargo.toml"),
        "--no-default-features", "--example", "sidebar-layout-contract", "--locked"
    ], cwd=ROOT))
    declarations = [contract.declaration("App/SidebarPreferences.swift", "enum SidebarProjectsSort:")]
    for marker in ["struct SidebarChatEntry:", "enum SidebarChatDay:", "struct SidebarChatDayGroup:", "enum SidebarProjectsLayout {"]:
        declarations.append(contract.declaration("App/SidebarProjectsLayout.swift", marker))
    source = '''import Foundation
struct WorkspaceFolder: Decodable, Hashable, Sendable {
    let id: String; let name: String; let machineLabel: String?; let chats: [ChatConversation]
}
struct ChatConversation: Decodable, Hashable, Sendable {
    let id: String; let title: String; let backend: String; let branch: String?
    let updatedAtMs: Int64; let lastMessageAtMs: Int64?; let running: Bool
}
struct Fixture: Decodable { let input: [WorkspaceFolder]; let now: Int64 }
''' + '\n'.join(declarations) + '''
let fixture = try JSONDecoder().decode(Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
var cases: [[String: Any]] = []
for query in ["", "  CAFE  ", "laptop", "feature", "claude", "missing"] {
    for sort in [SidebarProjectsSort.manual, .name, .recent] {
        let entries = SidebarProjectsLayout.chatEntries(folders: fixture.input, chats: { $0.chats }, query: query, sort: sort)
        let filtered = fixture.input.filter { SidebarProjectsLayout.matches(query, folder: $0, chats: $0.chats) }
        let folders = SidebarProjectsLayout.orderedFolders(filtered, sort: sort) { folder in
            folder.chats.map { $0.lastMessageAtMs ?? $0.updatedAtMs }.max() ?? 0
        }
        let groups = SidebarProjectsLayout.dayGroups(entries, now: Date(timeIntervalSince1970: Double(fixture.now)), calendar: calendar)
        cases.append(["query": query, "sort": sort.rawValue, "folders": folders.map(\\.id),
                      "entries": entries.map { $0.conversation.id },
                      "filtered": fixture.input.map { SidebarProjectsLayout.filteredChats($0.chats, query: query).map(\\.id) },
                      "groups": groups.map { ["day": $0.day.id, "entries": $0.entries.map { $0.conversation.id }] }])
    }
}
let output = try JSONSerialization.data(withJSONObject: cases, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
'''
    (ROOT / "target").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "target") as tmp:
        path = Path(tmp)
        (path / "Reference.swift").write_text(source)
        subprocess.run(["swiftc", str(path / "Reference.swift"), "-o", str(path / "reference")], check=True)
        result = subprocess.run([str(path / "reference")], input=json.dumps(rust).encode(), stdout=subprocess.PIPE, check=True)
    swift = json.loads(result.stdout)
    if swift != rust["cases"]:
        for index, (expected, actual) in enumerate(zip(swift, rust["cases"])):
            if expected != actual:
                raise AssertionError(f"case {index}: Swift {expected!r} != Rust {actual!r}")
        raise AssertionError("Different case counts")
    print(f"PASS: {len(swift)} original sidebar filter, ordering and UTC day-group cases")


if __name__ == "__main__":
    main()
