// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// Small things worth keeping, and nothing else.
///
/// Notes used to be a kind of card on the kanban board, which meant they sat in
/// a column called To Do, counted as work until every count learned to exclude
/// them, and made writing one down a decision about where it belonged. None of
/// that is what a note is.
///
/// So the field is the screen. It keeps focus after each note, because the
/// point of quick capture is the second thought that arrives while writing the
/// first one down. Everything else a note can do happens later: put it away, or
/// promote it to a task, which is where folders and agents start to matter.
struct NotesView: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]

    @State private var draft = ""
    @State private var showingArchive = false
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar(scope: nil) {
                ToolbarIconButton(
                    systemImage: showingArchive ? "archivebox.fill" : "archivebox",
                    help: showingArchive
                        ? "Show current notes"
                        : (model.archivedNotes.isEmpty
                            ? "Nothing archived"
                            : "Show \(model.archivedNotes.count) archived"),
                    isAccent: showingArchive,
                    showsBadge: false
                ) {
                    showingArchive.toggle()
                }
                .disabled(model.archivedNotes.isEmpty && !showingArchive)
            }
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(Theme.Space.m)
            }
            composer
            list
        }
        .background(Theme.background)
        .navigationTitle("Notes")
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task { await model.appeared() }
        .onDisappear { model.disappeared() }
    }

    /// One line, always at the top, always ready.
    private var composer: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Theme.accent)
            TextField("Something worth remembering", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: DisplayFit.dp(14)))
                .focused($writing)
                .onSubmit { save() }
            if !draft.isEmpty {
                Button("Add", .create) { save() }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var list: some View {
        let shown = showingArchive ? model.archivedNotes : model.notes
        if shown.isEmpty {
            VStack(spacing: Theme.Space.s) {
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                Text(showingArchive ? "Nothing archived." : "No notes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !showingArchive {
                    Text("Type above and press return.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(shown) { note in
                        row(note)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private func row(_ note: TodoCard) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.system(size: DisplayFit.dp(13)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !note.notes.isEmpty {
                    Text(note.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                RelativeTimeText(
                    date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000),
                    unitsStyle: .abbreviated
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: Theme.Space.s)
            // A note becomes work by being given a folder, which is the only
            // decision a note ever defers.
            Menu {
                ForEach(folders) { folder in
                    Button(folder.name) {
                        Task { await model.convertToTask(note, workspaceID: folder.id) }
                    }
                }
                Button("No folder") {
                    Task { await model.convertToTask(note, workspaceID: "") }
                }
            } label: {
                Label("Make a task", systemImage: "checklist")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Make this a task")
            if showingArchive {
                Button("Restore", .restore) {
                    Task { await model.archiveNote(note, archived: false) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Archive", .archive) {
                    Task { await model.archiveNote(note, archived: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private func save() {
        let text = draft
        draft = ""
        // Focus stays here rather than following the note into the list: the
        // second thought usually arrives while the first is being written.
        writing = true
        Task { await model.addNote(text) }
    }
}
