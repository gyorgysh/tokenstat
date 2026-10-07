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
        let huge = (0..<100_000).map { "line \($0)" }.joined(separator: "\n")
        let bounded = ChatToolState.makeSnippet(verb: "Read", detail: huge)
        precondition(bounded.count == 61 && bounded[0] == "| line 0" && bounded[59] == "| line 59")
        precondition(bounded[60] == L10n.text("apple.chatmodel.0_more.8bfcca49", "99940"))

        // Compare every shown line and the exact footer to the former
        // implementation, including empty lines and Character CRLF behavior.
        var seed: UInt64 = 19
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        let fragments = ["", "é👩🏽‍💻", "+new", "-old", "--- a/file", "+++ b/file", "\r", "\r\n", "\n", "e\u{301}"]
        for _ in 0..<500 {
            let fixture = (0..<random(180)).map { _ in fragments[random(fragments.count)] }.joined(separator: "\n")
            for verb in ["Read", "Edit", "NotebookEdit", "Diff", "Bash Input"] {
                precondition(ChatToolState.makeSnippet(verb: verb, detail: fixture) == reference(verb: verb, detail: fixture))
            }
        }
        precondition(ChatToolState.makeSnippet(verb: "Diff", detail: marks + "\n" + text) == reference(verb: "Diff", detail: marks + "\n" + text))
        print("Chat snippets: bounded allocation, 2500 exact comparisons, large output, Unicode, CRLF, empty lines and diff markers passed")
    }

    private static func reference(verb: String, detail: String) -> [String] {
        guard !detail.isEmpty else { return [] }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diff = ["Edit", "NotebookEdit", "Diff"].contains(verb)
        var out = lines.prefix(60).map { line in
            let shown = ChatToolState.clip(line)
            return diff && ChatToolState.isDiffLine(shown) ? shown : "| \(shown)"
        }
        if lines.count > 60 { out.append(L10n.text("apple.chatmodel.0_more.8bfcca49", "\(lines.count - 60)")) }
        return Array(out)
    }
}
