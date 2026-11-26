// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Observation

@MainActor @Observable
final class AgentProfileCatalog {
    static let shared = AgentProfileCatalog()
    private(set) var value: AgentProfiles?
    private var remote: [String: AgentProfiles] = [:]
    private var accountGeneration: UInt64?

    func remember(_ profiles: AgentProfiles, peer: String, account: UInt64) {
        if accountGeneration != account { remote = [:]; accountGeneration = account }
        remote[peer] = profiles
    }

    func name(_ id: String) -> String? {
        if let title = value?.profile(id)?.title { return title }
        guard accountGeneration == WorkSessionContext.shared.generation else { return nil }
        return remote.values.lazy.compactMap { $0.profile(id)?.title }.first
    }

    private var generation = 0

    func refresh() async throws {
        let generation = self.generation
        let loaded = try await Bridge.agentProfiles()
        guard !Task.isCancelled, generation == self.generation else { return }
        value = loaded
    }

    func replace(_ profiles: AgentProfiles) {
        generation += 1
        value = profiles
    }
}
