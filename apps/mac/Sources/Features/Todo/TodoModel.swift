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
    var errorMessage: String?
    var noticeMessage: String?
    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    /// Cards for a column, in board order.
    func cards(in column: String) -> [TodoCard] {
        cards.filter { $0.column == column }
    }

    func load() async {
        do {
            async let c = Bridge.todoCards()
            async let b = Bridge.automationBackends()
            cards = try await c
            backends = try await b
            errorMessage = nil
            syncPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(
        title: String, kind: TodoKind, notes: String, backend: String,
        workspaceID: String, budgetSeconds: UInt64
    ) async {
        do {
            _ = try await Bridge.todoCreate(
                title: title, kind: kind, notes: notes, column: "backlog",
                backend: backend, workspaceID: workspaceID, budgetSeconds: budgetSeconds
            )
            showNotice(kind == .note ? "Note added." : "Added to To Do.")
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
        do {
            _ = try await Bridge.todoUpdate(id: card.id, column: column, order: order)
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

    /// While any card is running, keep the board honest without a push channel.
    private func syncPolling() {
        let running = cards.contains { $0.delegate?.isRunning == true }
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
