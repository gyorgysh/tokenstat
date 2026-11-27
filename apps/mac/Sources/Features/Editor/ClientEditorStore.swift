// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

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
    fileprivate let ownerSession: AnyHashable?
    var isSaving = false
    var errorMessage: String?
    var conflictHostContent: String?

    init(id: ClientEditorKey, content: String, ownerSession: AnyHashable? = nil) {
        self.id = id
        self.ownerSession = ownerSession
        document = EditorDocument(workspaceID: id.workspace, path: id.path, content: content)
    }
}

@Observable
@MainActor
final class ClientEditorStore {
    typealias Writer = @MainActor (String, String, String, String) async throws -> Void
    typealias Reader = @MainActor (String, String, String) async throws -> String
    private(set) var tabs: [ClientEditorTab] = []
    private var selections: [ClientEditorScope: ClientEditorKey] = [:]
    @ObservationIgnored private let write: Writer
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private let sessionID: @MainActor () -> AnyHashable?

    init(write: @escaping Writer, read: @escaping Reader,
         sessionID: @escaping @MainActor () -> AnyHashable? = { nil }) {
        self.write = write
        self.read = read
        self.sessionID = sessionID
    }

    func tabs(peer: String, workspace: String) -> [ClientEditorTab] {
        let owner = sessionID()
        return tabs.filter { $0.ownerSession == owner && $0.id.peer == peer && $0.id.workspace == workspace }
    }

    func selected(peer: String, workspace: String) -> ClientEditorTab? {
        let key = selections[ClientEditorScope(peer: peer, workspace: workspace)]
        return tabs.first { $0.ownerSession == sessionID() && $0.id == key }
    }

    func tab(for key: ClientEditorKey) -> ClientEditorTab? {
        tabs.first(where: { $0.ownerSession == sessionID() && $0.id == key })
    }

    @discardableResult
    func selectExisting(_ key: ClientEditorKey) -> Bool {
        guard let tab = tab(for: key) else { return false }
        select(tab)
        return true
    }

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
        guard tab.ownerSession == sessionID(), tabs.contains(where: { $0 === tab }) else { return }
        selections[ClientEditorScope(peer: tab.id.peer, workspace: tab.id.workspace)] = tab.id
    }

    func showFiles(peer: String, workspace: String) {
        selections.removeValue(forKey: ClientEditorScope(peer: peer, workspace: workspace))
    }

    func open(_ key: ClientEditorKey, content: String) {
        guard !selectExisting(key) else { return }
        let tab = ClientEditorTab(id: key, content: content, ownerSession: sessionID())
        tabs.append(tab)
        select(tab)
    }

    @discardableResult
    func close(_ tab: ClientEditorTab, discard: Bool = false) -> Bool {
        guard tab.ownerSession == sessionID(), tabs.contains(where: { $0 === tab }),
              !tab.isSaving, discard || !tab.document.isDirty else { return false }
        let wasSelected = selected(peer: tab.id.peer, workspace: tab.id.workspace)?.id == tab.id
        tabs.removeAll { $0 === tab }
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
        let owner = sessionID()
        guard owns(tab, session: owner), !tab.isSaving, tab.document.isDirty,
              tab.conflictHostContent == nil else { return }
        tab.isSaving = true
        tab.errorMessage = nil
        defer { tab.isSaving = false }
        let host: String
        do {
            host = try await read(tab.id.peer, tab.id.workspace, tab.id.path)
        } catch {
            guard owns(tab, session: owner) else { return }
            tab.errorMessage = L10n.text("apple.clienteditorstore.could_not_re_read_this_file_on_that_comput.dacb7165")
            return
        }
        guard owns(tab, session: owner) else { return }
        let draft = tab.document.text
        if host != draft, host != tab.document.savedText {
            tab.conflictHostContent = host
            return
        }
        if host == draft {
            tab.document.markSaved(content: draft)
            return
        }
        let sent = draft
        do {
            try await write(tab.id.peer, tab.id.workspace, tab.id.path, sent)
            guard owns(tab, session: owner) else { return }
            tab.document.markSaved(content: sent)
            NotificationCenter.default.post(
                name: .clientFileDidChange,
                object: ClientFileChangeNotice(peer: tab.id.peer, workspace: tab.id.workspace, path: tab.id.path)
            )
        } catch {
            guard owns(tab, session: owner) else { return }
            tab.errorMessage = error.localizedDescription
        }
    }

    func resolveConflict(_ tab: ClientEditorTab, keepMine: Bool) async {
        let owner = sessionID()
        guard owns(tab, session: owner), !tab.isSaving,
              let host = tab.conflictHostContent else { return }
        if keepMine {
            tab.conflictHostContent = nil
            tab.errorMessage = nil
            let sent = tab.document.text
            tab.isSaving = true
            defer { tab.isSaving = false }
            do {
                try await write(tab.id.peer, tab.id.workspace, tab.id.path, sent)
                guard owns(tab, session: owner) else { return }
                tab.document.markSaved(content: sent)
                NotificationCenter.default.post(
                    name: .clientFileDidChange,
                    object: ClientFileChangeNotice(peer: tab.id.peer, workspace: tab.id.workspace, path: tab.id.path)
                )
            } catch {
                guard owns(tab, session: owner) else { return }
                tab.errorMessage = error.localizedDescription
            }
        } else {
            tab.document.adopt(saved: host)
            tab.conflictHostContent = nil
            tab.errorMessage = nil
        }
    }

    func reset() {
        tabs = []
        selections = [:]
    }

    private func owns(_ tab: ClientEditorTab, session owner: AnyHashable?) -> Bool {
        !Task.isCancelled && tab.ownerSession == owner && sessionID() == owner
            && tabs.contains(where: { $0 === tab })
    }
}

private struct ClientEditorScope: Hashable {
    let peer: String
    let workspace: String
}
