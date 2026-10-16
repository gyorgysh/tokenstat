#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Run the production recovery getter with observed transcript/selection changes."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 and sys.argv[1] == '--benchmark' else Path(__file__).resolve().parents[2]
benchmark = '--benchmark' in sys.argv
chat = root / 'apps/mac/Sources/Features/Workspaces/Chat'
source = (chat / 'ChatModel.swift').read_text()
recovery = source[source.index('    private var signInRecovery:'):source.index('    var signInQueuedMessage:')]
outgoing = source[source.index('    private(set) var outgoing:'):source.index('    var approvals:')]
queued_getter = source[source.index('    var signInQueuedMessage:'):source.index('    var signInGateRowID:')]
key = source[source.index('    private struct DisplayKey:'):source.index('    private var displayCache:')]
auth = (chat / 'ChatAuthenticationFailure.swift').read_text().replace(
    'enum ChatAuthenticationFailure {', 'enum ChatAuthenticationFailure {\n    static var computations = 0')
signature = '    static func latestRecovery(in items: [ChatDisplayItem], backend: String) -> Recovery? {'
assert auth.count(signature) == 1
auth = auth.replace(signature, signature + '\n        computations += 1')
fixture = r'''
import Foundation
import Observation
struct ChatAttachment: Hashable { var id: String }
struct ChatApproval: Hashable { var id: String; var decision: String? }
struct Conversation { var id: String; var backend: String }
struct ChatQueuedMessage {
    enum Delivery { case waiting, sending }
    var id: String
    var signInBackend: String?
    var delivery: Delivery
}
final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func note() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
@Observable @MainActor final class Model {
    var selected: Conversation? = Conversation(id: "one", backend: "claude")
    var displayRevision: UInt64 = 0
    private var displayCache: [ChatDisplayItem] = []
    @ObservationIgnored private var displayKey: DisplayKey?
    var savedCopy: String?
    var queued: [ChatQueuedMessage] = []
    var owns = true
    @ObservationIgnored var ownershipReads = 0
    private var ownsQueue: Bool { ownershipReads += 1; return owns }
OUTGOING
KEY
RECOVERY
QUEUED
    var displayItems: [ChatDisplayItem] { displayCache + outgoing }
    func read() -> ChatAuthenticationFailure.Recovery? { signInRecovery }
    func setRows(_ rows: [ChatDisplayItem], epoch: UInt64) {
        displayCache = rows
        displayKey = DisplayKey(epoch: epoch, count: rows.count, firstSeq: nil,
                                lastSeq: nil, backend: selected?.backend, running: false)
        displayRevision &+= 1
    }
    func clearRows() { displayCache = []; displayKey = nil }
    func stage(_ rows: [ChatDisplayItem]) { outgoing = rows }
}
@main struct Test {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--benchmark") {
            let model = Model()
            var rows: [ChatDisplayItem] = []
            for turn in 0..<40 {
                rows.append(ChatDisplayItem(id: "p\(turn)", kind: .user("prompt")))
                for step in 0..<29 {
                    rows.append(ChatDisplayItem(id: "r\(turn)-\(step)", kind: .assistant("A completed agent step.", backend: "claude")))
                }
            }
            rows.append(ChatDisplayItem(id: "fail", kind: .failed("Claude Code is not signed in on this computer.")))
            model.setRows(rows, epoch: 1)
            var times: [Double] = []
            var checksum = 0
            for _ in 0..<21 {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<100 { checksum += model.read()?.failureID.count ?? 0 }
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            times.sort()
            let report: [String: Any] = ["rows": rows.count, "reads_per_sample": 100,
                "samples": times.count, "median_ms": times[times.count / 2],
                "p95_ms": times[Int(Double(times.count - 1) * 0.95)], "checksum": checksum]
            print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            return
        }
        let model = Model()
        for _ in 0..<1000 { assert(model.signInQueuedMessage == nil) }
        assert(model.ownershipReads == 0, "empty queues need no ownership lookup")
        model.queued = [.init(id: "other", signInBackend: "codex", delivery: .waiting)]
        assert(model.signInQueuedMessage == nil && model.ownershipReads == 0)
        model.queued.append(.init(id: "in-flight", signInBackend: "claude", delivery: .sending))
        assert(model.signInQueuedMessage == nil && model.ownershipReads == 0)
        model.queued.append(.init(id: "sign-in", signInBackend: "claude", delivery: .waiting))
        assert(model.signInQueuedMessage?.id == "sign-in" && model.ownershipReads == 1)
        model.owns = false
        assert(model.signInQueuedMessage == nil, "matching sends still require ownership")
        model.owns = true
        let queueChanges = Changes()
        withObservationTracking { _ = model.signInQueuedMessage } onChange: { queueChanges.note() }
        model.owns = false
        assert(queueChanges.value == 1, "matching sends observe ownership changes")
        model.queued = []
        queueChanges.reset()
        withObservationTracking { _ = model.signInQueuedMessage } onChange: { queueChanges.note() }
        model.queued.append(.init(id: "new", signInBackend: "claude", delivery: .waiting))
        assert(queueChanges.value == 1, "empty queues observe new messages")
        model.queued = []
        model.owns = true
        let prompt = ChatDisplayItem(id: "prompt", kind: .user("hello"))
        let failed = ChatDisplayItem(id: "failed", kind: .failed("Claude Code is not signed in on this computer."))
        model.setRows([prompt, failed], epoch: 1)
        assert(model.read()?.failureID == "failed")
        let built = ChatAuthenticationFailure.computations
        assert(built == 1, "the counter observes the production recovery function")
        for _ in 0..<1000 { assert(model.read()?.failureID == "failed") }
        assert(ChatAuthenticationFailure.computations == built, "unchanged rows reuse recovery")
        model.stage([ChatDisplayItem(id: "next", kind: .user("new prompt"))])
        assert(model.read() == nil, "optimistic prompt retires old recovery")
        let missing = ChatAuthenticationFailure.computations
        for _ in 0..<1000 { assert(model.read() == nil) }
        assert(ChatAuthenticationFailure.computations == missing, "nil is cached too")
        model.stage([])
        assert(model.read()?.failureID == "failed")
        model.selected?.backend = "codex"
        assert(model.read() == nil, "handoff cannot reuse another backend's failure")
        model.selected?.backend = "claude"
        model.setRows([prompt, failed], epoch: 2)
        assert(model.read()?.failureID == "failed")
        let changes = Changes()
        withObservationTracking { _ = model.read() } onChange: { changes.note() }
        model.stage([ChatDisplayItem(id: "third", kind: .user("third prompt"))])
        assert(changes.value == 1, "cache hits still observe optimistic prompts")
        assert(model.read() == nil)
        model.stage([])
        assert(model.read()?.failureID == "failed")
        changes.reset()
        withObservationTracking { _ = model.read() } onChange: { changes.note() }
        model.clearRows()
        assert(changes.value == 1 && model.read() == nil, "clearing the window invalidates a cached recovery")
        model.selected = nil
        assert(model.read() == nil)
        model.selected = Conversation(id: "other", backend: "claude")
        model.setRows([prompt, failed], epoch: 2)
        assert(model.read()?.failureID == "failed")
        print("Production recovery cache and observation invalidation passed")
    }
}
'''.replace('OUTGOING', outgoing).replace('KEY', key).replace('RECOVERY', recovery).replace('QUEUED', queued_getter)
with tempfile.TemporaryDirectory(prefix='tokenstat-recovery-cache-') as directory:
    path = Path(directory)
    (path / 'Fixture.swift').write_text(fixture)
    (path / 'Authentication.swift').write_text(auth)
    subprocess.run(['swiftc', '-O' if benchmark else '-Onone', '-parse-as-library', '-swift-version', '5',
                    str(path / 'Fixture.swift'), str(path / 'Authentication.swift'),
                    str(chat / 'ChatDisplayItem.swift'), str(chat / 'ChatTranscriptFold.swift'),
                    str(chat / 'ChatQuestion.swift'), str(root / 'apps/mac/Sources/Design/L10n.swift'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')] + (['--benchmark'] if benchmark else []), check=True)
