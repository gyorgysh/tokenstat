// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Feeds the gutter's change marks from the same diff the Changes panel
/// parsed, so the two cannot disagree. Reloads when the file opens and
/// whenever its dirty state settles after a save.
struct EditorChangedLines: ViewModifier {
    let peer: String
    let workspace: String
    let document: EditorDocument

    func body(content: Content) -> some View {
        content
            .task(id: document.id) { await reload() }
            .onChange(of: document.isDirty) { _, dirty in
                if !dirty { Task { await reload() } }
            }
    }

    private func reload() async {
        #if WORKBENCH_QA
        if ProcessInfo.processInfo.environment["WORKBENCH_CHANGED"] == "1" {
            document.applyDiff(FileDiffFixture.changed)
            return
        }
        #endif
        guard let diff = try? await ClientRemote.diff(
            peer: peer,
            workspace: workspace,
            path: document.path
        ) else {
            document.applyDiff(nil)
            return
        }
        document.applyDiff(diff)
    }
}

extension View {
    func editorChangedLines(peer: String, workspace: String, document: EditorDocument) -> some View {
        modifier(EditorChangedLines(peer: peer, workspace: workspace, document: document))
    }
}

#if WORKBENCH_QA
/// Deterministic added lines for the gutter capture. No host involved.
enum FileDiffFixture {
    static var changed: FileDiff {
        try! JSONDecoder().decode(FileDiff.self, from: Data(
            """
            {"path":"Sources/Tokenizer.swift","binary":false,"untracked":false,"hunks":[
            {"header":"@@ -1,6 +1,9 @@","lines":[
            {"kind":"context","oldLine":1,"newLine":1,"text":"// Tokenizer"},
            {"kind":"context","oldLine":2,"newLine":2,"text":"//"},
            {"kind":"added","newLine":3,"text":"// A token is a word."},
            {"kind":"added","newLine":4,"text":"//"},
            {"kind":"context","oldLine":3,"newLine":5,"text":"// punctuation."},
            {"kind":"context","oldLine":4,"newLine":6,"text":"import Foundation"},
            {"kind":"context","oldLine":5,"newLine":7,"text":""},
            {"kind":"context","oldLine":6,"newLine":8,"text":"struct Tokenizer {"},
            {"kind":"added","newLine":9,"text":"    let text: String"}]}]}
            """.utf8
        ))
    }
}
#endif
#endif
