// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A focused code editor for one workspace file.
///
/// A real editor, and deliberately not an IDE: syntax colour, line numbers, the
/// system find bar, indentation, bracket pairing, a comment toggle, and marks
/// in the gutter for what changed. No language server, no completion, no
/// refactoring. The terminal beside it is where the work happens, and this is
/// for the focused change you do not want to open another application for.
///
/// Saving is always explicit. Nothing here writes on a timer or on focus loss.
struct EditorView: View {
    @Bindable var model: WorkspacesModel
    let folder: WorkspaceFolder
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.editorError {
                Banner(text: error, severity: .danger)
            }

            #if os(macOS)
            if let document = model.document(for: path, in: folder.id) {
                CodeTextView(document: document) {
                    Task { await model.saveText(path, in: folder.id) }
                }
                .background(Theme.background)
                statusLine(document)
            } else {
                loading
            }
            #else
            loading
            #endif
        }
        .background(Theme.background)
    }

    private var loading: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    #if os(macOS)
    /// Path, language, unsaved state, and the Save button.
    ///
    /// The language sits here rather than in the tab because it is only ever
    /// interesting when the colours look wrong, and this is where you look then.
    private func statusLine(_ document: EditorDocument) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(path)
                .font(Theme.mono(11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)

            if document.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .imageScale(.small)
                    .foregroundStyle(Theme.warning)
            }

            if let note = document.highlightNote {
                // Not an error. "No grammar for this file type" is a normal
                // thing for a text file to be, and the file still edits and
                // saves. It belongs here in grey, not in a banner in red.
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if !document.changedLines.isEmpty {
                Text("\(document.changedLines.count) changed")
                    .font(Theme.numeric(11))
                    .foregroundStyle(.tertiary)
            }

            Button("Save") {
                Task { await model.saveText(path, in: folder.id) }
            }
            .disabled(!document.isDirty)
            .keyboardShortcut("s")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
    #endif
}
