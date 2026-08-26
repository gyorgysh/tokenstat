// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// Small things worth keeping, and nothing else.
///
/// A note can live on a project or stay unassigned. That is a label, not a
/// column. The field stays focused after each note so the next one is ready.
///
/// The same screen serves the global list and one folder's. With a
/// `workspaceID` the chips go away: a folder's notes are that folder's, and a
/// filter on top of it would be two answers to one question.
struct NotesView: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]
    /// The folder this screen is scoped to, or nil for every folder.
    var workspaceID: String?

    @State private var draft = ""
    @State private var showingArchive = false
    @State private var picked: TodoModel.NoteScope = .all
    @State private var converting: TodoCard?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar(scope: nil) {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Write a note"
                ) {
                    writing = true
                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        save()
                    }
                }
                ToolbarIconButton(
                    systemImage: showingArchive ? "archivebox.fill" : "archivebox",
                    help: showingArchive
                        ? "Show current notes"
                        : (archivedCount == 0
                            ? "Nothing archived"
                            : "Show \(archivedCount) archived"),
                    isAccent: showingArchive,
                    showsBadge: false
                ) {
                    showingArchive.toggle()
                }
                .disabled(archivedCount == 0 && !showingArchive)
            }
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(Theme.Space.m)
            }
            composer
            if workspaceID == nil {
                scopeBar
            }
            list
        }
        .background(Theme.background)
        .navigationTitle("Notes")
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .sheet(item: $converting) { note in
            ConvertNoteSheet(note: note, folders: folders) { folderID in
                converting = nil
                Task { await model.convertToTask(note, workspaceID: folderID) }
            } onCancel: {
                converting = nil
            }
        }
        .task { await model.appeared() }
        .onDisappear { model.disappeared() }
    }

    /// What the list is showing: the folder this screen belongs to, or the
    /// chip you picked on the global one.
    private var scope: TodoModel.NoteScope {
        if let workspaceID { return .workspace(workspaceID) }
        return picked
    }

    /// How many notes are put away in what is on screen. Scoped, so a folder's
    /// archive button does not light up for another folder's notes.
    private var archivedCount: Int {
        model.notes(in: scope, archived: true).count
    }

    /// Where a new note lands: this folder, the chip you picked, or unassigned
    /// when looking at everything.
    private var destinationID: String {
        if case let .workspace(id) = scope { return id }
        return ""
    }

    private var destinationName: String {
        if case let .workspace(id) = scope {
            return folders.first { $0.id == id }?.name ?? "this folder"
        }
        return "Unassigned"
    }

    /// One line, always at the top, always ready. The plus in the chrome
    /// focuses it; Add is always visible so the field is not the only way in.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Theme.accent)
                TextField("Something worth remembering", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.fit(14))
                    .focused($writing)
                    .onSubmit { save() }
                Button("Add", .create) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Saves to \(destinationName).")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChoiceChip(title: "All", isSelected: picked == .all) {
                    picked = .all
                }
                ChoiceChip(title: "Unassigned", isSelected: picked == .unassigned) {
                    picked = .unassigned
                }
                ForEach(folders) { folder in
                    ChoiceChip(
                        title: folder.name,
                        isSelected: picked == .workspace(folder.id)
                    ) {
                        picked = .workspace(folder.id)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var list: some View {
        let shown = model.notes(in: scope, archived: showingArchive)
        if shown.isEmpty {
            VStack(spacing: Theme.Space.s) {
                Spacer()
                Image(systemName: "note.text")
                    .font(Theme.font(30, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                Text(emptyTitle)
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                if !showingArchive {
                    Text("Type above and press return, or the plus.")
                        .font(Theme.caption)
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

    private var emptyTitle: String {
        if showingArchive { return "Nothing archived." }
        switch scope {
        case .all: return "No notes yet."
        case .unassigned: return "No unassigned notes."
        case .workspace: return "No notes in \(destinationName)."
        }
    }

    private func row(_ note: TodoCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title)
                        .font(Theme.fit(13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !note.notes.isEmpty {
                        Text(note.notes)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        Text(placeName(for: note))
                            .font(Theme.caption2)
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .font(Theme.caption2)
                            .foregroundStyle(.tertiary)
                        RelativeTimeText(
                            date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000),
                            unitsStyle: .abbreviated
                        )
                        .font(Theme.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
                if showingArchive {
                    Button("Restore", .restore) {
                        Task { await model.archiveNote(note, archived: false) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Archive", .archive) {
                        Task { await model.archiveNote(note, archived: true) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            if !showingArchive {
                Button("Make a task", .move) {
                    converting = note
                }
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

    private func placeName(for note: TodoCard) -> String {
        if note.workspaceID.isEmpty { return "Unassigned" }
        return folders.first { $0.id == note.workspaceID }?.name ?? "Folder"
    }

    private func save() {
        let text = draft
        draft = ""
        writing = true
        Task { await model.addNote(text, workspaceID: destinationID) }
    }
}

/// Pick a folder, then the note becomes a card on that board.
///
/// Capture stays cheap because this decision happens later, in a panel that
/// says what it is doing, not a hidden menu of folder names.
private struct ConvertNoteSheet: View {
    let note: TodoCard
    let folders: [WorkspaceFolder]
    let onConvert: (String) -> Void
    let onCancel: () -> Void

    @State private var folderID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make a task")
                        .font(Theme.font(15, weight: .semibold))
                    Text("This note becomes a card on the board. Pick a folder, or leave it unassigned.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                InspectorCloseButton(
                    action: onCancel,
                    help: "Close",
                    label: "Close"
                )
            }

            Text(note.title)
                .font(Theme.font(13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))

            Text("Folder")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ChoiceChip(title: "Unassigned", isSelected: folderID.isEmpty) {
                    folderID = ""
                }
                ForEach(folders) { folder in
                    ChoiceChip(
                        title: folder.name,
                        isSelected: folderID == folder.id
                    ) {
                        folderID = folder.id
                    }
                }
            }

            HStack {
                Button("Cancel", .dismiss, role: .cancel) { onCancel() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Make a task", .move) { onConvert(folderID) }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 440)
        .background(Theme.panel)
        .onAppear {
            folderID = note.workspaceID
        }
    }
}
