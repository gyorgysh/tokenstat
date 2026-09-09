// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// The wire shapes of the saved-work cache.
///
/// Every property spells its key the way the host's `work_cache` writes it
/// (`itemId`, `createdMs`), because the host derives keys as camelCase and a
/// synthesized `…ID` key would ask for one nothing sends.
struct CacheRecordMeta: Decodable, Sendable {
    var scope: String
    var id: String
    var kind: String
    var itemId: String
    var revision: String?
    var bytes: UInt64
    var createdMs: Int64
    var updatedMs: Int64
    var pinned: Bool
}

struct CachePutResult: Decodable, Sendable {
    var id: String
    var bytes: UInt64
    var evicted: [String]
    var repaired: Bool
}

struct CachedRecordPayload: Decodable, Sendable {
    var backend: String?
    var title: String
    var savedAt: Date
    var revision: String
    var page: ChatEventPage

    enum CodingKeys: String, CodingKey { case backend, title, savedAt, revision, page }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decodeIfPresent(String.self, forKey: .backend)
        title = try values.decode(String.self, forKey: .title)
        revision = try values.decode(String.self, forKey: .revision)
        page = try values.decode(ChatEventPage.self, forKey: .page)
        let timestamp = try values.decode(String.self, forKey: .savedAt)
        guard let date = ISO8601DateFormatter().date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(forKey: .savedAt, in: values,
                debugDescription: "Saved work timestamp is not ISO 8601")
        }
        savedAt = date
    }
}

struct CachedRecord: Decodable, Sendable {
    var scope: String
    var id: String
    var kind: String
    var itemId: String
    var revision: String?
    var bytes: UInt64
    var createdMs: Int64
    var updatedMs: Int64
    var pinned: Bool
    var payload: CachedRecordPayload
}

struct CacheListResult: Decodable, Sendable {
    var records: [CacheRecordMeta]
    var repaired: Bool
}

struct CacheStatsResult: Decodable, Sendable {
    var bytes: UInt64
    var records: UInt64
    var pinned: UInt64
    var pinnedBytes: UInt64
    var repaired: Bool
}

struct CacheRemoveResult: Decodable, Sendable {
    var removed: Bool
    var repaired: Bool
}

struct CachePinResult: Decodable, Sendable {
    var pinned: Bool
    var repaired: Bool
}

struct CacheClearResult: Decodable, Sendable {
    var removed: UInt64
    var repaired: Bool
}

/// What the transcript is showing when the machine cannot be reached.
///
/// Identifiers and timestamps only: the rows themselves live in the model's
/// events, read from the sealed copy. Nil is the ordinary case, a live
/// conversation, and the only state that can send, approve or fetch.
struct SavedCopyInfo: Sendable, Equatable {
    var title: String
    var savedAt: Date
    /// The saved page said earlier pages exist on the host. They are not in
    /// the copy, and the reader is told so rather than shown a start marker.
    var hasEarlier: Bool
    var revision: String
}
