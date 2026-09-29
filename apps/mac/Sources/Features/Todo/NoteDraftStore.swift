// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// Retains unsaved notes across navigation and drains edits in order per note.
@MainActor @Observable
final class NoteDraftStore {
    struct Text: Equatable, Hashable {
        var title: String
        var body: String
    }
    struct Entry {
        var value: Text
        var saved: Text
        var saving = false
        var hasSaved = false
        var error: String?
        var dirty: Bool { value != saved }
    }
    private(set) var entries: [String: Entry] = [:]

    func open(_ id: String, saved: Text) -> Text {
        if let entry = entries[id], entry.dirty || entry.saving || entry.error != nil { return entry.value }
        entries[id] = Entry(value: saved, saved: saved)
        return saved
    }

    func edit(_ id: String, value: Text, saved: Text) {
        var entry = entries[id] ?? Entry(value: saved, saved: saved)
        guard entry.value != value else { return }
        entry.value = value
        entry.error = nil
        entries[id] = entry
    }

    func discard(_ id: String) -> Text? {
        guard var entry = entries[id], !entry.saving else { return nil }
        entry.value = entry.saved
        entry.error = nil
        entries[id] = entry
        return entry.saved
    }

    func save(_ id: String, write: (Text) async throws -> Void) async {
        guard entries[id]?.saving != true else { return }
        while let entry = entries[id], entry.dirty {
            var snapshot = entry.value
            snapshot.title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if snapshot.title.isEmpty { snapshot.title = entry.saved.title }
            entries[id]?.saving = true
            entries[id]?.error = nil
            do {
                try await write(snapshot)
                // Normalize only the submitted version; typing during the
                // request belongs to the next write and must stay untouched.
                if entries[id]?.value == entry.value { entries[id]?.value = snapshot }
                entries[id]?.saved = snapshot
                entries[id]?.hasSaved = true
                entries[id]?.saving = false
            } catch {
                entries[id]?.saving = false
                entries[id]?.error = error.localizedDescription
                return
            }
        }
    }
}
