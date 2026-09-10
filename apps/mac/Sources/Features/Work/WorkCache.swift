// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import CryptoKit

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
        guard let prefix = recordPrefix(reference.kind), let item = reference.itemID, !item.isEmpty,
              !reference.hostIdentity.isEmpty, !reference.workspaceID.isEmpty
        else { return nil }
        return [prefix, reference.hostIdentity, reference.workspaceID, item]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }

    static func reference(recordID: String, scope: WorkReference.Scope) -> WorkReference? {
        let fields = recordID.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 4, let kind = recordKind(String(fields[0])),
              let host = String(fields[1]).removingPercentEncoding, !host.isEmpty,
              let folder = String(fields[2]).removingPercentEncoding, !folder.isEmpty,
              let item = String(fields[3]).removingPercentEncoding, !item.isEmpty else { return nil }
        let reference = WorkReference(scope: scope, hostIdentity: host, workspaceID: folder,
                                      kind: kind, itemID: item)
        guard self.recordID(for: reference) == recordID else { return nil }
        return reference
    }

    private static func recordPrefix(_ kind: WorkReference.Kind) -> String? {
        switch kind {
        case .conversation: "conv"
        case .commit: "commit"
        case .savedDiff: "diff"
        default: nil
        }
    }

    private static func recordKind(_ prefix: String) -> WorkReference.Kind? {
        switch prefix {
        case "conv": .conversation
        case "commit": .commit
        case "diff": .savedDiff
        default: nil
        }
    }

    static func matches(kind: String, reference: WorkReference) -> Bool {
        kind == "conversation" && reference.kind == .conversation
            || kind == "diff" && [.commit, .savedDiff].contains(reference.kind)
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

    /// Whether a kept copy still names the live timeline. Reconnecting
    /// compares the saved revision against the fresh page's: a match means
    /// the conversation was quiet, anything else means the copy is replaced.
    static func matches(_ savedRevision: String, maxSeq: UInt64, count: Int, nextOffset: UInt64) -> Bool {
        savedRevision == revision(maxSeq: maxSeq, count: count, nextOffset: nextOffset)
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

    static let retentionChoices = [7, 30, 90]
    static let budgetChoices = [50, 100, 250, 500]
    static let offlineBudgetChoices = [100, 500, 1000]

    var retentionDays: Int {
        get { choice("work.cache.days", allowed: Self.retentionChoices, fallback: 30) }
        set { if Self.retentionChoices.contains(newValue) { defaults.set(newValue, forKey: "work.cache.days") } }
    }
    var budgetMB: Int {
        get { choice("work.cache.mb", allowed: Self.budgetChoices, fallback: 100) }
        set { if Self.budgetChoices.contains(newValue) { defaults.set(newValue, forKey: "work.cache.mb") } }
    }
    var offlineBudgetMB: Int {
        get { choice("work.cache.offline.mb", allowed: Self.offlineBudgetChoices, fallback: 500) }
        set { if Self.offlineBudgetChoices.contains(newValue) { defaults.set(newValue, forKey: "work.cache.offline.mb") } }
    }
    private func choice(_ key: String, allowed: [Int], fallback: Int) -> Int {
        let value = defaults.integer(forKey: key)
        return allowed.contains(value) ? value : fallback
    }

    func saves(_ reference: WorkReference) -> Bool {
        enabled && folderEnabled(reference)
    }

    func folderEnabled(_ reference: WorkReference) -> Bool {
        defaults.object(forKey: folderKey(reference)) as? Bool ?? true
    }

    func setFolderEnabled(_ enabled: Bool, for reference: WorkReference) {
        defaults.set(enabled, forKey: folderKey(reference))
    }

    private func folderKey(_ reference: WorkReference) -> String {
        let identity = WorkReferenceKey.folder(scope: reference.scope,
            hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "work.cache.folder.enabled." + digest
    }

    /// Nothing recorded means on: the copies exist to be opened offline, and
    /// a device that has never chosen keeps them until it says otherwise.
    var enabled: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set { defaults.set(newValue, forKey: key) }
    }
}
