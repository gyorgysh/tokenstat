// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// Owns checkpoints and task lifetime independently of the navigation stack.
@MainActor
@Observable
final class ClientSetupCoordinator {
    private(set) var savedDraft: ClientSetupDraft?
    private(set) var working = false
    private(set) var preparation: UUID?
    /// What went wrong, and the one thing to do about it.
    var failure: ClientSetupFailure?

    @ObservationIgnored private let store: ClientSetupStore
    @ObservationIgnored private var scope: ClientSetupScope?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(store: ClientSetupStore = ClientSetupStore()) { self.store = store }

    /// Preparation can outlive the view or be superseded by an account event.
    /// Only its current result may load saved progress or publish a failure.
    func beginPreparation() -> UUID {
        clearAccount()
        let id = UUID()
        preparation = id
        return id
    }

    func finishPreparation(_ id: UUID, scope: ClientSetupScope) -> Bool {
        guard preparation == id else { return false }
        load(scope: scope)
        return true
    }

    func failPreparation(_ id: UUID, error: Error) {
        guard preparation == id else { return }
        preparation = nil
        failure = ClientSetupFailure.from(error)
    }

    func load(scope: ClientSetupScope) {
        cancel()
        self.scope = scope
        savedDraft = nil
        failure = nil
        do { savedDraft = try store.load(scope: scope) }
        catch {
            failure = ClientSetupFailure(
                explanation: "The saved setup could not be opened.",
                changed: "Nothing on the server was removed, and nothing will be.",
                action: .retry,
                details: error.localizedDescription
            )
        }
    }

    func save(_ draft: ClientSetupDraft) throws {
        guard draft.scope == scope else { throw ClientSetupDraftError.invalid }
        try store.save(draft)
        savedDraft = draft
    }

    /// Forget local progress only. Never stop or remove a remote installation.
    func discard() throws {
        cancel()
        // An empty scope is shared and never written (see checkpoint), so
        // there is nothing of this account's to remove.
        if let scope, !scope.account.isEmpty { try store.remove(scope: scope) }
        savedDraft = nil
        failure = nil
    }

    func clearAccount() {
        cancel()
        scope = nil
        savedDraft = nil
        failure = nil
    }

    func cancel() {
        preparation = nil
        generation = UUID()
        task?.cancel()
        task = nil
        working = false
    }

    func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !working else { return }
        let id = UUID()
        generation = id
        failure = nil
        working = true
        let current = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation()
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                // A cancelled step is not a failure and has nothing to say.
                // It still falls through, so the screen stops saying "working".
                if !(error is CancellationError) {
                    self.failure = ClientSetupFailure.from(error)
                }
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
