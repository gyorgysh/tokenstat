// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// The keys, revisions and envelopes that file saved work under. Pure
/// Foundation, so the standalone tests pin the contract without a bridge, a
/// keychain or a daemon.
///
/// A scope is the account (or the local installation), shared by every folder
/// on every machine under it: signing out removes one scope and takes exactly
/// that account's copies with it. A record id names the machine, the folder
/// and the conversation inside that scope.
/// A sealed envelope as the reader sees it, before the page inside is
/// re-decoded into the timeline type.
struct WorkCachedEnvelope: Sendable {
    var title: String
    var savedAt: Date
    var revision: String
    var page: [String: Any]
}

enum WorkCache {
    /// One record per conversation: its newest page, which is what an offline
    /// open shows. Earlier pages stay on the host; the copy says so.
    static func recordID(for reference: WorkReference) -> String? {
        guard reference.kind == .conversation, let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty
        else { return nil }
        return ["conv", reference.hostIdentity, reference.workspaceID, item]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }

    static func scope(for scope: WorkReference.Scope) -> String {
        [scope.kind.rawValue, scope.origin, scope.identity]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }

    /// What timeline a page came from: the highest archive position in it,
    /// how many rows it carries, and where live tailing carries on from. Two
    /// pages with the same revision show the same conversation.
    static func revision(maxSeq: UInt64, count: Int, nextOffset: UInt64) -> String {
        "s\(maxSeq):\(count):\(nextOffset)"
    }

    static func encode(title: String, revision: String, page: [String: Any],
                       at date: Date = Date()) throws -> [String: Any] {
        let envelope: [String: Any] = [
            "title": title,
            "savedAt": ISO8601DateFormatter().string(from: date),
            "revision": revision,
            "page": page,
        ]
        // Round through data so only JSON values can leave: a non-plist type
        // fails here rather than in the transport's serializer.
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkCacheError.encoding
        }
        return object
    }

    static func decode(_ payload: [String: Any]) throws -> WorkCachedEnvelope {
        guard let title = payload["title"] as? String,
              let savedAtString = payload["savedAt"] as? String,
              let savedAt = ISO8601DateFormatter().date(from: savedAtString),
              let revision = payload["revision"] as? String,
              let page = payload["page"] as? [String: Any]
        else { throw WorkCacheError.encoding }
        return WorkCachedEnvelope(title: title, savedAt: savedAt, revision: revision, page: page)
    }
}

enum WorkCacheError: Error {
    case encoding
}

/// Whether this device keeps encrypted copies of opened work.
///
/// On with a first-use explanation where the copies are managed; off means
/// nothing new is saved and previously kept copies stay until cleared there.
/// A separate durable setting from the copies themselves, so turning saving
/// off does not delete what is already kept.
final class WorkCacheSettings {
    static let shared = WorkCacheSettings()
    private let defaults: UserDefaults
    private let key = "work.cache.enabled.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Nothing recorded means on: the copies exist to be opened offline, and
    /// a device that has never chosen keeps them until it says otherwise.
    var enabled: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key) }
    }
}
