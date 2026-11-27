// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
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

@MainActor
enum LaunchAgentProfile {
    private static var catalogs: [String: (profiles: AgentProfiles, workspaceID: String)] = [:]

    private static func key(_ folderID: String) -> String { "launch.agentProfile.\(folderID)" }

    static func remember(_ profiles: AgentProfiles?, folderID: String, workspaceID: String) {
        catalogs[folderID] = profiles.map { ($0, workspaceID) }
    }

    static func forget(folderID: String) { catalogs[folderID] = nil }

    static func chosen(for folderID: String) -> String? {
        UserDefaults.standard.string(forKey: key(folderID))
    }

    static func choose(_ id: String?, for folderID: String) {
        if let id { UserDefaults.standard.set(id, forKey: key(folderID)) }
        else { UserDefaults.standard.removeObject(forKey: key(folderID)) }
    }

    static func stored(for folderID: String) -> String? {
        guard let entry = catalogs[folderID] else { return nil }
        if entry.profiles.workspaceLocks?[entry.workspaceID] != nil { return nil }
        let id = chosen(for: folderID) ?? entry.profiles.default
        guard id != AgentProfiles.system, entry.profiles.profile(id) != nil else { return nil }
        return id
    }
}
