// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum L10n { static func text(_ key: String) -> String { key } }

@main struct OutboxStoreReference {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        let store = ChatOutboxStore(directory: URL(fileURLWithPath: arguments[2]))
        let reference = WorkReference(scope: .local(installationID: "fixture"), hostIdentity: "host", workspaceID: "folder", kind: .conversation, itemID: "chat")
        switch arguments[1] {
        case "write":
            try store.update(reference) { items in
                items.append(ChatQueuedMessage(id: "swift", text: "Swift / café 🦊", attachments: [ChatAttachment(id: "file-swift", name: "two.txt", mediaType: "text/plain", size: 43)], delivery: .sending, firstAttemptAt: Date(timeIntervalSinceReferenceDate: 125.5), attemptedAt: Date(timeIntervalSinceReferenceDate: 126), expectedRevision: 7, whenConnected: false, sourceDraftText: "Swift / café 🦊"))
            }
        case "accept":
            guard let sent = try store.items(for: reference).first(where: { $0.id == "rust" }) else { fatalError("missing message") }
            try store.accept(sent, revision: 8, for: reference)
        case "read":
            let data = try JSONEncoder().encode(store.items(for: reference))
            print(String(decoding: data, as: UTF8.self))
        default: fatalError("unknown command")
        }
    }
}
