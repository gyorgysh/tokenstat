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

/// The agent profile the next terminal launch in a folder signs in with.
///
/// Remembered per folder on this device. Until somebody picks one, a launch
/// uses the profile set as the default for new chats, so a terminal and a
/// chat started in the same folder use the same login. A repository locked
/// to a profile always launches on it, and the host refuses anything else.
@MainActor
enum LaunchAgentProfile {
    /// The last list read for each folder, and the host's id for that
    /// folder, so a launch knows the default and the lock without waiting.
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

    /// What this launch should ask the host for. Nil leaves the choice to the
    /// host: a locked repository's own profile, or this machine's logins.
    static func stored(for folderID: String) -> String? {
        guard let entry = catalogs[folderID] else { return nil }
        if entry.profiles.workspaceLocks?[entry.workspaceID] != nil { return nil }
        let id = chosen(for: folderID) ?? entry.profiles.default
        // A profile deleted since it was picked falls back to the machine
        // rather than failing every launch from this folder.
        guard id != AgentProfiles.system, entry.profiles.profile(id) != nil else { return nil }
        return id
    }
}
