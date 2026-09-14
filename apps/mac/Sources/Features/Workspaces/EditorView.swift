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
    @State private var find = EditorFindSession()

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.editorError {
                Banner(text: error, severity: .danger)
            }

            // One branch, not one per platform. Everything except the editor
            // itself and its status line is the same on both, and two copies
            // of the document lookup and the loading fallback would have to be
            // kept in step by hand across a boundary neither side compiles.
            if let document = model.document(for: path, in: folder.id) {
                editor(document)
                    .background(Theme.background)
                statusLine(document)
            } else {
                loading
            }
        }
        .background(Theme.background)
        #if !os(macOS)
        .clientShortcuts(findShortcuts)
        #endif
    }

    /// The editor for this platform. The only real difference between the two
    /// builds: AppKit's needs a save action passed in, UIKit's carries Save in
    /// its own status line.
    @ViewBuilder
    private func editor(_ document: EditorDocument) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            if find.showing {
                EditorFindBar(find: find)
            }
            CodeTextView(document: document, find: find) {
                Task { await model.saveText(path, in: folder.id) }
            }
        }
        .background {
            // For focus in the SwiftUI chrome. With the caret in the text,
            // the text view's key equivalents answer instead.
            Group {
                Button("Find next") {
                    if find.showing { find.goNext() } else { find.showing = true }
                }
                .keyboardShortcut("g", modifiers: .command)
                Button("Find previous") {
                    if find.showing { find.goPrevious() } else { find.showing = true }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .hidden()
        }
        #else
        VStack(spacing: 0) {
            if find.showing {
                EditorFindBar(find: find)
            }
            IOSCodeTextView(document: document, find: find)
        }
        #endif
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
                    .font(Theme.caption)
                    .imageScale(.small)
                    .foregroundStyle(Theme.warning)
            }

            if let note = document.highlightNote {
                // Not an error. "No grammar for this file type" is a normal
                // thing for a text file to be, and the file still edits and
                // saves. It belongs here in grey, not in a banner in red.
                Text(note)
                    .font(Theme.caption)
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

            Button("Find in file", systemImage: "magnifyingglass") { find.showing.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.controlGlyph)
                .help("Find in file")
                .keyboardShortcut("f", modifiers: .command)
            Button("Save", .save) {
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

    #if !os(macOS)
    private func statusLine(_ document: EditorDocument) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(path)
                .font(ClientType.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)

            if document.isDirty {
                Label("Unsaved", systemImage: "circle.fill")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.warning)
            }

            if let note = document.highlightNote {
                Text(note)
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
            Button("Find in file", .search) { find.showing.toggle() }
                .labelStyle(.iconOnly)
                .keyboardShortcut("f", modifiers: .command)
            Button("Save", .save) {
                Task { await model.saveText(path, in: folder.id) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!document.isDirty)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var findShortcuts: [ClientShortcut] {
        let state = EditorShortcutState(
            canNavigate: find.canNavigate,
            findShowing: find.showing
        )
        return [
            .workbench(.findNext, id: "find-next", title: "Find Next",
                       enabled: WorkbenchShortcutPolicy.canFindNext(state)) {
                if find.showing {
                    find.goNext()
                } else {
                    find.showing = true
                }
            },
            .workbench(.findPrevious, id: "find-previous", title: "Find Previous",
                       enabled: WorkbenchShortcutPolicy.canFindPrevious(state)) {
                if find.showing {
                    find.goPrevious()
                } else {
                    find.showing = true
                }
            },
        ]
    }
    #endif
}
