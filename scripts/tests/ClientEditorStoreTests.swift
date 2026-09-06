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

@main
struct ClientEditorStoreTests {
    @MainActor
    static func main() async {
        var finish: CheckedContinuation<Void, Error>?
        var submitted: String?
        let store = ClientEditorStore { _, _, _, content in
            submitted = content
            try await withCheckedThrowingContinuation { finish = $0 }
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
        print("ClientEditorStoreTests passed")
    }
}
