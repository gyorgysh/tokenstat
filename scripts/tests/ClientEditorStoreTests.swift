// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with EditorDocument.swift and ClientEditorStore.swift. Host highlighting
// is stubbed so these tests exercise document ownership and asynchronous saves.
import Foundation

struct SyntaxSpan {}
struct SyntaxRules { static let fallback = SyntaxRules() }
struct FileDiff { var hunks: [DiffHunk] }
struct DiffHunk { var lines: [DiffLine] }
struct DiffLine { enum Kind { case added }; var kind: Kind; var newLine: Int? }
struct Highlighting { var spans: [SyntaxSpan] = []; var rules = SyntaxRules(); var note: String? }
enum Bridge {
    static func highlight(path: String, text: String) async throws -> Highlighting { Highlighting() }
}

private final class EditorSaveNoticeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

@main
struct ClientEditorStoreTests {
    @MainActor
    static func main() async {
        var finish: CheckedContinuation<Void, Error>?
        var submitted: String?
        var hostContent = "original"
        let store = ClientEditorStore {
            _, _, _, content in
            submitted = content
            // The fake host holds what was written, like the real one.
            hostContent = content
            try await withCheckedThrowingContinuation { finish = $0 }
        } read: { _, _, _ in
            hostContent
        }
        let a = ClientEditorKey(peer: "host-a", workspace: "workspace", path: "src/main.swift")
        let b = ClientEditorKey(peer: "host-b", workspace: "workspace", path: "src/main.swift")
        store.open(a, content: "original")
        let tab = store.selected(peer: a.peer, workspace: a.workspace)!
        tab.document.setText("edited")
        tab.document.selection = NSRange(location: 3, length: 2)
        store.showFiles(peer: a.peer, workspace: a.workspace)
        store.open(a, content: "stale read")
        precondition(store.tabs.count == 1, "Reopen reuses tab")
        precondition(tab.document.text == "edited", "Reopen cannot replace dirty content")
        precondition(tab.document.selection == NSRange(location: 3, length: 2), "Selection survives")
        store.open(b, content: "other host")
        precondition(store.tabs.count == 2, "Identical paths on different hosts are isolated")
        precondition(store.selected(peer: a.peer, workspace: a.workspace) === tab, "Per-workspace selection")
        precondition(!store.close(tab), "Dirty close needs discard")

        let save = Task { await store.save(tab) }
        while finish == nil { await Task.yield() }
        precondition(submitted == "edited", "Sends the captured version")
        precondition(!store.close(tab, discard: true), "Cannot discard an in-flight save")
        tab.document.setText("typed during save")
        finish?.resume()
        finish = nil
        await save.value
        precondition(tab.document.savedText == "edited", "Acknowledges only the sent version")
        precondition(tab.document.text == "typed during save" && tab.document.isDirty, "New edits remain dirty")

        let failure = Task { await store.save(tab) }
        while finish == nil { await Task.yield() }
        finish?.resume(throwing: NSError(domain: "offline", code: 1))
        finish = nil
        await failure.value
        precondition(tab.document.isDirty && tab.errorMessage != nil, "Save failure preserves edits")
        precondition(store.close(tab, discard: true), "Explicit discard closes")
        precondition(store.tabs.count == 1, "Other host is retained")
        store.reset()
        precondition(store.tabs.isEmpty, "Sign-out clears session contents")

        let clean = ClientEditorKey(peer: "host-a", workspace: "workspace", path: "README.md")
        store.open(clean, content: "first")
        store.adoptSaved(clean, content: "from host")
        precondition(store.tab(for: clean)?.document.text == "from host", "Clean tabs re-read")
        store.tab(for: clean)?.document.setText("typed")
        store.adoptSaved(clean, content: "stale host")
        precondition(store.tab(for: clean)?.document.text == "typed", "Dirty tabs keep the buffer")
        store.reset()

        var writes = 0
        var host = "opened"
        let checked = ClientEditorStore { _, _, _, _ in
            writes += 1
        } read: { _, _, _ in
            host
        }
        let key = ClientEditorKey(peer: "host-a", workspace: "workspace", path: "notes.txt")
        checked.open(key, content: "opened")
        let draft = checked.tab(for: key)!
        draft.document.setText("my edits")
        await checked.save(draft)
        precondition(writes == 1 && !draft.document.isDirty, "Unchanged host saves straight through")
        precondition(draft.document.savedAt != nil, "Save stamps an outcome")
        draft.document.setText("more edits")
        precondition(draft.document.savedAt == nil, "New edits clear the stamp")

        host = "more edits"
        await checked.save(draft)
        precondition(writes == 1 && !draft.document.isDirty, "Converged host just marks saved")
        draft.document.setText("diverged again")

        host = "someone else"
        await checked.save(draft)
        precondition(writes == 1, "Moved host blocks the write")
        precondition(draft.conflictHostContent == "someone else", "Conflict keeps the host copy")
        precondition(draft.document.text == "diverged again", "Conflict keeps the draft")
        await checked.save(draft)
        precondition(writes == 1, "Conflicted save stays off")
        await checked.resolveConflict(draft, keepMine: false)
        precondition(draft.document.text == "someone else" && !draft.document.isDirty, "Reload adopts the host")
        precondition(draft.conflictHostContent == nil, "Reload clears the conflict")

        draft.document.setText("mine once more")
        host = "host again"
        await checked.save(draft)
        precondition(draft.conflictHostContent != nil, "Conflict again")
        await checked.resolveConflict(draft, keepMine: true)
        precondition(writes == 2 && !draft.document.isDirty, "Keeping writes the draft through")

        precondition(EditorDocument.firstDifference(between: "a\nb\nc", and: "a\nB\nc") == 2, "First difference names the line")
        precondition(EditorDocument.firstDifference(between: "same", and: "same") == nil, "Matching files have none")
        precondition(EditorDocument.firstDifference(between: "a", and: "a\nb") == 2, "Appended lines count")

        var blindWrites = 0
        let blind = ClientEditorStore { _, _, _, _ in
            blindWrites += 1
        } read: { _, _, _ in
            throw NSError(domain: "offline", code: 1)
        }
        blind.open(key, content: "opened")
        let offline = blind.tab(for: key)!
        offline.document.setText("offline edits")
        await blind.save(offline)
        precondition(blindWrites == 0 && offline.document.isDirty, "Unreadable host waits, edits kept")
        precondition(offline.errorMessage != nil, "Refusal says why")

        // A read can ignore task cancellation and answer after the account's
        // buffers have been removed. It must never start a subsequent write.
        for retirement in ["reset", "account", "cancel"] {
            var readGate: CheckedContinuation<String, Error>?
            var retiredWrites = 0
            var session = "account-a"
            let retired = ClientEditorStore(write: { _, _, _, _ in
                retiredWrites += 1
            }, read: { _, _, _ in
                try await withCheckedThrowingContinuation { readGate = $0 }
            }, sessionID: { AnyHashable(session) })
            retired.open(key, content: "opened")
            let retiredTab = retired.tab(for: key)!
            retiredTab.document.setText("private draft")
            let operation = Task { await retired.save(retiredTab) }
            while readGate == nil { await Task.yield() }
            switch retirement {
            case "reset": retired.reset()
            case "account": session = "account-b"
            default: operation.cancel()
            }
            readGate?.resume(returning: "opened")
            await operation.value
            precondition(retiredWrites == 0, "Retired \(retirement) read cannot write the draft")
            precondition(retiredTab.document.isDirty && !retiredTab.isSaving,
                         "Retired save cannot acknowledge the draft or keep the save slot")
            precondition(retiredTab.errorMessage == nil && retiredTab.conflictHostContent == nil,
                         "Retired read cannot publish stale state")
        }

        var session = "account-a"
        var staleReads = 0
        let stale = ClientEditorStore(write: { _, _, _, _ in
            preconditionFailure("An old account's tab must not write")
        }, read: { _, _, _ in
            staleReads += 1
            return "opened"
        }, sessionID: { AnyHashable(session) })
        stale.open(key, content: "opened")
        let staleTab = stale.tab(for: key)!
        staleTab.document.setText("old account draft")
        session = "account-b"
        await stale.save(staleTab)
        precondition(staleReads == 0, "A stale action is refused before the root's reset callback")
        precondition(stale.tabs(peer: key.peer, workspace: key.workspace).isEmpty,
                     "A new account cannot display the previous account's buffers before reset")
        stale.adoptSaved(key, content: "new account file")
        let newSessionTab = stale.tab(for: key)!
        precondition(newSessionTab !== staleTab && newSessionTab.document.text == "new account file",
                     "A same-path new-account read cannot adopt or expose the old dirty buffer")
        stale.select(staleTab)
        precondition(stale.selected(peer: key.peer, workspace: key.workspace) === newSessionTab,
                     "An old view cannot select another account's buffer")
        precondition(!stale.close(staleTab, discard: true) && stale.tab(for: key) === newSessionTab,
                     "An old view cannot close a same-path buffer belonging to the new account")

        // A write already sent cannot be recalled, but its delayed answer must
        // not mark a retired buffer saved or refresh a new account's surfaces.
        for keepingConflict in [false, true] {
            var writeGate: CheckedContinuation<Void, Error>?
            let notices = EditorSaveNoticeCounter()
            let observer = NotificationCenter.default.addObserver(forName: .clientFileDidChange,
                                                                  object: nil, queue: nil) { _ in notices.record() }
            let retired = ClientEditorStore(write: { _, _, _, _ in
                try await withCheckedThrowingContinuation { writeGate = $0 }
            }, read: { _, _, _ in "opened" })
            retired.open(key, content: "opened")
            let retiredTab = retired.tab(for: key)!
            retiredTab.document.setText("private draft")
            if keepingConflict { retiredTab.conflictHostContent = "host changes" }
            let operation = Task {
                if keepingConflict { await retired.resolveConflict(retiredTab, keepMine: true) }
                else { await retired.save(retiredTab) }
            }
            while writeGate == nil { await Task.yield() }
            retired.reset()
            writeGate?.resume()
            await operation.value
            NotificationCenter.default.removeObserver(observer)
            precondition(retiredTab.document.isDirty && retiredTab.document.savedAt == nil,
                         "Retired write answer cannot acknowledge an old buffer")
            precondition(notices.count == 0, "Retired write answer cannot refresh another session")
        }
        print("ClientEditorStoreTests passed")
    }
}
