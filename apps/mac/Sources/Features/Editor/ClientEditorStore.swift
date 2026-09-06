// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// File identity includes the host because local workspace IDs can repeat.
struct ClientEditorKey: Hashable {
    let peer: String
    let workspace: String
    let path: String
}

@Observable
@MainActor
final class ClientEditorTab: Identifiable {
    let id: ClientEditorKey
    let document: EditorDocument
    var isSaving = false
    var errorMessage: String?

    init(id: ClientEditorKey, content: String) {
        self.id = id
        document = EditorDocument(workspaceID: id.workspace, path: id.path, content: content)
    }
}

/// Owned by the client root, so layout and workspace changes preserve buffers.
@Observable
@MainActor
final class ClientEditorStore {
    typealias Writer = @MainActor (String, String, String, String) async throws -> Void
    private(set) var tabs: [ClientEditorTab] = []
    private var selections: [ClientEditorScope: ClientEditorKey] = [:]
    @ObservationIgnored private let write: Writer

    init(write: @escaping Writer) { self.write = write }

    func tabs(peer: String, workspace: String) -> [ClientEditorTab] {
        tabs.filter { $0.id.peer == peer && $0.id.workspace == workspace }
    }

    func selected(peer: String, workspace: String) -> ClientEditorTab? {
        let key = selections[ClientEditorScope(peer: peer, workspace: workspace)]
        return tabs.first { $0.id == key }
    }

    func tab(for key: ClientEditorKey) -> ClientEditorTab? {
        tabs.first(where: { $0.id == key })
    }

    @discardableResult
    func selectExisting(_ key: ClientEditorKey) -> Bool {
        guard let tab = tab(for: key) else { return false }
        select(tab)
        return true
    }

    /// Replace a clean buffer with a fresh host read. Dirty and in-flight
    /// saves keep what the person is looking at.
    func adoptSaved(_ key: ClientEditorKey, content: String) {
        guard let tab = tab(for: key) else {
            open(key, content: content)
            return
        }
        if tab.isSaving || tab.document.isDirty {
            select(tab)
            return
        }
        tab.document.adopt(saved: content)
        select(tab)
    }

    func select(_ tab: ClientEditorTab) {
        selections[ClientEditorScope(peer: tab.id.peer, workspace: tab.id.workspace)] = tab.id
    }

    func showFiles(peer: String, workspace: String) {
        selections.removeValue(forKey: ClientEditorScope(peer: peer, workspace: workspace))
    }

    func open(_ key: ClientEditorKey, content: String) {
        guard !selectExisting(key) else { return }
        let tab = ClientEditorTab(id: key, content: content)
        tabs.append(tab)
        select(tab)
    }

    /// Dirty buffers need explicit discard. An in-flight save cannot be closed.
    @discardableResult
    func close(_ tab: ClientEditorTab, discard: Bool = false) -> Bool {
        guard !tab.isSaving, discard || !tab.document.isDirty else { return false }
        let wasSelected = selected(peer: tab.id.peer, workspace: tab.id.workspace)?.id == tab.id
        tabs.removeAll { $0.id == tab.id }
        if wasSelected {
            if let next = tabs(peer: tab.id.peer, workspace: tab.id.workspace).last {
                select(next)
            } else {
                showFiles(peer: tab.id.peer, workspace: tab.id.workspace)
            }
        }
        return true
    }

    func save(_ tab: ClientEditorTab) async {
        guard tabs.contains(where: { $0 === tab }), !tab.isSaving, tab.document.isDirty else { return }
        tab.isSaving = true
        tab.errorMessage = nil
        let sent = tab.document.text
        defer { tab.isSaving = false }
        do {
            try await write(tab.id.peer, tab.id.workspace, tab.id.path, sent)
            tab.document.markSaved(content: sent)
        } catch {
            tab.errorMessage = error.localizedDescription
        }
    }

    /// Signing out removes account-owned file contents from the session.
    func reset() {
        tabs = []
        selections = [:]
    }
}

private struct ClientEditorScope: Hashable {
    let peer: String
    let workspace: String
}
