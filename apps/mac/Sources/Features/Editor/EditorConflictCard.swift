// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// The host file moved while the draft was dirty. Saving stays off until
/// the person chooses a copy: reload adopts the host and clears the draft,
/// keeping writes the draft through explicitly.
struct EditorConflictCard: View {
    let document: EditorDocument
    let hostContent: String
    var onReload: () -> Void
    var onKeep: () -> Void

    private var firstDifference: Int? {
        EditorDocument.firstDifference(between: document.text, and: hostContent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.editorconflictcard.this_file_changed_on_that_computer.c4576a6e"))
                .font(ClientType.label.weight(.semibold))
            Text(summary)
                .font(ClientType.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("apple.editorconflictcard.reload_computer.2bdc7487"), .restore, role: .destructive) { onReload() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Button(L10n.text("apple.editorconflictcard.keep_my_draft.cdb80bb9"), .edit) { onKeep() }
                    .buttonStyle(AccentButtonStyle(small: true))
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.editorconflictcard.this_file_changed_on_that_computer_0.087ee47e", "\(summary)"))
    }

    private var summary: String {
        let mine = document.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let theirs = hostContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        var parts = L10n.text("apple.editorconflictcard.yours_has_0_lines_that_computer_has_1_savi.66339948", "\(mine)", "\(theirs)")
        if let first = firstDifference {
            parts += L10n.text("apple.editorconflictcard.first_difference_line_0.42e7b04c", "\(first)")
        }
        return parts
    }
}
#endif
