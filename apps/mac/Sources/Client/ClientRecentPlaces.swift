// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// Device furniture only. Every read and write requires an account scope, so
/// a late view callback cannot write into whichever account signed in next.
@MainActor @Observable
final class ClientRecentPlaces {
    static let shared = ClientRecentPlaces()
    static let capacity = 20

    struct Scope: Codable, Hashable {
        let host: String
        let handle: String

        init?(host: String, handle: String?) {
            guard let handle, !handle.isEmpty, !host.isEmpty else { return nil }
            self.host = host
            self.handle = handle
        }

        fileprivate var key: String {
            let data = try! JSONEncoder().encode([host, handle])
            return "client.recentPlaces.v1." + data.base64EncodedString()
        }
    }

    enum Kind: String, Codable { case workspace, chat, terminal }

    struct Place: Codable, Equatable, Identifiable {
        struct ID: Codable, Hashable {
            let peer: String
            let workspaceID: String?
            let kind: Kind
            let itemID: String?
        }
        let id: ID
        /// A workspace label only. Chat titles can contain the first prompt;
        /// commands and working directories are never accepted by this API.
        let workspaceName: String
        let openedAt: Date
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func places(in scope: Scope?) -> [Place] {
        _ = revision
        guard let scope, let data = defaults.data(forKey: scope.key),
              let places = try? JSONDecoder().decode([Place].self, from: data)
        else { return [] }
        return Array(places.filter { Self.valid($0.id) }
            .map { Place(id: $0.id, workspaceName: Self.safeName($0.workspaceName), openedAt: $0.openedAt) }
            .sorted { $0.openedAt > $1.openedAt }.prefix(Self.capacity))
    }

    func record(
        in scope: Scope?, peer: String, workspaceID: String?,
        workspaceName: String, kind: Kind, itemID: String? = nil,
        at date: Date = Date()
    ) {
        guard let scope else { return }
        let id = Place.ID(peer: peer, workspaceID: workspaceID, kind: kind, itemID: itemID)
        guard Self.valid(id) else { return }
        let place = Place(id: id, workspaceName: Self.safeName(workspaceName), openedAt: date)
        var recent = places(in: scope).filter { $0.id != id }
        recent.append(place)
        recent.sort { $0.openedAt > $1.openedAt }
        recent = Array(recent.prefix(Self.capacity))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        defaults.set(data, forKey: scope.key)
        revision += 1
    }

    private static func valid(_ id: Place.ID) -> Bool {
        let identifiers = [id.peer, id.workspaceID, id.itemID].compactMap { $0 }
        guard identifiers.allSatisfy({
            !$0.isEmpty && $0.count <= 256 && !$0.contains("/") && !$0.contains("\\")
                && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { return false }
        switch id.kind {
        case .workspace: return id.workspaceID?.isEmpty == false && id.itemID == nil
        case .chat: return id.workspaceID?.isEmpty == false && id.itemID?.isEmpty == false
        case .terminal: return id.itemID?.isEmpty == false
        }
    }

    private static func safeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else { return "Workspace" }
        return String(trimmed.prefix(80))
    }
}
