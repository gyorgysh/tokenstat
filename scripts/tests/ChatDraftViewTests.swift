// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatDraftView.swift.
import AppKit
import SwiftUI
struct WorkReference: Equatable { let id: String }
enum Theme { static let accent = Color.green }
enum ChatInbox { static func pasteboardHasAttachment() -> Bool { false } }
@main struct ChatDraftViewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var sends: [String] = []
        let coordinator = ChatDraftView.Coordinator(text: .constant("draft"), selection: .constant(NSRange(location: 0, length: 0)),
            owner: WorkReference(id: "first"), onSend: { sends.append("first") }, onStop: {})
        coordinator.requestSend()
        coordinator.owner = WorkReference(id: "second")
        coordinator.onSend = { sends.append("second") }
        try await Task.sleep(for: .milliseconds(20))
        assert(sends.isEmpty, "deferred Return must not send the newly selected conversation")
        coordinator.requestSend()
        coordinator.requestSend()
        try await Task.sleep(for: .milliseconds(20))
        assert(sends == ["second"], "same-owner Return remains coalesced")
        let editor = ChatDraftTextView()
        var stops = 0
        var keys: [UInt16] = []
        editor.draftStop = { stops += 1 }
        editor.commandKey = { key in keys.append(key); return true }
        func press(_ key: UInt16) {
            editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!)
        }
        press(125)
        press(53)
        assert(keys == [125, 53] && stops == 0, "command navigation and dismissal must consume the editor key")
        editor.commandKey = { _ in false }
        press(53)
        assert(stops == 1, "Escape outside the command menu still stops the turn")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.tokenstat.draft-drop-tests." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        let fileURL = URL(fileURLWithPath: "/temporary-screenshot.png").absoluteString
        first.setString(fileURL, forType: .fileURL)
        first.setData(Data([1, 2, 3]), forType: .png)
        let privateType = NSPasteboard.PasteboardType("ai.tokenstat.test.unsupported-file-contents")
        first.setData(Data([9]), forType: privateType)
        second.setData(Data([4, 5]), forType: .tiff)
        pasteboard.writeObjects([first, second])
        let providers = ChatDraftTextView.attachmentProviders(from: pasteboard)
        pasteboard.clearContents()
        assert(providers.count == 2, "A native drop must preserve every dragged item")
        assert(providers[0].registeredTypeIdentifiers.contains("public.file-url")
            && providers[0].registeredTypeIdentifiers.contains("public.png"), "Transient screenshots retain URL and pixel alternatives")
        assert(!providers[0].registeredTypeIdentifiers.contains(privateType.rawValue), "Private representations must not be eagerly materialized")
        func bytes(_ provider: NSItemProvider, type: NSPasteboard.PasteboardType) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.rawValue) { data, _ in continuation.resume(returning: data) }
            }
        }
        let png = await bytes(providers[0], type: .png)
        let tiff = await bytes(providers[1], type: .tiff)
        assert(png == Data([1, 2, 3]) && tiff == Data([4, 5]), "Drop snapshots must survive the source pasteboard being cleared")
        assert(!editor.acceptsAttachmentDrops, "Standalone editors must opt into attachment routing")
        print("Composer deferred Return, command keys and native multi-item screenshot drop snapshots passed")
    }
}
