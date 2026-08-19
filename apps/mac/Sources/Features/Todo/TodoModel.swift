// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// What the global board is showing.
///
/// Inbox is not a fourth column, it is a filter: a card with no folder is an
/// ordinary card that has not been assigned, and giving it a column of its own
/// would mean moving a card twice to get it into a folder's To Do.
enum TodoScope: Hashable, Sendable {
    case all
    case inbox
    case workspace(String)
}

/// The kanban board. Cards live in the daemon, and delegating one starts an
/// agent run whose transcript lands in the automations history.
@MainActor
@Observable
final class TodoModel {
    private(set) var cards: [TodoCard] = []
    private(set) var backends: [AgentBackend] = []

    /// True once the board has been read at least once.
    ///
    /// An empty board and a board that has not loaded look identical, and they
    /// mean opposite things. Without this the columns said "No cards" for the
    /// length of the first read, which is a claim rather than a wait.
    private(set) var hasLoaded = false
    var errorMessage: String?
    /// The card the inspector is showing.
    var selectedCardID: String?
    /// Bumps on every select, including a second click on the same card, so
    /// the inspector can reopen.
    private(set) var selectionGeneration = 0
    var noticeMessage: String?
    /// Where the notice's subject went, when that is somewhere this board is
    /// not showing. The toast offers it as Show; the view applies it.
    var noticeScope: TodoScope?
    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    /// True while the board is on screen.
    ///
    /// Polling is for keeping a board somebody is watching honest. The model
    /// outlives the view, so without this the two-second loop carried on
    /// running for the rest of the session after a single visit to a screen
    /// with a delegated card on it.
    private var isVisible = false

    /// The board appeared. Load, and start polling if anything is running.
    func appeared() async {
        isVisible = true
        await load()
    }

    /// The board went away. Nothing to keep honest.
    func disappeared() {
        isVisible = false
        syncPolling()
    }

    /// Newest first by added date, or the order the person arranged.
    var sortNewestFirst = true

    /// Scheduler default, used when a new card does not set its own limit.
    var defaultBudgetMinutes = "180"
    var defaultNoLimit = false

    /// When true, the Done column shows archived cards instead.
    var showingArchive = false

    var archivedCount: Int { cards.filter { $0.column == "archive" }.count }

    /// Picker list: hidden workspace tiles stay out, except the current pick.
    func pickerBackends(keeping id: String? = nil) -> [AgentBackend] {
        backends.visibleForPicker(keeping: id)
    }

    /// Board column id to the stored column (Archive lives under Done).
    func storageColumn(_ column: String) -> String {
        if column == "done", showingArchive { return "archive" }
        return column
    }

    /// Which workspace the board is showing, set by the route. Nil is the
    /// global board.
    ///
    /// Scope lives on the model rather than in the view because the counts in
    /// the sidebar ask the same question, and two places deciding what belongs
    /// to a folder is two places to get it wrong.
    var scope: String?

    /// The global board's own selector. Ignored while `scope` is set: a
    /// folder's board is that folder's, and a filter on top of it would be
    /// two answers to one question.
    ///
    /// Separate from `scope` because they are different things. Scope is
    /// where you are, filter is what you asked to see, and folding them
    /// together made the global board look locked to a folder it had merely
    /// been asked to show.
    var filter: TodoScope = .all

    /// Which notes the notes screen is showing.
    ///
    /// Notes are not work in a stage, but they do belong somewhere: a folder,
    /// or unassigned (global). All is the union of those.
    enum NoteScope: Hashable, Sendable {
        case all
        case unassigned
        case workspace(String)
    }

    /// Notes in a scope, newest first.
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

    /// Notes that have been put away, in any folder. Used to enable Archive.
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

    /// Capture a note. Title only, because that is the whole point: the cost
    /// of writing one down has to be lower than the cost of losing it.
    ///
    /// `workspaceID` is empty for an unassigned (global) note, or a folder id
    /// when the note belongs to a project.
    func addNote(_ text: String, workspaceID: String) async {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            _ = try await Bridge.todoCreate(
                title: title, kind: .note, notes: "", column: "backlog",
                backend: "", workspaceID: workspaceID, budgetSeconds: 0
            )
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Put a note away, or take it back out.
    func archiveNote(_ card: TodoCard, archived: Bool) async {
        do {
            _ = try await Bridge.todoUpdate(id: card.id, column: archived ? "archive" : "backlog")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Turn a note into a card on the board.
    ///
    /// The one bridge between the two, and the reason capture can be cheap:
    /// nothing has to be decided while writing the thing down. The note's own
    /// text becomes the prompt, which is what `todo.rs` hands an agent anyway
    /// when a card has no separate body.
    func convertToTask(_ card: TodoCard, workspaceID: String) async {
        do {
            _ = try await Bridge.todoUpdate(
                id: card.id,
                column: "backlog",
                kind: .task,
                notes: card.notes.isEmpty ? card.title : card.notes,
                workspaceID: workspaceID
            )
            showNotice("Moved to Tasks.")
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cards for a column, in the active sort, inside the current scope.
    func cards(in column: String) -> [TodoCard] {
        let target = storageColumn(column)
        let list = cards.filter { $0.column == target && $0.kind != .note && inScope($0) }
        if sortNewestFirst {
            return list.sorted { $0.createdAtMs > $1.createdAtMs }
        }
        return list.sorted { $0.order < $1.order }
    }

    /// The filter that would show this card on the global board.
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

    /// Where a new card should land: the folder whose board this is, or the
    /// one the global board has been filtered to. Nothing, on All and Inbox.
    var defaultWorkspaceID: String? {
        if let scope { return scope }
        if case let .workspace(id) = filter { return id }
        return nil
    }

    /// Cards nobody filed. Not an inbox anybody works out of: the absence of
    /// a folder, which `todo.rs` has always allowed.
    var unfiledCount: Int {
        cards.filter {
            $0.workspaceID.isEmpty && $0.column != "done" && $0.column != "archive"
        }.count
    }

    /// Cards still to do in a folder: the sidebar count.
    ///
    /// Done, archived and notes are not work left. A badge that only ever
    /// goes up is not a badge.
    func openCount(in workspaceID: String) -> Int {
        cards.filter {
            $0.workspaceID == workspaceID
                && $0.kind != .note
                && $0.column != "done"
                && $0.column != "archive"
        }.count
    }

    /// Drop a selection that the new scope would hide.
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

    func load() async {
        do {
            async let c = Bridge.todoCards(includeArchived: true)
            async let b = Bridge.automationBackends()
            cards = try await c
            backends = try await b
            if let queue = try? await Bridge.automationQueue() {
                defaultNoLimit = queue.defaultBudgetSeconds == 0
                if queue.defaultBudgetSeconds > 0 {
                    defaultBudgetMinutes = String(max(1, queue.defaultBudgetSeconds / 60))
                }
            }
            hasLoaded = true
            errorMessage = nil
            syncPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-read the cards for the sidebar's counts, and nothing else.
    ///
    /// No backends, no queue config, and no error banner: this runs on a timer
    /// nobody asked for, so a host that blinks during it must not put a red
    /// message on a board the person is not even looking at.
    func refreshCounts() async {
        guard let fresh = try? await Bridge.todoCards(includeArchived: true) else { return }
        if cards != fresh { cards = fresh }
    }

    func create(
        title: String, kind: TodoKind, notes: String, backend: String,
        workspaceID: String, budgetSeconds: UInt64, column: String = "backlog",
        model: String? = nil, effort: String? = nil,
        destinationName: String = ""
    ) async {
        do {
            let created = try await Bridge.todoCreate(
                title: title, kind: kind, notes: notes, column: column,
                backend: backend, workspaceID: workspaceID, budgetSeconds: budgetSeconds,
                model: model, effort: effort
            )
            // A card that lands where this board cannot show it says where it
            // went, and offers the way there. Silence here is what lost two
            // notes: they were written, saved, and then invisible.
            let noun = kind == .note ? "Note" : "Card"
            if inScope(created) {
                showNotice("\(noun) added.")
            } else {
                let place = destinationName.isEmpty ? "another board" : destinationName
                // Only the global board can follow: a folder's board is fixed
                // by the route, so there it names the place and stops.
                showNotice(
                    "\(noun) added to \(place).",
                    scope: scope == nil ? destinationScope(of: created) : nil
                )
            }
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        budgetSeconds: UInt64? = nil
    ) async -> Bool {
        do {
            _ = try await Bridge.todoUpdate(
                id: card.id,
                backend: backend,
                model: model,
                effort: effort,
                workspaceID: workspaceID,
                budgetSeconds: budgetSeconds
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
            showNotice("Saved \"\(value)\".")
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
            showNotice("Handed \"\(card.title)\" to an agent.")
            errorMessage = nil
            await load()
            return updated.delegate?.runId ?? cards.first { $0.id == card.id }?.delegate?.runId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func noticeOpenedInFront(_ title: String) {
        showNotice("Opened \"\(title)\" in a terminal.")
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
            try await Bridge.todoRemove(id: card.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// While any card is running and somebody is looking, keep the board honest
    /// without a push channel.
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
