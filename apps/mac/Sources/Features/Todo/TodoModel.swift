// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

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

    /// Cards for a column, in the active sort.
    func cards(in column: String) -> [TodoCard] {
        let list = cards.filter { $0.column == column }
        if sortNewestFirst {
            return list.sorted { $0.createdAtMs > $1.createdAtMs }
        }
        return list.sorted { $0.order < $1.order }
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
            async let c = Bridge.todoCards()
            async let b = Bridge.automationBackends()
            cards = try await c
            backends = try await b
            hasLoaded = true
            errorMessage = nil
            syncPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(
        title: String, kind: TodoKind, notes: String, backend: String,
        workspaceID: String, budgetSeconds: UInt64, column: String = "backlog",
        model: String? = nil, effort: String? = nil
    ) async {
        do {
            _ = try await Bridge.todoCreate(
                title: title, kind: kind, notes: notes, column: column,
                backend: backend, workspaceID: workspaceID, budgetSeconds: budgetSeconds,
                model: model, effort: effort
            )
            showNotice(kind == .note ? "Note added." : "Card added.")
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

    func updateCard(
        _ card: TodoCard,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        workspaceID: String? = nil,
        budgetSeconds: UInt64? = nil
    ) async {
        do {
            _ = try await Bridge.todoUpdate(
                id: card.id,
                backend: backend,
                model: model,
                effort: effort,
                workspaceID: workspaceID,
                budgetSeconds: budgetSeconds
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateTitle(_ card: TodoCard, title: String) async {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != card.title else { return }
        do {
            _ = try await Bridge.todoUpdate(id: card.id, title: value)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateNotes(_ card: TodoCard, notes: String) async {
        guard notes != card.notes else { return }
        do {
            _ = try await Bridge.todoUpdate(id: card.id, notes: notes)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delegate(_ card: TodoCard) async {
        do {
            _ = try await Bridge.todoDelegate(id: card.id)
            showNotice("Handed \"\(card.title)\" to an agent.")
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showNotice(_ message: String) {
        noticeGeneration += 1
        let generation = noticeGeneration
        noticeMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.noticeMessage = nil
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
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    await self.load()
                }
            }
        } else if !running {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
