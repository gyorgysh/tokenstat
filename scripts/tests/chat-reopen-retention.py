#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production reopen method with a held and failed newest-page read."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatModel.swift').read_text()
start = source.index('    func reopenAtLatest() async {')
end = source.index('\n    /// One creation at a time:', start)
method = source[start:end]
fixture = r'''
import Foundation
struct Conversation { var id: String }
@MainActor final class Reader {
    var sending = false, sendingNow = false
    var selected: Conversation? = .init(id: "chat")
    var selectionGeneration = 0
    var openingConversation = false
    var events = ["old page"], outgoing = ["pending"], outgoingWatermark = ["pending": 1]
    var contextRevision = 7, offset = 10, tailCursor = "cursor", liveWindowLoaded = true
    var wait: CheckedContinuation<Bool, Never>?
    func advanceSelection(_ reason: String) { selectionGeneration += 1 }
    func discardSteerReservations() {}
    func forgetWindow() { offset = 0; tailCursor = ""; liveWindowLoaded = false; contextRevision = 0 }
    @discardableResult func openEvents(id: String, generation: Int, quiet: Bool = false) async -> Bool {
        let accepted = await withCheckedContinuation { wait = $0 }
        if accepted && generation == selectionGeneration { events = ["new page"]; offset = 3; tailCursor = "new" }
        return accepted
    }
METHOD
}
@main struct Test {
    @MainActor static func main() async {
        let reader = Reader()
        let first = Task { await reader.reopenAtLatest() }
        while reader.wait == nil { await Task.yield() }
        precondition(reader.openingConversation && reader.events == ["old page"])
        precondition(reader.outgoing == ["pending"] && reader.outgoingWatermark["pending"] == 1)
        precondition(reader.offset == 10 && reader.tailCursor == "cursor" && reader.liveWindowLoaded && reader.contextRevision == 7)
        reader.wait?.resume(returning: false); reader.wait = nil
        await first.value
        precondition(!reader.openingConversation && reader.events == ["old page"] && reader.tailCursor == "cursor")
        let cancelled = Task { await reader.reopenAtLatest() }
        while reader.wait == nil { await Task.yield() }
        cancelled.cancel()
        reader.wait?.resume(returning: false); reader.wait = nil
        await cancelled.value
        precondition(!reader.openingConversation && reader.events == ["old page"] && reader.tailCursor == "cursor")
        let second = Task { await reader.reopenAtLatest() }
        while reader.wait == nil { await Task.yield() }
        reader.wait?.resume(returning: true); reader.wait = nil
        await second.value
        precondition(!reader.openingConversation && reader.events == ["new page"] && reader.tailCursor == "new")
        reader.sending = true
        await reader.reopenAtLatest()
        precondition(reader.wait == nil && reader.events == ["new page"])
        print("Reopen preserves the displayed page and cursors through a failed read and replaces them only on success")
    }
}
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='tokenstat-reopen-') as directory:
    path = Path(directory)
    (path / 'Test.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
