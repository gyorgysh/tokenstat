// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Search exactly the readable transcript blocks. Coalescing is shared with
/// the transcript, so a match in streamed assistant text opens the same row
/// the reader sees rather than an individual transport delta.
enum WorkSearchConversation {
    static func documents(reference: WorkReference, payload: CachedRecordPayload,
                          folderName: String, machineName: String) -> [WorkSearchIndex.Document] {
        guard reference.kind == .conversation, WorkReferenceKey.conversation(reference) != nil else { return [] }
        var root = reference
        root.anchor = nil
        func document(_ reference: WorkReference, text: String) -> WorkSearchIndex.Document {
            .init(reference: reference, revision: payload.revision, title: payload.title, text: text,
                  folderName: folderName, machineName: machineName, updatedAt: payload.savedAt,
                  partial: payload.page.hasEarlier)
        }
        var result = [document(root, text: "")]
        for row in ChatDisplayItem.coalesce(payload.page.events, defaultBackend: payload.backend, running: false) {
            guard ChatReadingMark.isStable(eventID: row.id) else { continue }
            let text: String
            switch row.kind {
            case .user(let value), .assistant(let value, _), .thinking(let value): text = value
            case .handoff(_, let brief): text = brief
            default: continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var anchored = root
            anchored.anchor = row.id
            result.append(document(anchored, text: text))
        }
        return result
    }
}
