#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check production file-opening guards against stale navigation and access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
client = (root / "apps/mac/Sources/Client/ClientChatView.swift").read_text()
gallery = (root / "apps/mac/Sources/Features/Workspaces/Chat/ChatImageGallery.swift").read_text()
card = (root / "apps/mac/Sources/Features/Workspaces/Chat/ChatEventRow.swift").read_text()
card_guard = card[card.index("    private func canFinishOpening("):
                  card.index("    private func open()", card.index("    private func canFinishOpening("))]
assert "canUse: { canFinishOpening(ticket) }" in card
assert "guard !Task.isCancelled, canFinishOpening(ticket) else { return }" in card
client_guard = client[client.index("    private func canOpen(_ request: PendingFileOpen)"):
                      client.index("    private func prepareFileOpen(")]
gallery_guard = gallery[gallery.index("    private func canPerform(_ action: FileAction)"):
                        gallery.index("    private func sourceFile(_ action:")]
support = r'''
import Foundation
@MainActor enum WorkCacheAccess {
    static var permitted = true
    static func canRead(_ reference: String) -> Bool { permitted }
}
@MainActor final class Model {
    var currentReference: String? = "account-a/host-a/chat-a"
    var selectionGeneration: UInt64 = 2
}
@MainActor final class Navigation { var stackGeneration: UInt64 = 3 }
struct Attachment { var id = "attachment-a" }
struct Resource { var available = true }
struct PendingFileOpen {
    var id = UUID()
    var reference = "account-a/host-a/chat-a"
    var generation: UInt64 = 2
    var navigationGeneration: UInt64 = 3
}
struct FileAction {
    var id = UUID()
    var attachment = Attachment()
    var reference = "account-a/host-a/chat-a"
    var generation: UInt64 = 2
}
@MainActor final class ClientPolicy {
    let model = Model(), navigation = Navigation()
    var isActive = true
    var pendingFileOpen: PendingFileOpen?
CLIENT_GUARD
    func allows(_ request: PendingFileOpen) -> Bool { canOpen(request) }
}
@MainActor final class GalleryPolicy {
    let model = Model()
    var fileAction: FileAction?
    var attachment = Attachment(), resource = Resource()
GALLERY_GUARD
    func allows(_ action: FileAction) -> Bool { canPerform(action) }
}
@MainActor final class CardPolicy {
    var opening: UUID?
    var permitted = true
    func canOpen() -> Bool { permitted }
CARD_GUARD
    func allows(_ ticket: UUID) -> Bool { canFinishOpening(ticket) }
}
@main enum FileOpeningTests {
    @MainActor static func main() {
        let request = PendingFileOpen(), action = FileAction()
        let client = ClientPolicy(); client.pendingFileOpen = request
        let gallery = GalleryPolicy(); gallery.fileAction = action
        precondition(client.allows(request) && gallery.allows(action))

        func rejectsClient(_ mutate: (ClientPolicy) -> Void) {
            let policy = ClientPolicy(); policy.pendingFileOpen = request
            mutate(policy)
            precondition(!policy.allows(request), "A stale file request must not open a preview")
        }
        rejectsClient { $0.isActive = false }
        rejectsClient { $0.pendingFileOpen = nil }
        rejectsClient { $0.pendingFileOpen = PendingFileOpen() }
        rejectsClient { $0.model.currentReference = nil }
        rejectsClient { $0.model.currentReference = "account-b/host-a/chat-a" }
        rejectsClient { $0.model.currentReference = "account-a/host-b/chat-a" }
        rejectsClient { $0.model.currentReference = "account-a/host-a/chat-b" }
        rejectsClient { $0.model.selectionGeneration += 1 }
        rejectsClient { $0.navigation.stackGeneration += 1 }

        func rejectsGallery(_ mutate: (GalleryPolicy) -> Void) {
            let policy = GalleryPolicy(); policy.fileAction = action
            mutate(policy)
            precondition(!policy.allows(action), "A stale image action must not open or save a file")
        }
        rejectsGallery { $0.fileAction = nil }
        rejectsGallery { $0.fileAction = FileAction() }
        rejectsGallery { $0.attachment.id = "attachment-b" }
        rejectsGallery { $0.resource.available = false }
        rejectsGallery { $0.model.currentReference = nil }
        rejectsGallery { $0.model.currentReference = "account-b/host-a/chat-a" }
        rejectsGallery { $0.model.currentReference = "account-a/host-b/chat-a" }
        rejectsGallery { $0.model.currentReference = "account-a/host-a/chat-b" }
        rejectsGallery { $0.model.selectionGeneration += 1 }

        WorkCacheAccess.permitted = false
        precondition(!client.allows(request) && !gallery.allows(action), "Revoked access blocks completed work")
        WorkCacheAccess.permitted = true
        precondition(client.allows(request) && gallery.allows(action), "Current readable files remain available")
        let card = CardPolicy(), ticket = UUID()
        card.opening = ticket
        precondition(card.allows(ticket))
        card.opening = nil
        precondition(!card.allows(ticket), "A cleared card cannot open before task cancellation is delivered")
        card.opening = UUID()
        precondition(!card.allows(ticket), "An older completion cannot open a replacement request")
        card.opening = ticket; card.permitted = false
        precondition(!card.allows(ticket), "Current tickets still need access")
        print("File opening: current tickets allowed; cleared/replaced card, stale navigation, image, owner and access refused")
    }
}
'''.replace("CLIENT_GUARD", client_guard).replace("GALLERY_GUARD", gallery_guard).replace("CARD_GUARD", card_guard)

with tempfile.TemporaryDirectory(prefix="tokenstat-file-opening-") as directory:
    work = Path(directory)
    source = work / "FileOpening.swift"
    source.write_text(support)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source),
                    "-o", str(work / "test")], check=True)
    subprocess.run([str(work / "test")], check=True)
