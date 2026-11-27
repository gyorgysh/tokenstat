// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import Foundation
import Observation

enum TodoScope: Hashable, Sendable {
    case all
    case inbox
    case workspace(String)
}

@MainActor
@Observable
final class TodoModel {
    let noteDrafts = NoteDraftStore()
    private(set) var cards: [TodoCard] = []
    private(set) var backends: [AgentBackend] = []

    private(set) var hasLoaded = false
    var errorMessage: String?
    var selectedCardID: String?
    private(set) var selectionGeneration = 0
    var noticeMessage: String?
    var noticeScope: TodoScope?
    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    private var isVisible = false

    func appeared() async {
        isVisible = true
        await load()
    }

    func disappeared() {
        isVisible = false
        syncPolling()
    }

    var sortNewestFirst = true

    var defaultBudgetMinutes = "180"
    var defaultNoLimit = false

    var showingArchive = false

    var archivedCount: Int { cards.filter { $0.column == "archive" }.count }

    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    func storageColumn(_ column: String) -> String {
        if column == "done", showingArchive { return "archive" }
        return column
    }

    var scope: String?

    var filter: TodoScope = .all

    enum NoteScope: Hashable, Sendable {
        case all
        case unassigned
        case workspace(String)
    }

    func notes(in scope: NoteScope, archived: Bool) -> [TodoCard] {
        cards
            .filter { $0.kind == .note && ($0.column == "archive") == archived }
            .filter { matches($0, scope: scope) }
            .sorted {
                archived
                    ? $0.updatedAtMs > $1.updatedAtMs
                    : $0.createdAtMs > $1.createdAtMs
            }
    }

    var archivedNoteCount: Int {
        cards.filter { $0.kind == .note && $0.column == "archive" }.count
    }

    private func matches(_ card: TodoCard, scope: NoteScope) -> Bool {
        switch scope {
        case .all: return true
        case .unassigned: return card.workspaceID.isEmpty
        case let .workspace(id): return card.workspaceID == id
        }
    }

    @discardableResult
    func addNote(_ text: String, workspaceID: String) async -> Bool {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        do {
            _ = try await Bridge.todoCreate(
                title: title, kind: .note, notes: "", column: "backlog",
                backend: "", workspaceID: workspaceID, budgetSeconds: 0
            )
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func archiveNote(_ card: TodoCard, archived: Bool) async {
        do {
            _ = try await Bridge.todoUpdate(id: card.id, column: archived ? "archive" : "backlog")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func convertToTask(_ card: TodoCard, workspaceID: String) async {
        do {
            _ = try await Bridge.todoUpdate(
                id: card.id,
                column: "backlog",
                kind: .task,
                notes: card.notes.isEmpty ? card.title : card.notes,
                workspaceID: workspaceID
            )
            showNotice(L10n.text("apple.todomodel.moved_to_tasks.903d2d20"))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cards(in column: String) -> [TodoCard] {
        let target = storageColumn(column)
        let list = cards.filter { $0.column == target && $0.kind != .note && inScope($0) }
        if sortNewestFirst {
            return list.sorted { $0.createdAtMs > $1.createdAtMs }
        }
        return list.sorted { $0.order < $1.order }
    }

    private func destinationScope(of card: TodoCard) -> TodoScope {
        card.workspaceID.isEmpty ? .inbox : .workspace(card.workspaceID)
    }

    private func inScope(_ card: TodoCard) -> Bool {
        if let scope { return card.workspaceID == scope }
        switch filter {
        case .all: return true
        case .inbox: return card.workspaceID.isEmpty
        case let .workspace(id): return card.workspaceID == id
        }
    }

    var defaultWorkspaceID: String? {
        if let scope { return scope }
        if case let .workspace(id) = filter { return id }
        return nil
    }

    var unfiledCount: Int {
        cards.filter {
            $0.kind != .note
                && $0.workspaceID.isEmpty
                && $0.column != "done"
                && $0.column != "archive"
        }.count
    }

    func openCount(in workspaceID: String) -> Int {
        cards.filter {
            $0.workspaceID == workspaceID
                && $0.kind != .note
                && $0.column != "done"
                && $0.column != "archive"
        }.count
    }

    func noteCount(in workspaceID: String) -> Int {
        cards.filter {
            $0.workspaceID == workspaceID
                && $0.kind == .note
                && $0.column != "archive"
        }.count
    }

    func dropOutOfScopeSelection() {
        if let selected = selectedCard, !inScope(selected) {
            selectedCardID = nil
        }
    }

    var selectedCard: TodoCard? {
        guard let selectedCardID else { return nil }
        return cards.first { $0.id == selectedCardID }
    }

    func selectCard(_ id: String) {
        selectedCardID = id
        selectionGeneration += 1
    }

    private var loadGeneration: UInt64 = 0

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            async let c = Bridge.todoCards(includeArchived: true)
            async let b = Bridge.automationBackends()
            let (freshCards, freshBackends) = try await (c, b)
            let freshQueue = try? await Bridge.automationQueue()
            guard !Task.isCancelled, generation == loadGeneration else { return }
            cards = freshCards
            backends = freshBackends
            if let queue = freshQueue {
                defaultNoLimit = queue.defaultBudgetSeconds == 0
                if queue.defaultBudgetSeconds > 0 {
                    defaultBudgetMinutes = String(max(1, queue.defaultBudgetSeconds / 60))
                }
            }
            hasLoaded = true
            errorMessage = nil
            syncPolling()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshCounts() async {
        guard let fresh = try? await Bridge.todoCards(includeArchived: true) else { return }
        if cards != fresh { cards = fresh }
    }

    func taskCreated(_ created: TodoCard, folders: [WorkspaceFolder]) async {
        if inScope(created) { showNotice(L10n.text("apple.todomodel.task_added.d37be00e")) }
        else {
            let place = created.workspaceID.isEmpty ? L10n.text("apple.todomodel.uncategorized.8d40d123") : folders.first(where: { $0.id == created.workspaceID })?.name ?? L10n.text("apple.todomodel.another_folder.c5f5ba2c")
            showNotice(L10n.text("apple.todomodel.task_added_to_0.54e9b589", "\(place)"), scope: scope == nil ? destinationScope(of: created) : nil)
        }
        errorMessage = nil
        await load()
    }

    func move(_ card: TodoCard, to column: String) async {
        do {
            _ = try await Bridge.todoUpdate(id: card.id, column: column)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorder(_ card: TodoCard, to column: String, order: Int64) async {
        sortNewestFirst = false
        do {
            _ = try await Bridge.todoUpdate(id: card.id, column: column, order: order)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateCard(
        _ card: TodoCard,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        workspaceID: String? = nil,
        budgetSeconds: UInt64? = nil,
        priority: String? = nil
    ) async -> Bool {
        var draft = TaskEditorDraft(card)
        if let backend { draft.backend = backend }
        if let model { draft.model = model }
        if let effort { draft.effort = effort }
        if let workspaceID { draft.workspaceID = workspaceID }
        if let priority { draft.priority = priority }
        if let budgetSeconds {
            draft.noTimeLimit = budgetSeconds == 0
            draft.budgetValue = String(budgetSeconds)
            draft.budgetUnit = "seconds"
        }
        if let validation = draft.validation { errorMessage = validation; return false }
        guard card.revision != nil else {
            errorMessage = L10n.text("apple.todomodel.reload_this_task_before_saving_its_setting.afe9a32c")
            return false
        }
        do {
            _ = try await Bridge.todoUpdate(
                id: card.id,
                backend: backend,
                model: model,
                effort: effort,
                workspaceID: workspaceID,
                budgetSeconds: budgetSeconds,
                priority: priority,
                expectedRevision: card.revision
            )
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateTitle(_ card: TodoCard, title: String) async -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if value == card.title { return true }
        do {
            _ = try await Bridge.todoUpdate(id: card.id, title: value)
            showNotice(L10n.text("apple.todomodel.saved_0.8eb4b783", "\(value)"))
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveNoteDraft(_ id: String) async {
        await noteDrafts.save(id) { text in
            _ = try await Bridge.todoUpdate(id: id, title: text.title, notes: text.body)
        }
        if let failure = noteDrafts.entries[id]?.error {
            errorMessage = failure
        } else {
            errorMessage = nil
            await load()
        }
    }

    @discardableResult
    func updateNotes(_ card: TodoCard, notes: String) async -> Bool {
        if notes == card.notes { return true }
        do {
            _ = try await Bridge.todoUpdate(id: card.id, notes: notes)
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func delegate(_ card: TodoCard) async -> String? {
        do {
            let updated = try await Bridge.todoDelegate(id: card.id)
            showNotice(L10n.text("apple.todomodel.handed_0_to_an_agent.095b5329", "\(card.title)"))
            errorMessage = nil
            await load()
            return updated.delegate?.runId ?? cards.first { $0.id == card.id }?.delegate?.runId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func noticeOpenedInFront(_ title: String) {
        showNotice(L10n.text("apple.todomodel.opened_0_in_a_terminal.37753566", "\(title)"))
    }

    private func showNotice(_ message: String, scope: TodoScope? = nil) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = message
        noticeScope = scope
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
            self.noticeScope = nil
        }
    }

    func stop(_ card: TodoCard) async {
        do {
            _ = try await Bridge.todoStop(id: card.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ card: TodoCard) async {
        do {
            if card.isNote { try await Bridge.todoRemove(id: card.id) }
            else { try await TaskEditorTarget(peer: nil).deleteTask(card) }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncPolling() {
        let running = isVisible && cards.contains { $0.delegate?.isRunning == true }
        if running && pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.load()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else if !running {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
