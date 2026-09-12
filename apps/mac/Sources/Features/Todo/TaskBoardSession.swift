// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

@MainActor @Observable
final class TaskBoardSession {
    let target: TaskEditorTarget
    let fixedFolder: String?
    var filter: TaskBoardFilter
    var editingTask: TodoCard?
    var composing = false
    var deletingTask: TodoCard?
    private(set) var cards: [TodoCard] = []
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var backends: [AgentBackend] = []
    private(set) var capabilities: TaskBoardCapabilities?
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var working = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private let service: any TaskBoardService
    private var generation: UInt64 = 0
    private var noticeGeneration: UInt64 = 0

    init(target: TaskEditorTarget, folder: String?, service: (any TaskBoardService)? = nil) {
        self.target = target
        fixedFolder = folder
        self.service = service ?? target
        filter = TaskBoardFilter(folder: folder.map(TaskBoardFolder.folder) ?? .all)
    }

    var visible: [TodoCard] { filter.cards(from: cards) }

    /// Multiple mounted boards can hear the same save. A newer explicit load
    /// already covers it; otherwise replace any read started before the save.
    func refreshAfterChange() {
        let observed = generation
        Task { [weak self] in
            await Task.yield()
            guard let self, self.generation == observed, !self.working else { return }
            await self.load(includeOptions: false)
        }
    }

    func canReorder(_ card: TodoCard, offset: Int) -> Bool {
        guard [-1, 1].contains(offset), !filter.newestFirst, !working, capabilities?.edit == true else { return false }
        let column = visible.filter { $0.column == card.column }
        guard let index = column.firstIndex(where: { $0.id == card.id }) else { return false }
        return column.indices.contains(index + offset)
    }

    func reorder(_ card: TodoCard, offset: Int) async {
        guard canReorder(card, offset: offset) else { return }
        let column = visible.filter { $0.column == card.column }
        guard let index = column.firstIndex(where: { $0.id == card.id }) else { return }
        if offset < 0 { await move(card, to: card.column, before: column[index - 1].id) }
        else if column.indices.contains(index + 2) { await move(card, to: card.column, before: column[index + 2].id) }
        else { await move(card, to: card.column, atEnd: true) }
    }

    func load(includeOptions: Bool = true) async {
        generation &+= 1
        let request = generation
        loading = true
        defer { if generation == request { loading = false } }
        do {
            let fresh = try await service.boardCards()
            guard request == generation, !Task.isCancelled else { return }
            cards = fresh
            loaded = true
            errorMessage = nil
            guard includeOptions else { return }
            async let availableFolders = service.boardFolders()
            async let availableBackends = service.boardBackends()
            async let availableCapabilities = service.boardCapabilities()
            let options = try await (availableFolders, availableBackends, availableCapabilities)
            guard request == generation, !Task.isCancelled else { return }
            (folders, backends, capabilities) = options
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func move(_ card: TodoCard, to column: String, before: String? = nil, atEnd: Bool = false) async {
        guard !working, capabilities?.edit == true, ["backlog", "doing", "done", "archive"].contains(column) else { return }
        working = true
        notice = nil
        generation &+= 1
        loading = false
        defer { working = false }
        let order: Int64?
        if let before {
            let destination = cards.filter { $0.column == column && $0.id != card.id }.sorted { $0.order < $1.order }
            guard let index = destination.firstIndex(where: { $0.id == before }) else { return }
            order = Int64(index)
        } else if atEnd {
            order = Int64(cards.filter { $0.column == column && $0.id != card.id }.count)
        } else { order = nil }
        do {
            _ = try await service.moveTask(card, column: column, order: order)
            if order != nil { filter.newestFirst = false }
            showNotice(column == "archive" ? "Task archived" : "Task moved")
            await load()
            NotificationCenter.default.post(name: TaskEditorSession.didChange, object: target)
        } catch { errorMessage = "The move was not confirmed. Reload the board before trying again. \(error.localizedDescription)" }
    }

    func delete(_ card: TodoCard) async {
        guard !working, capabilities?.delete == true else { return }
        working = true
        notice = nil
        generation &+= 1
        loading = false
        defer { working = false }
        do {
            try await service.deleteTask(card)
            generation &+= 1
            loading = false
            cards.removeAll { $0.id == card.id }
            deletingTask = nil
            showNotice("Task deleted")
            errorMessage = nil
            NotificationCenter.default.post(name: TaskEditorSession.didChange, object: target)
        } catch { errorMessage = "The deletion was not confirmed. Reload the board to check the task. \(error.localizedDescription)" }
    }

    private func showNotice(_ text: String) {
        noticeGeneration &+= 1
        let shown = noticeGeneration
        notice = text
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.noticeGeneration == shown else { return }
            self.notice = nil
        }
    }
}

@MainActor enum TaskBoardSessions {
    private static var sessions: [String: TaskBoardSession] = [:]
    static func session(target: TaskEditorTarget, folder: String?) -> TaskBoardSession {
        let context = WorkSessionContext.shared
        guard let scope = context.scope, let host = target.peer ?? context.localHostIdentity else {
            return TaskBoardSession(target: target, folder: folder)
        }
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: folder ?? "") + (folder == nil ? "all-tasks" : "folder-tasks")
        if let existing = sessions[key] { return existing }
        let created = TaskBoardSession(target: target, folder: folder)
        sessions[key] = created
        return created
    }
}
