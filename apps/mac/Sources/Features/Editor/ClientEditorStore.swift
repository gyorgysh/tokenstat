// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// File identity includes the host because local workspace IDs can repeat.
struct ClientEditorKey: Hashable {
    let peer: String
    let workspace: String
    let path: String
}

/// Posted after an iOS editor save lands on the host, so surfaces behind
/// the sheet (Changes, History, the file list) re-read without disturbing
/// selections, drafts or scroll positions.
struct ClientFileChangeNotice {
    let peer: String
    let workspace: String
    let path: String
}

extension Notification.Name {
    static let clientFileDidChange = Notification.Name("tokenstat.clientFileDidChange")
}

@Observable
@MainActor
final class ClientEditorTab: Identifiable {
    let id: ClientEditorKey
    let document: EditorDocument
    var isSaving = false
    var errorMessage: String?
    /// Host content that arrived while the draft was dirty. Saving stays off
    /// until the person chooses a copy.
    var conflictHostContent: String?

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
    typealias Reader = @MainActor (String, String, String) async throws -> String
    private(set) var tabs: [ClientEditorTab] = []
    private var selections: [ClientEditorScope: ClientEditorKey] = [:]
    @ObservationIgnored private let write: Writer
    @ObservationIgnored private let read: Reader

    init(write: @escaping Writer, read: @escaping Reader) {
        self.write = write
        self.read = read
    }

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
        guard tabs.contains(where: { $0 === tab }), !tab.isSaving, tab.document.isDirty,
              tab.conflictHostContent == nil else { return }
        tab.isSaving = true
        tab.errorMessage = nil
        defer { tab.isSaving = false }
        // The host file may have moved since this buffer opened: another
        // window, the Mac, or a run writing output. Re-read before writing
        // so a stale draft cannot silently overwrite newer host content.
        let host: String
        do {
            host = try await read(tab.id.peer, tab.id.workspace, tab.id.path)
        } catch {
            tab.errorMessage = "Could not re-read this file on the host, so the save waits. Your edits are kept."
            return
        }
        let draft = tab.document.text
        if host != draft, host != tab.document.savedText {
            tab.conflictHostContent = host
            return
        }
        if host == draft {
            // Already there: a lost acknowledgement or a matching remote
            // edit. Mark it saved without writing the same bytes again.
            tab.document.markSaved(content: draft)
            return
        }
        let sent = draft
        do {
            try await write(tab.id.peer, tab.id.workspace, tab.id.path, sent)
            tab.document.markSaved(content: sent)
            NotificationCenter.default.post(
                name: .clientFileDidChange,
                object: ClientFileChangeNotice(peer: tab.id.peer, workspace: tab.id.workspace, path: tab.id.path)
            )
        } catch {
            tab.errorMessage = error.localizedDescription
        }
    }

    /// Choose a copy after a conflict. Reloading adopts the host and clears
    /// the draft; keeping writes the draft through explicitly.
    func resolveConflict(_ tab: ClientEditorTab, keepMine: Bool) async {
        guard tabs.contains(where: { $0 === tab }), !tab.isSaving,
              let host = tab.conflictHostContent else { return }
        if keepMine {
            tab.conflictHostContent = nil
            tab.errorMessage = nil
            let sent = tab.document.text
            tab.isSaving = true
            defer { tab.isSaving = false }
            do {
                try await write(tab.id.peer, tab.id.workspace, tab.id.path, sent)
                tab.document.markSaved(content: sent)
                NotificationCenter.default.post(
                    name: .clientFileDidChange,
                    object: ClientFileChangeNotice(peer: tab.id.peer, workspace: tab.id.workspace, path: tab.id.path)
                )
            } catch {
                tab.errorMessage = error.localizedDescription
            }
        } else {
            tab.document.adopt(saved: host)
            tab.conflictHostContent = nil
            tab.errorMessage = nil
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
