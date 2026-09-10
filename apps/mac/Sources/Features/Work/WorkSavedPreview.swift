// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Small attachment previews share the sealed work cache and its account,
/// folder, expiry and deletion boundaries. Missing bytes never trigger a peer
/// request while a saved conversation is being read.
enum WorkSavedPreview {
    static let maximumBytes = 256 * 1024
    struct Payload: Codable, Sendable {
        let reference: WorkReference
        let attachmentID: String
        let title: String
        let capturedAt: Date
        let data: Data
    }
    struct Record: Decodable, Sendable {
        let scope: String
        let id: String
        let kind: String
        let itemId: String
        let payload: Payload
    }

    static func recordID(reference: WorkReference, attachment: String) -> String? {
        guard reference.kind == .conversation, let conversation = reference.itemID,
              !attachment.isEmpty else { return nil }
        return ["preview", reference.hostIdentity, reference.workspaceID, conversation, attachment]
            .map(WorkReferenceKey.encode).joined(separator: "|")
    }

    static func reference(recordID: String, scope: WorkReference.Scope) -> WorkReference? {
        let fields = recordID.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[0] == "preview" else { return nil }
        let values = fields.compactMap { String($0).removingPercentEncoding }
        guard values.count == 5, values.allSatisfy({ !$0.isEmpty }) else { return nil }
        let ref = WorkReference(scope: scope, hostIdentity: values[1], workspaceID: values[2],
                                kind: .conversation, itemID: values[3])
        return self.recordID(reference: ref, attachment: values[4]) == recordID ? ref : nil
    }

    @MainActor static func read(reference: WorkReference, attachment: String) async -> Data? {
        let scope = WorkCache.scope(for: reference.scope)
        guard WorkCacheAccess.canRead(reference),
              let id = recordID(reference: reference, attachment: attachment),
              let key = WorkCacheKey.existingKey(for: scope),
              let record = try? await Bridge.savedPreview(key: WorkCacheKey.encoded(key), scope: scope, id: id),
              WorkCacheAccess.canRead(reference), !Task.isCancelled,
              record.scope == scope, record.id == id, record.kind == "attachment", record.itemId == attachment,
              record.payload.reference == reference, record.payload.attachmentID == attachment,
              !record.payload.data.isEmpty, record.payload.data.count <= maximumBytes else { return nil }
        return record.payload.data
    }

    @MainActor static func save(reference: WorkReference, attachment: ChatAttachment, data: Data) async {
        guard WorkCacheAccess.canSave(reference), !Task.isCancelled,
              WorkCacheSettings.shared.saves(reference), !data.isEmpty, data.count <= maximumBytes,
              let id = recordID(reference: reference, attachment: attachment.id) else { return }
        let scope = WorkCache.scope(for: reference.scope)
        let payload = Payload(reference: reference, attachmentID: attachment.id, title: attachment.name,
                              capturedAt: Date(), data: data)
        guard let key = WorkCacheKey.key(for: scope), let encoded = try? JSONEncoder().encode(payload),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return }
        _ = try? await Bridge.cachePut(key: WorkCacheKey.encoded(key), scope: scope, id: id,
                                     kind: "attachment", itemId: attachment.id, revision: nil, payload: object)
    }
}
