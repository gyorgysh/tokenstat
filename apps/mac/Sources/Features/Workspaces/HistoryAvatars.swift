// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

struct HistoryPictureRequest: Equatable, Sendable {
    var workspaceID: String
    var from: String
}

@MainActor
final class HistoryAvatarCache {
    struct Key: Hashable {
        var owner: UInt64
        var peer: String
        var workspace: String
        var from: String
    }
    private struct Entry { var index: HistoryAvatarIndex; var at: Date }
    static let shared = HistoryAvatarCache()
    private var entries: [Key: Entry] = [:]
    private let lifetime: TimeInterval = 300

    func exact(_ key: Key, now: Date = Date()) -> HistoryAvatarIndex? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) >= 0,
              now.timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.index
    }

    func recent(_ key: Key, now: Date = Date()) -> HistoryAvatarIndex? {
        entries.filter { candidate, entry in
            candidate.owner == key.owner && candidate.peer == key.peer && candidate.workspace == key.workspace
                && now.timeIntervalSince(entry.at) >= 0 && now.timeIntervalSince(entry.at) < lifetime
        }.max { $0.value.at < $1.value.at }?.value.index
    }

    func store(_ index: HistoryAvatarIndex, for key: Key, now: Date = Date()) {
        entries[key] = Entry(index: index.normalized(), at: now)
        if entries.count > 64, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}

struct HistoryAvatarIndex: Codable, Sendable, Equatable {
    var byCommit: [String: String] = [:]
    var byEmail: [String: String] = [:]

    static let empty = HistoryAvatarIndex()

    func url(commitID: String, email: String?, mine: Bool, accountAvatar: String?) -> String? {
        if mine, let own = Self.present(accountAvatar) { return own }
        if let hit = Self.secure(byCommit, commitID) { return hit }
        if let hit = Self.secure(byEmail, email) { return hit }
        return nil
    }

    func normalized() -> HistoryAvatarIndex {
        HistoryAvatarIndex(byCommit: Self.fold(byCommit), byEmail: Self.fold(byEmail))
    }

    private static func fold(_ map: [String: String]) -> [String: String] {
        var folded: [String: String] = [:]
        for (key, value) in map {
            guard let name = present(key)?.lowercased(), let picture = secureValue(value) else { continue }
            if folded[name] == nil { folded[name] = picture }
        }
        return folded
    }

    private static func secure(_ map: [String: String], _ key: String?) -> String? {
        guard let name = present(key)?.lowercased() else { return nil }
        if let direct = map[name], let picture = secureValue(direct) { return picture }
        for (raw, value) in map {
            guard present(raw)?.lowercased() == name, let picture = secureValue(value) else { continue }
            return picture
        }
        return nil
    }

    private static func secureValue(_ value: String) -> String? {
        guard let picture = present(value), picture.hasPrefix("https://") else { return nil }
        return picture
    }

    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
