#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the actual ChatModel publication methods with controlled CPU replies."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
def method(signature):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')
publication = method('    private func publishEvents(')
commit = method('    private func commitDisplay(')
def failure(signature, name, returns):
    original = method(signature)
    body = original.rsplit('} catch {', 1)[1]
    body = body[:body.rindex('\n        }')]
    return f'    func {name}(error: Error, id: String, generation: UInt64, requestedEpoch: UInt64, quiet: Bool = false) async{returns} {{' + body + '\n    }'
failures = '\n'.join([
    failure('    private func openEvents(', 'failedOpen', ' -> Bool'),
    failure('    private func loadEarlier(', 'failedEarlier', ''),
    failure('    private func loadEvents(', 'failedTail', ' -> Bool')
])
swift = r'''import Foundation
struct ChatTimelineEvent { let seq: UInt64?; let text: String }
struct ChatDisplayItem: Equatable { let text: String }
struct Conversation { let id: String; var backend: String? = "agent"; var running = true }
@MainActor final class Worker {
    var inputs: [[ChatTimelineEvent]] = []
    var held: [CheckedContinuation<[ChatDisplayItem], Error>?] = []
    func project(_ events: [ChatTimelineEvent], backend: String?, running: Bool) async throws -> [ChatDisplayItem] {
        inputs.append(events)
        return try await withCheckedThrowingContinuation { held.append($0) }
    }
    func finish(_ index: Int) {
        let reply = inputs[index].map { ChatDisplayItem(text: $0.text) }
        let continuation = held[index]; held[index] = nil
        continuation?.resume(returning: reply)
    }
}
@MainActor final class Model {
    struct DisplayKey: Equatable {
        var epoch: UInt64; var count: Int; var firstSeq: UInt64?; var lastSeq: UInt64?
        var backend: String?; var running: Bool
    }
    var events: [ChatTimelineEvent] = [] { didSet { eventsRevision &+= 1 } }
    var eventsRevision: UInt64 = 0, displayRevision: UInt64 = 0
    var displayKey: DisplayKey?, foldKey: Int?, hasRunningToolCacheKey: Int?
    var displayCache: [ChatDisplayItem] = []
    var selected: Conversation? = Conversation(id: "A")
    var generation: UInt64 = 1, ownerIsCurrent = true
    var eventsEpoch: UInt64 = 2, pagingUnavailable = false, error: String?, fallbackCalls = 0
    func isUnknownMethod(_ error: Error) -> Bool { true }
    func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool) async -> Bool { fallbackCalls += 1; return true }
    let transcriptProjector = Worker()
    func selectionMatches(id: String, generation: UInt64) -> Bool {
        ownerIsCurrent && self.generation == generation && selected?.id == id
    }
''' + publication + '\n' + commit + '\n' + failures + r'''
}
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    precondition(condition())
}
func event(_ text: String, _ seq: UInt64) -> ChatTimelineEvent { .init(seq: seq, text: text) }
@main struct Check {
    @MainActor static func main() async {
        // Captured replacement loses to a newer accepted tail.
        let m = Model(); m.events = [event("base", 1)]
        let old = Task { await m.publishEvents(id: "A", generation: 1, rebasesWindow: false) { _ in [event("old", 1)] } }
        await until { m.transcriptProjector.inputs.count == 1 }
        m.events.append(event("new", 2)); m.commitDisplay(m.events.map { .init(text: $0.text) })
        m.transcriptProjector.finish(0)
        let replaced = await old.value
        precondition(!replaced && m.events.map(\.text) == ["base", "new"])
        // Prepend rebases over a tail in the same archive, retaining both.
        let prepend = Task { await m.publishEvents(id: "A", generation: 1) { [event("earlier", 0)] + $0 } }
        await until { m.transcriptProjector.inputs.count == 2 }
        m.events.append(event("newer", 3)); m.transcriptProjector.finish(1)
        await until { m.transcriptProjector.inputs.count == 3 }; m.transcriptProjector.finish(2)
        let prepended = await prepend.value
        precondition(prepended && m.events.map(\.text) == ["earlier", "base", "new", "newer"])
        // Exact cursor/window fence rejects an older archive even on same chat.
        var epoch = 1
        let stale = Task { await m.publishEvents(id: "A", generation: 1, canPublish: { epoch == 1 }) { [event("wrong archive", 0)] + $0 } }
        await until { m.transcriptProjector.inputs.count == 4 }; epoch = 2
        m.transcriptProjector.finish(3)
        let adopted = await stale.value; precondition(!adopted)
        let displacedTail = Task { await m.publishEvents(id: "A", generation: 1, canPublish: { epoch == 2 }) { $0 + [event("old tail", 4)] } }
        await until { m.transcriptProjector.inputs.count == 5 }
        epoch = 3 // Replacement intent retires the old archive before CPU completion.
        m.transcriptProjector.finish(4)
        let tailAccepted = await displacedTail.value; precondition(!tailAccepted)
        let revision = m.eventsRevision
        let metadata = Task { await m.publishEvents(id: "A", generation: 1, recordsChanged: false) { $0 } }
        await until { m.transcriptProjector.inputs.count == 6 }; m.selected?.running = false
        m.transcriptProjector.finish(5)
        await until { m.transcriptProjector.inputs.count == 7 }; m.transcriptProjector.finish(6)
        let updated = await metadata.value
        precondition(updated && m.eventsRevision == revision && m.displayKey?.running == false)
        // A previous selection/account and a canceled producer cannot publish.
        for reason in 0..<3 {
            let next = m.transcriptProjector.inputs.count
            let job = Task { await m.publishEvents(id: "A", generation: 1) { _ in [event("forbidden", 90)] } }
            await until { m.transcriptProjector.inputs.count == next + 1 }
            if reason == 0 { m.generation = 2 }
            if reason == 1 { m.ownerIsCurrent = false }
            if reason == 2 { job.cancel() }
            m.transcriptProjector.finish(next)
            let accepted = await job.value; precondition(!accepted)
            m.generation = 1; m.ownerIsCurrent = true
        }
        precondition(!m.events.contains { $0.text == "forbidden" })
        enum Failure: Error { case olderPage }
        let fallback = await m.failedOpen(error: Failure.olderPage, id: "A", generation: 1, requestedEpoch: 1)
        precondition(!fallback && m.fallbackCalls == 0 && !m.pagingUnavailable)
        await m.failedEarlier(error: Failure.olderPage, id: "A", generation: 1, requestedEpoch: 1)
        _ = await m.failedTail(error: Failure.olderPage, id: "A", generation: 1, requestedEpoch: 1)
        precondition(!m.pagingUnavailable && m.error == nil)
        let current = await m.failedOpen(error: Failure.olderPage, id: "A", generation: 1, requestedEpoch: 2)
        precondition(current && m.fallbackCalls == 1 && m.pagingUnavailable)
        print("Actual ChatModel publication: replacement/prepend/cursor/metadata/selection/account/cancel fences")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(work / 'ModuleCache'), str(work / 'Check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
# The actual application routes each nonempty mutation through publication.
assert 'ChatDisplayItem.coalesce(events' not in source
assert 'events.append(contentsOf:' not in source and 'events.insert(contentsOf:' not in source
assert 'private var displayCache:' in source and '@ObservationIgnored private var displayCache:' not in source
assert 'requestedEpoch == self.eventsEpoch && cursor == self.earlierCursor' in source
assert 'requestedEpoch == self.eventsEpoch && requestedOffset == self.offset && requestedCursor == self.tailCursor' in source
assert 'await applySavedCopy' in source
print('Projection integration source guards passed')
