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
            Text("This file changed on that computer.")
                .font(ClientType.label.weight(.semibold))
            Text(summary)
                .font(ClientType.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Reload computer", .restore, role: .destructive) { onReload() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                Button("Keep my draft", .edit) { onKeep() }
                    .buttonStyle(AccentButtonStyle(small: true))
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This file changed on that computer. \(summary)")
    }

    private var summary: String {
        let mine = document.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let theirs = hostContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        var parts = "Yours has \(mine) lines, that computer has \(theirs). Saving is off until you choose."
        if let first = firstDifference {
            parts += " First difference: line \(first)."
        }
        return parts
    }
}
#endif
