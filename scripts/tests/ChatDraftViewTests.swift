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
        print("Composer deferred Return ownership and command-key routing passed")
    }
}
