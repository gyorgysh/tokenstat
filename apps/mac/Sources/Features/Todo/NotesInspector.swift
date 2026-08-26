// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The selected note, in the same column a task gets.
///
/// Notes were the one list in the app with no inspector: a note could be
/// written and archived and nothing else, so the body text somebody typed on
/// their phone could not be read on the Mac, let alone edited. Tasks had all
/// of that a pane away. This is the same pane, with the fields a note has
/// rather than the ones an agent run needs.
struct NotesInspector: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]
    var onClose: () -> Void

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var baselineTitle = ""
    @State private var baselineNotes = ""
    @State private var saveState: FieldSaveState = .idle
    @State private var loadedID: String?
    @State private var placeID = ""
    @State private var applyingPlace = false
    @State private var converting = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case title, notes }

    /// The selection, but only while it is a note. The board and this screen
    /// share one selected card, so arriving here with a task selected must
    /// show the empty state rather than an editor for something else.
    private var note: TodoCard? {
        guard let card = model.selectedCard, card.isNote else { return nil }
        return card
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                FeatureMark(name: "mark_note", tint: Theme.secondary, size: 16)
                    .padding(.leading, Theme.Space.m)
                Text("Note")
                    .font(Theme.font(13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Group {
                if let note {
                    noteBody(note)
                } else {
                    InspectorEmptyState(
                        mark: "mark_note",
                        title: "Pick a note",
                        subtitle: "Its text, where it belongs and what to do with it live here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onChange(of: model.selectedCardID) { old, _ in
            let title = titleDraft
            let notes = notesDraft
            Task { await persistDrafts(for: old, title: title, notes: notes) }
            syncDrafts()
        }
        .onChange(of: focused) { _, new in
            if new == nil { Task { await persistDrafts() } }
        }
        .onChange(of: titleDraft) { _, _ in markDirtyIfNeeded() }
        .onChange(of: notesDraft) { _, _ in markDirtyIfNeeded() }
        .onDisappear { Task { await persistDrafts() } }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let note else { return }
                Task {
                    await model.remove(note)
                    model.selectedCardID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is gone for good. Archive keeps it and takes it off the list.")
        }
        .sheet(isPresented: $converting) {
            if let note {
                ConvertNoteSheet(note: note, folders: folders) { folderID in
                    converting = false
                    Task { await model.convertToTask(note, workspaceID: folderID) }
                } onCancel: {
                    converting = false
                }
            }
        }
    }

    private func noteBody(_ note: TodoCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.font(15, weight: .semibold))
                    .focused($focused, equals: .title)
                    .onSubmit { Task { await persistDrafts() } }
                    .onAppear { syncDrafts() }

                notesEditor

                FieldSaveBar(
                    state: saveState,
                    canSave: !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await persistDrafts() }
                } onCancel: {
                    titleDraft = baselineTitle
                    notesDraft = baselineNotes
                    saveState = .idle
                }

                // A note belongs somewhere, and until now the only way to
                // change where was to write it again in the right place.
                AppMenuPicker(
                    title: "Folder",
                    options: [(value: "", label: "Unassigned")]
                        + folders.map { (value: $0.id, label: $0.name) },
                    selection: $placeID
                )
                .onChange(of: placeID) { _, new in
                    guard !applyingPlace, loadedID == note.id, new != note.workspaceID else { return }
                    Task { await model.updateCard(note, workspaceID: new) }
                }

                written(note)

                actions(note)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesEditor: some View {
        TextEditor(text: $notesDraft)
            .font(Theme.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120, maxHeight: 260)
            .padding(Theme.Space.xs)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if notesDraft.isEmpty {
                    Text("Note")
                        .font(Theme.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.s)
                        .allowsHitTesting(false)
                }
            }
            .focused($focused, equals: .notes)
    }

    private func written(_ note: TodoCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Written")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            RelativeTimeText(
                date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000),
                unitsStyle: .full
            )
            .font(Theme.callout)
        }
    }

    @ViewBuilder
    private func actions(_ note: TodoCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button("Make a task", .move) { converting = true }
                .buttonStyle(AccentButtonStyle())
            HStack(spacing: Theme.Space.s) {
                if note.column == "archive" {
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
                // Archive is beside this and is the reversible one. Deleting
                // a note is the only permanent thing this pane can do, and a
                // misclick a few points to the right of Archive must not be
                // the way somebody finds that out.
                Button("Delete", .delete) { confirmingDelete = true }
                    .buttonStyle(DestructiveButtonStyle())
            }
        }
    }

    // MARK: - Drafts

    private func markDirtyIfNeeded() {
        guard loadedID != nil else { return }
        if titleDraft != baselineTitle || notesDraft != baselineNotes {
            if saveState != .saving { saveState = .dirty }
        } else if saveState == .dirty || saveState == .failed {
            saveState = .idle
        }
    }

    private func syncDrafts() {
        guard let note else {
            loadedID = nil
            titleDraft = ""
            notesDraft = ""
            baselineTitle = ""
            baselineNotes = ""
            placeID = ""
            saveState = .idle
            return
        }
        guard loadedID != note.id else { return }
        loadedID = note.id
        titleDraft = note.title
        notesDraft = note.notes
        baselineTitle = note.title
        baselineNotes = note.notes
        applyingPlace = true
        placeID = note.workspaceID
        applyingPlace = false
        saveState = .idle
    }

    private func persistDrafts() async {
        await persistDrafts(for: loadedID, title: titleDraft, notes: notesDraft)
    }

    /// Write the drafts back to the card they were typed into.
    ///
    /// The id is passed rather than read, because this also runs while the
    /// selection is moving to another note: by the time it does, `model`
    /// already points at the new one and saving against that would put one
    /// note's text into another.
    ///
    /// An empty title is not a save that failed, it is a title that was not
    /// changed. Sending it made the whole write fail, which took the body edit
    /// typed in the same visit down with it and left Save disabled, because
    /// Save needs a title: the only way out was Cancel, which threw the body
    /// away as well. The field goes back to what it was and the body is
    /// written on its own.
    ///
    /// The state at the end belongs to the note on screen. Setting it after
    /// the selection has moved on is how another note's pane ended up saying
    /// "Saving" about a write that had already finished somewhere else.
    private func persistDrafts(for id: String?, title: String, notes: String) async {
        if saveState == .saving { return }
        guard let id, let card = model.cards.first(where: { $0.id == id }), card.isNote else { return }
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            trimmed = card.title
            if loadedID == id { titleDraft = card.title }
        }
        let titleChanged = trimmed != card.title
        let notesChanged = notes != card.notes
        guard titleChanged || notesChanged else {
            if saveState == .dirty { saveState = .idle }
            return
        }
        saveState = .saving
        var ok = true
        if titleChanged { ok = await model.updateTitle(card, title: trimmed) && ok }
        if notesChanged { ok = await model.updateNotes(card, notes: notes) && ok }
        guard loadedID == id else {
            // The pane is showing a different note now, and that note's own
            // drafts decide what its bar says.
            if saveState == .saving { saveState = .idle }
            return
        }
        if ok {
            baselineTitle = trimmed
            baselineNotes = notes
            titleDraft = trimmed
            saveState = .saved
            Task {
                try? await Task.sleep(for: .seconds(2))
                if saveState == .saved { saveState = .idle }
            }
        } else {
            saveState = .failed
        }
    }
}
