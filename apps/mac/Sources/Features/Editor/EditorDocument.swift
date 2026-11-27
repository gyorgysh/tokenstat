// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

@Observable
@MainActor
final class EditorDocument: Identifiable {
    let id: String
    let workspaceID: String
    let path: String

    private(set) var text: String
    private(set) var savedText: String

    private(set) var spans: [SyntaxSpan] = []
    private(set) var rules: SyntaxRules = .fallback
    private(set) var highlightNote: String?
    private(set) var spansVersion = 0

    private(set) var changedLines: Set<Int> = []

    var isDirty: Bool { text != savedText }
    private(set) var savedAt: Date?

    private var highlightTask: Task<Void, Never>?

    init(workspaceID: String, path: String, content: String) {
        self.id = "\(workspaceID):\(path)"
        self.workspaceID = workspaceID
        self.path = path
        self.text = content
        self.savedText = content
    }

    func setText(_ next: String) {
        guard next != text else { return }
        text = next
        if isDirty { savedAt = nil }
        scheduleHighlight()
    }

    func adopt(saved content: String) {
        text = content
        savedText = content
        savedAt = nil
        scheduleHighlight()
    }

    func markSaved(content: String? = nil) {
        savedText = content ?? text
        if !isDirty { savedAt = Date() }
    }

    static func firstDifference(between mine: String, and other: String) -> Int? {
        if mine == other { return nil }
        let mineLines = mine.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let otherLines = other.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, pair) in zip(mineLines, otherLines).enumerated() {
            if pair.0 != pair.1 { return index + 1 }
        }
        return min(mineLines.count, otherLines.count) + 1
    }

    @ObservationIgnored var selection = NSRange(location: 0, length: 0)

    func scheduleHighlight() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            await self?.highlightNow()
        }
    }

    func highlightNow() async {
        let source = text
        do {
            let result = try await Bridge.highlight(path: path, text: source)
            guard source == text else { return }
            spans = result.spans
            rules = result.rules
            highlightNote = result.note
            spansVersion += 1
        } catch {
            spans = []
            highlightNote = error.localizedDescription
            spansVersion += 1
        }
    }

    func applyDiff(_ diff: FileDiff?) {
        guard let diff else {
            changedLines = []
            return
        }
        var lines: Set<Int> = []
        for hunk in diff.hunks {
            for line in hunk.lines where line.kind == .added {
                if let number = line.newLine {
                    lines.insert(Int(number))
                }
            }
        }
        changedLines = lines
    }
}
