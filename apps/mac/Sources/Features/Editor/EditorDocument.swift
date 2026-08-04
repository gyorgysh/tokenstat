// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// One file open in the editor.
///
/// A document rather than a pair of dictionary entries keyed by path, which is
/// what this was. The difference matters once a file has highlighting, a saved
/// copy to compare against, changed-line marks and an in-flight highlight task:
/// that is five dictionaries keyed the same way, and they go out of step one at
/// a time.
///
/// This lives in the model and never in view state. The workspace file watcher
/// rebuilds the workspace views on every save, and during a build that is
/// several times a second, so a document held as `@State` would lose its
/// unsaved text to a `cargo build` in another window.
@Observable
@MainActor
final class EditorDocument: Identifiable {
    let id: String
    let workspaceID: String
    let path: String

    /// What is on screen. The text view owns the live editing and pushes here.
    private(set) var text: String
    /// What was last read from or written to disk. Dirty is the difference
    /// between the two, so undoing back to the original correctly stops
    /// reporting the file as unsaved.
    private(set) var savedText: String

    private(set) var spans: [SyntaxSpan] = []
    private(set) var rules: SyntaxRules = .fallback
    /// Why the file is not coloured, when it is not. Shown quietly in the
    /// status line rather than as an error.
    private(set) var highlightNote: String?
    /// Bumped whenever `spans` is replaced, so the text view can tell a new
    /// answer from a redraw without comparing arrays.
    private(set) var spansVersion = 0

    /// Lines with changes against HEAD, one-based, for the gutter marks.
    private(set) var changedLines: Set<Int> = []

    var isDirty: Bool { text != savedText }

    private var highlightTask: Task<Void, Never>?

    init(workspaceID: String, path: String, content: String) {
        self.id = "\(workspaceID):\(path)"
        self.workspaceID = workspaceID
        self.path = path
        self.text = content
        self.savedText = content
    }

    /// The text view reporting an edit.
    func setText(_ next: String) {
        guard next != text else { return }
        text = next
        scheduleHighlight()
    }

    /// Re-read from disk landed, or a save completed.
    func adopt(saved content: String) {
        text = content
        savedText = content
        scheduleHighlight()
    }

    func markSaved() {
        savedText = text
    }

    /// Colour the buffer, once it stops changing.
    ///
    /// Debounced rather than run per keystroke: highlighting is a parse of the
    /// whole file and a round trip across the bridge, and at 60 keystrokes a
    /// minute nobody sees the difference between now and 40 ms from now. The
    /// previous task is cancelled, so holding a key down costs one parse and
    /// not one per character.
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
            // The buffer may have moved on while this was in flight. Applying
            // spans measured against older text colours the wrong ranges, which
            // looks like a highlighter bug rather than a stale result.
            guard source == text else { return }
            spans = result.spans
            rules = result.rules
            highlightNote = result.note
            spansVersion += 1
        } catch {
            // Colour is not worth an error banner. The file is still editable
            // and still saveable without it.
            spans = []
            highlightNote = error.localizedDescription
            spansVersion += 1
        }
    }

    /// Take the changed-line marks from a diff the app already parsed.
    ///
    /// Reuses `workspace.diff` rather than diffing again: the Changes panel and
    /// the gutter must not be able to disagree about what changed.
    func applyDiff(_ diff: FileDiff?) {
        guard let diff else {
            changedLines = []
            return
        }
        var lines: Set<Int> = []
        for hunk in diff.hunks {
            // Added lines only. A removed line has no number on the new side,
            // so there is no row in this buffer to mark: what it leaves behind
            // is a gap between two numbers, which the Changes panel shows and a
            // gutter cannot.
            for line in hunk.lines where line.kind == .added {
                if let number = line.newLine {
                    lines.insert(Int(number))
                }
            }
        }
        changedLines = lines
    }
}
