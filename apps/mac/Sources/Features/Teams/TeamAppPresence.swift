// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// All windows share one publisher for each login. Visibility is sampled
/// locally; only a change or a due foreground heartbeat reaches the server.
@MainActor final class TeamAppPresence {
    static let shared = TeamAppPresence()
    private final class State {
        var published: Bool?
        var attempted: Bool?
        var nextAttempt: ContinuousClock.Instant?
        var retry: Duration = .seconds(30)
        var inFlight = false
    }
    private var states: [TeamAccountOwner: State] = [:]
    private var owners: [TeamAccountOwner] = []
    private let now: () -> ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) { self.now = now }

    func publish(_ active: Bool, owner: TeamAccountOwner, api: TeamAPI) async {
        let state: State
        if let existing = states[owner] { state = existing }
        else {
            state = State(); states[owner] = state; owners.append(owner)
            if owners.count > 8 { states.removeValue(forKey: owners.removeFirst()) }
        }
        guard !state.inFlight else { return }
        if state.attempted == active, let next = state.nextAttempt, now() < next { return }
        if state.published == active, !active { return }
        state.inFlight = true; state.attempted = active
        defer { state.inFlight = false }
        do {
            let _: JSONValue = try await api.request(.directory,
                ["operation": .string("presence.set"), "active": .bool(active)], owner: owner)
            state.published = active
            state.retry = .seconds(30)
            // The existing server lease lasts 75 seconds. Leave 30 seconds
            // for transport delays without extending stale online status.
            state.nextAttempt = now().advanced(by: .seconds(45))
        } catch {
            // A lost reply may still have reached the server. A later state
            // change must publish again, including an inactive transition.
            state.published = nil
            state.nextAttempt = now().advanced(by: state.retry)
            state.retry = min(.seconds(300), state.retry * 2)
        }
    }
}
