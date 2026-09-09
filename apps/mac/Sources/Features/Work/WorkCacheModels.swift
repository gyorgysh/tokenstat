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
    var title: String
    var savedAt: Date
    var revision: String
    var page: ChatEventPage
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
