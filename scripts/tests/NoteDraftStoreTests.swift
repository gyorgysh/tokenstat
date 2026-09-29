// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with NoteDraftStore.swift.
import Foundation

enum DraftFailure: Error { case offline }
@MainActor final class DelayedWriter {
    var writes: [NoteDraftStore.Text] = []
    var continuation: CheckedContinuation<Void, Never>?
    func write(_ value: NoteDraftStore.Text) async {
        writes.append(value)
        if writes.count == 1 { await withCheckedContinuation { continuation = $0 } }
    }
}

@main struct NoteDraftStoreTests {
    @MainActor static func main() async {
        let store = NoteDraftStore()
        let original = NoteDraftStore.Text(title: "First", body: "Original")
        _ = store.open("a", saved: original)
        store.edit("a", value: .init(title: "First edit", body: "One"), saved: original)
        let writer = DelayedWriter()
        let saving = Task { await store.save("a") { await writer.write($0) } }
        while writer.continuation == nil { await Task.yield() }
        let newest = NoteDraftStore.Text(title: "Latest title", body: "Latest body")
        store.edit("a", value: newest, saved: original)
        await store.save("a") { _ in assertionFailure("Concurrent saves must coalesce") }
        var otherSaved = false
        _ = store.open("b", saved: original)
        store.edit("b", value: .init(title: "Other", body: "Independent"), saved: original)
        await store.save("b") { _ in otherSaved = true }
        assert(otherSaved, "One slow note must not block another note")
        assert(store.open("a", saved: original) == newest, "Switching back must restore the newer draft")
        writer.continuation?.resume()
        await saving.value
        assert(writer.writes.count == 2 && writer.writes.last == newest)
        assert(store.entries["a"]?.value == newest && store.entries["a"]?.dirty == false)

        store.edit("a", value: .init(title: "Unsaved", body: "Keep offline"), saved: newest)
        await store.save("a") { _ in throw DraftFailure.offline }
        assert(store.entries["a"]?.error != nil)
        assert(store.open("a", saved: newest).body == "Keep offline", "Failed drafts survive navigation")
        await store.save("a") { _ in }
        assert(store.entries["a"]?.dirty == false && store.entries["a"]?.error == nil)
        store.edit("a", value: .init(title: "  ", body: "Changed body"), saved: newest)
        await store.save("a") { text in
            assert(text.title == "Unsaved" && text.body == "Changed body")
        }
        assert(store.entries["a"]?.value.title == "Unsaved")
        print("Note draft race and recovery tests passed")
    }
}
