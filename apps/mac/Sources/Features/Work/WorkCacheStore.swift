// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Encrypted copies of opened work, kept on this device.
///
/// Best effort by design: a copy that cannot be sealed (no keychain, no
/// settings, an older helper, a full disk) simply does not exist, and the
/// conversation still opens live. Nothing here throws past the caller, and
/// nothing here reaches a peer: every call rides the local transport, and the
/// host refuses these methods to a machine asking over the tunnel.
///
/// What is kept is the newest page of an opened conversation, with the title
/// it had when it was saved. Earlier pages stay on the host; the copy carries
/// the page's own `hasEarlier` flag so the reader says so honestly.
final class WorkCacheStore {
    static let shared = WorkCacheStore()
    private let settings: WorkCacheSettings

    init(settings: WorkCacheSettings = .shared) { self.settings = settings }

    /// Whether the host on this transport can keep copies at all. An older
    /// helper refuses with `unknown_method`, which is unavailability rather
    /// than emptiness: the caller keeps the live conversation and tries
    /// again another time.
    static func isUnavailable(_ error: Error) -> Bool {
        if case let BridgeError.core(code, _) = error { return code == "unknown_method" }
        return false
    }

    /// Keep this conversation's newest page under the scope's key.
    func saveConversation(reference: WorkReference, title: String, page: ChatEventPage, backend: String? = nil) async {
        guard settings.enabled,
              let recordID = WorkCache.recordID(for: reference),
              let itemID = reference.itemID,
              let key = WorkCacheKey.key(for: WorkCache.scope(for: reference.scope)),
              let pageData = try? JSONEncoder().encode(page),
              let pageObject = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any]
        else { return }
        let revision = WorkCache.revision(
            maxSeq: page.events.compactMap(\.seq).max() ?? 0,
            count: page.events.count, nextOffset: page.nextOffset
        )
        guard var payload = try? WorkCache.encode(title: title, revision: revision, page: pageObject),
              (try? WorkCache.decode(payload)) != nil
        else { return }
        if let backend { payload["backend"] = backend }
        _ = try? await Bridge.cachePut(
            key: WorkCacheKey.encoded(key), scope: WorkCache.scope(for: reference.scope),
            id: recordID, kind: "conversation", itemId: itemID,
            revision: revision, payload: payload
        )
    }

    /// Disabling future saving does not hide copies that are already kept.
    func savedConversation(for reference: WorkReference) async -> CachedRecordPayload? {
        guard let recordID = WorkCache.recordID(for: reference) else { return nil }
        let scope = WorkCache.scope(for: reference.scope)
        guard let key = WorkCacheKey.existingKey(for: scope) else { return nil }
        guard let record = try? await Bridge.cacheGet(
            key: WorkCacheKey.encoded(key), scope: scope, id: recordID
        ) else { return nil }
        return record.payload
    }

    /// Drop one conversation's copy, for a folder that has left.
    func removeConversation(for reference: WorkReference) async {
        guard let recordID = WorkCache.recordID(for: reference) else { return }
        _ = try? await Bridge.cacheRemove(scope: WorkCache.scope(for: reference.scope), id: recordID)
    }

    /// Keep or release a conversation's copy. Pinning survives age eviction
    /// inside the hard budget; unpinning hands the copy back to the ordinary
    /// quota. Folder pins carry no copy and answer nothing here.
    func setPinned(_ pinned: Bool, for reference: WorkReference) async {
        guard let recordID = WorkCache.recordID(for: reference) else { return }
        _ = try? await Bridge.cachePin(
            scope: WorkCache.scope(for: reference.scope), id: recordID, pinned: pinned
        )
    }
}
