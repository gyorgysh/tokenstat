// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@MainActor final class TeamAppPresence {
    static let shared = TeamAppPresence()
    private final class State {
        var published: Bool?
        var attempted: Bool?
        var nextAttempt: ContinuousClock.Instant?
        var retry: Duration = .seconds(30)
        var inFlight = false
        var revision: UInt64 = 0
        var pending: (active: Bool, api: TeamAPI)?
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
        state.revision &+= 1
        if state.inFlight {
            state.pending = (active, api)
            return
        }
        if state.attempted == active, let next = state.nextAttempt, now() < next { return }
        if state.published == active, !active { return }
        state.inFlight = true; state.attempted = active
        defer {
            state.inFlight = false
            if let pending = state.pending {
                state.pending = nil
                let revision = state.revision
                Task { @MainActor [weak self] in
                    guard let self, self.states[owner] === state, state.revision == revision else { return }
                    await self.publish(pending.active, owner: owner, api: pending.api)
                }
            }
        }
        do {
            let _: JSONValue = try await api.request(.directory,
                ["operation": .string("presence.set"), "active": .bool(active)], owner: owner)
            state.published = active
            state.retry = .seconds(30)
            state.nextAttempt = now().advanced(by: .seconds(45))
        } catch {
            state.published = nil
            state.nextAttempt = now().advanced(by: state.retry)
            state.retry = min(.seconds(300), state.retry * 2)
        }
    }
}
