// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// One explicitly selected host in a search presentation. Every suspension
/// rechecks the captured owner; this connection never pairs or wakes machines.
@MainActor
final class WorkSearchLiveConnection {
    struct Unavailable: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Transport {
        let allowed: @MainActor () async throws -> Bool
        let version: @MainActor () async throws -> Int
        let search: @MainActor (String, Set<WorkReference.Kind>, String?) async throws -> WorkSearchLive.Response
    }

    let host: String
    private let scope: WorkReference.Scope
    private let ownsSession: @MainActor () -> Bool
    private let transport: Transport
    private var closed = false

    init(host: String, scope: WorkReference.Scope, transport: Transport,
         ownsSession: @escaping @MainActor () -> Bool) {
        self.host = host
        self.scope = scope
        self.transport = transport
        self.ownsSession = ownsSession
    }

    func close() { closed = true }

    private func requireCurrent() throws {
        guard !closed, !Task.isCancelled, ownsSession() else { throw CancellationError() }
    }

    func search(query: String, kinds: Set<WorkReference.Kind> = [], cursor: String? = nil) async throws -> WorkSearchLive.Page {
        try requireCurrent()
        let parsed = try WorkSearchQuery(query)
        guard !parsed.terms.isEmpty else { throw Unavailable(message: L10n.text("apple.worksearchliveconnection.enter_words_to_search.a02980fd")) }
        let allowed = try await transport.allowed()
        try requireCurrent()
        guard allowed else { throw Unavailable(message: L10n.text("apple.worksearchliveconnection.project_access_is_no_longer_available_on_t.357734b8")) }
        let version = try await transport.version()
        try requireCurrent()
        guard version >= 12 else { throw Unavailable(message: L10n.text("apple.worksearchliveconnection.update_tokenstat_on_this_computer_to_searc.f5cebe47")) }
        let response = try await transport.search(query, kinds, cursor)
        try requireCurrent()
        guard cursor == nil || response.nextCursor != cursor else { throw WorkSearchLive.Invalid.response }
        let page = try WorkSearchLive.decode(JSONEncoder().encode(response), expectedHost: host, scope: scope, kinds: kinds)
        try requireCurrent()
        return page
    }
}
