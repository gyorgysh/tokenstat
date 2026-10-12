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
        print("Composer deferred Return ownership passed")
    }
}
