// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// Owns checkpoints and task lifetime independently of the navigation stack.
@MainActor
@Observable
final class ClientSetupCoordinator {
    private(set) var savedDraft: ClientSetupDraft?
    private(set) var working = false
    var error: String?

    @ObservationIgnored private let store: ClientSetupStore
    @ObservationIgnored private var scope: ClientSetupScope?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(store: ClientSetupStore = ClientSetupStore()) { self.store = store }

    func load(scope: ClientSetupScope) {
        cancel()
        self.scope = scope
        savedDraft = nil
        error = nil
        do { savedDraft = try store.load(scope: scope) }
        catch { self.error = "Saved setup could not be opened. You can start a new setup; nothing on the server will be removed." }
    }

    func save(_ draft: ClientSetupDraft) throws {
        guard draft.scope == scope else { throw ClientSetupDraftError.invalid }
        try store.save(draft)
        savedDraft = draft
    }

    /// Forget local progress only. Never stop or remove a remote installation.
    func discard() throws {
        cancel()
        if let scope { try store.remove(scope: scope) }
        savedDraft = nil
        error = nil
    }

    func clearAccount() {
        cancel()
        scope = nil
        savedDraft = nil
        error = nil
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        working = false
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !working else { return }
        let id = UUID()
        generation = id
        error = nil
        working = true
        let current = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation()
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.error = error.localizedDescription
            }
            guard let self, !Task.isCancelled, self.generation == id else { return }
            self.working = false
            self.task = nil
        }
        task = current
        await withTaskCancellationHandler {
            await current.value
        } onCancel: {
            current.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.cancel()
            }
        }
    }
}
