// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// One explicit handoff sheet for one conversation. Reading a record never
/// writes to the composer or the reading store; importing is a separate action.
@MainActor @Observable
final class WorkHandoffModel {
    enum Phase: Equatable {
        case idle, loading, ready, sharing, shared, conflict, failed, invalidated
    }

    let reference: WorkReference
    private(set) var phase: Phase = .idle
    private(set) var shared: WorkHandoff?
    /// Immutable after a send starts, including when its acknowledgement is lost.
    private(set) var pending: WorkHandoffRequest?
    private(set) var error: String?
    private var hasLoaded = false
    private var generation = UUID()
    private let ownsDestination: @MainActor () -> Bool
    private let fetch: @MainActor () async throws -> WorkHandoff?
    private let put: @MainActor (WorkHandoffRequest) async throws -> WorkHandoffResult

    init(reference: WorkReference,
         ownsDestination: @escaping @MainActor () -> Bool,
         fetch: @escaping @MainActor () async throws -> WorkHandoff?,
         put: @escaping @MainActor (WorkHandoffRequest) async throws -> WorkHandoffResult) {
        self.reference = reference
        self.ownsDestination = ownsDestination
        self.fetch = fetch
        self.put = put
    }

    var isBusy: Bool { phase == .loading || phase == .sharing }
    var canShare: Bool { hasLoaded && pending == nil && !isBusy && phase != .invalidated }
    var canRetryShare: Bool { phase == .failed && pending != nil }

    /// Called on dismissal, scope change or loss of the selected destination.
    /// An in-flight host write may have succeeded; it cannot update another view.
    func invalidate() {
        generation = UUID()
        shared = nil
        pending = nil
        error = nil
        hasLoaded = false
        phase = .invalidated
    }

    private func owns(_ token: UUID) -> Bool {
        guard token == generation, phase != .invalidated else { return false }
        guard !Task.isCancelled, ownsDestination() else {
            invalidate()
            return false
        }
        return true
    }

    func load() async {
        let token = generation
        guard !isBusy, pending == nil, owns(token) else { return }
        phase = .loading
        error = nil
        do {
            let record = try await fetch()
            guard owns(token) else { return }
            shared = record
            hasLoaded = true
            phase = .ready
        } catch {
            guard owns(token) else { return }
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    /// The caller takes a snapshot of the local draft and reading position only
    /// when the user chooses Share. Later typing cannot change an uncertain send.
    func share(deviceName: String, draft: WorkSharedDraft?, anchor: WorkHandoffAnchor?) async {
        guard canShare, owns(generation) else { return }
        pending = WorkHandoffRequest(requestID: UUID().uuidString,
            expectedRevision: shared?.revision ?? 0, deviceName: deviceName,
            draft: draft, anchor: anchor)
        await sendPending()
    }

    func retryShare() async {
        guard canRetryShare else { return }
        await sendPending()
    }

    /// Explicitly publish the preserved local version after reviewing a
    /// conflict. Another intervening edit produces another conflict, never a
    /// blind overwrite. The original local payload remains unchanged.
    func shareMyVersion() async {
        guard phase == .conflict, let previous = pending, owns(generation) else { return }
        pending = WorkHandoffRequest(requestID: UUID().uuidString,
            expectedRevision: shared?.revision ?? 0, deviceName: previous.deviceName,
            draft: previous.draft, anchor: previous.anchor)
        await sendPending()
    }

    /// Keep the local composer and leave the host's version alone. This is only
    /// available for an answered conflict, not an uncertain write.
    func keepMine() {
        guard phase == .conflict, owns(generation) else { return }
        pending = nil
        error = nil
        phase = .ready
    }

    private func sendPending() async {
        let token = generation
        guard !isBusy, let request = pending, owns(token) else { return }
        phase = .sharing
        error = nil
        do {
            let result = try await put(request)
            guard owns(token) else { return }
            switch result {
            case let .saved(record):
                shared = record
                pending = nil
                phase = .shared
            case let .conflict(current):
                shared = current
                phase = .conflict
            }
        } catch {
            guard owns(token) else { return }
            self.error = error.localizedDescription
            phase = .failed
        }
    }
}
