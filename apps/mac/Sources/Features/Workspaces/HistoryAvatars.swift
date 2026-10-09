// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Where a history list asks the forge to start, and which workspace it asks about.
struct HistoryPictureRequest: Equatable, Sendable {
    var workspaceID: String
    var from: String
}

/// Public profile pictures for the authors of one history list.
///
/// The host asks the repository's forge for one page of commits and returns
/// the pictures already attached to those accounts. A commit this repository
/// counts as yours keeps the signed-in account's own picture. Everyone else
/// uses the forge picture for that commit, or the same author's picture keyed
/// by email when the commit itself is still only on this machine. A miss
/// draws initials.
struct HistoryAvatarIndex: Codable, Sendable, Equatable {
    var byCommit: [String: String] = [:]
    var byEmail: [String: String] = [:]

    static let empty = HistoryAvatarIndex()

    /// The picture for one row, or nil when the row should draw initials.
    ///
    /// Keys are matched without regard to case. Only `https` forge URLs are
    /// accepted. The account picture is the one the host already resolved for
    /// this sign-in, so it is not put through that check again.
    func url(commitID: String, email: String?, mine: Bool, accountAvatar: String?) -> String? {
        if mine, let own = Self.present(accountAvatar) { return own }
        if let hit = Self.secure(byCommit, commitID) { return hit }
        if let hit = Self.secure(byEmail, email) { return hit }
        return nil
    }

    /// Drop blank keys and anything that is not an `https` URL, and fold the
    /// keys to lower case so a later lookup is one read.
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
