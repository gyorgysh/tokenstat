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
        let identity: String

        init?(host: String, handle: String?, id: String?) {
            guard !host.isEmpty,
                  let identity = WorkReference.Scope.accountIdentity(handle: handle, id: id) else { return nil }
            self.host = host
            self.identity = identity
        }

        fileprivate var key: String {
            // Length-prefixed rather than encoded: no throwing, and "ab"+"c"
            // never shares a key with "a"+"bc".
            "client.recentPlaces.v1.\(host.count):\(host)\(identity.count):\(identity)"
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
        /// paths and commands are never accepted as display labels.
        let workspaceName: String
        let openedAt: Date
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var revision = 0
    private struct ChatOwner: Hashable { let peer: String; let workspace: String? }

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

    /// Keep the last conversation reachable even when recent folders and
    /// terminals would otherwise fill the short Home list.
    func continuePlaces(in scope: Scope?, limit: Int = 4) -> [Place] {
        guard limit > 0 else { return [] }
        // Titles are deliberately not persisted: a title can contain a private
        // prompt. Multiple chats in the same repository would therefore have
        // identical labels, so offer its most recently opened chat once.
        var chatOwners = Set<ChatOwner>()
        let recent = places(in: scope).filter { place in
            guard place.id.kind == .chat else { return true }
            return chatOwners.insert(ChatOwner(peer: place.id.peer, workspace: place.id.workspaceID)).inserted
        }
        var shown = Array(recent.prefix(limit))
        if !shown.contains(where: { $0.id.kind == .chat }),
           let chat = recent.first(where: { $0.id.kind == .chat }) {
            if shown.count == limit { shown.removeLast() }
            shown.append(chat)
        }
        return shown
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
        if let lastChat = recent.first(where: { $0.id.kind == .chat }),
           !recent.prefix(Self.capacity).contains(where: { $0.id == lastChat.id }) {
            recent = Array(recent.prefix(Self.capacity - 1)) + [lastChat]
        } else {
            recent = Array(recent.prefix(Self.capacity))
        }
        guard let data = try? JSONEncoder().encode(recent) else { return }
        defaults.set(data, forKey: scope.key)
        revision += 1
    }

    private static func valid(_ id: Place.ID) -> Bool {
        // Hosts use a canonical path as the workspace identifier. It must
        // round-trip unchanged to reach the folder, but is never used as a
        // display label. Peer and conversation IDs are not paths.
        if let workspace = id.workspaceID {
            guard !workspace.isEmpty, workspace.count <= 4096,
                  workspace.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        }
        let identifiers = [id.peer, id.itemID].compactMap { $0 }
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
        else { return L10n.text("apple.clientrecentplaces.project.98595978") }
        return String(trimmed.prefix(80))
    }
}
