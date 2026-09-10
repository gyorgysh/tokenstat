// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// These records predate host/account ownership. They are local recovery
/// material only: no reference is inferred and no outbox adopts them.
enum ChatLegacyQueueStore {
    private static let prefix = "chat.queuedMessages.v1."
    struct Message: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let attachments: [ChatAttachment]
    }
    struct Draft: Identifiable, Sendable {
        let storageKey: String
        let message: Message
        var id: String { storageKey + "|" + message.id }
    }
    struct Listing {
        var drafts: [Draft] = []
        var unreadable = 0
    }

    static func list(defaults: UserDefaults = .standard) -> Listing {
        var listing = Listing()
        for key in defaults.dictionaryRepresentation().keys.filter({ $0.hasPrefix(prefix) }).sorted() {
            guard let data = defaults.data(forKey: key), data.count <= 8 * 1024 * 1024,
                  let messages = try? JSONDecoder().decode([Message].self, from: data),
                  messages.count <= 20, Set(messages.map(\.id)).count == messages.count else {
                listing.unreadable += 1
                continue
            }
            listing.drafts += messages.map { Draft(storageKey: key, message: $0) }
        }
        return listing
    }

    /// Only an explicit Remove action deletes a matching legacy copy. A newer
    /// edit in an older window is left untouched rather than overwritten.
    static func remove(_ draft: Draft, defaults: UserDefaults = .standard) throws {
        guard draft.storageKey.hasPrefix(prefix), let data = defaults.data(forKey: draft.storageKey),
              data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        var messages = try JSONDecoder().decode([Message].self, from: data)
        guard messages.contains(draft.message) else { throw CocoaError(.fileWriteUnknown) }
        messages.removeAll { $0 == draft.message }
        if messages.isEmpty { defaults.removeObject(forKey: draft.storageKey) }
        else { defaults.set(try JSONEncoder().encode(messages), forKey: draft.storageKey) }
    }
}
