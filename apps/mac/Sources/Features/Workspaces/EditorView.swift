// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// A deliberately small code editor for the selected workspace file.
///
/// It is a text editor, not a language-server IDE. The terminal remains the
/// main work surface, while this gives a user a safe place to make a focused
/// change and explicitly save it back into the chosen workspace.
struct EditorView: View {
    @Bindable var model: WorkspacesModel
    let folder: WorkspaceFolder
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.editorError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .background(.red.opacity(0.08))
            }

            TextEditor(text: Binding(
                get: { model.editorText(for: path, in: folder.id) },
                set: { model.setEditorText($0, for: path, in: folder.id) }
            ))
            .font(Theme.mono(12))
            .scrollContentBackground(.hidden)
            .padding(Theme.Space.s)

            HStack(spacing: Theme.Space.s) {
                Text(path)
                    .font(Theme.mono(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if model.isEditorDirty(path, in: folder.id) {
                    Text("Unsaved")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") {
                    Task { await model.saveText(path, in: folder.id) }
                }
                .disabled(!model.isEditorDirty(path, in: folder.id))
                .keyboardShortcut("s")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.panel)
        }
        .background(Theme.background)
    }
}
