// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatDisplayItem.swift ChatQuestion.swift ChatTranscriptFold.swift.
import Foundation

struct ChatAttachment: Hashable { let id: String }
struct ChatApproval: Hashable { let id: String }

@main enum ChatSnippetTests {
    static func main() {
        precondition(ChatToolState.clip("é👩🏽‍💻") == "é👩🏽‍💻")
        let text = String(repeating: "x", count: 5_000_000)
        let clipped = ChatToolState.clip(text)
        precondition(clipped.count == 601 && clipped.hasSuffix("…"))
        let marks = "e" + String(repeating: "\u{301}", count: 100_000)
        precondition(ChatToolState.clip(marks).unicodeScalars.count <= 2_401)
        let shown = ChatToolState.makeSnippet(verb: "Diff", detail: "+ " + text)
        precondition(shown.count == 1 && shown[0].count <= 601 && shown[0].hasPrefix("+"))
        precondition(text.utf8.count == 5_000_000, "render clipping must not mutate source for Copy")
        print("Chat snippets: multi-megabyte lines, Unicode text, hostile graphemes and diff markers passed")
    }
}
