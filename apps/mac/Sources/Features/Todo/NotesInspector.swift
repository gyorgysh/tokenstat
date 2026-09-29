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
    var embedded = false
    var onClose: () -> Void

    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var baselineTitle = ""
    @State private var baselineNotes = ""
    private var saveState: FieldSaveState {
        guard let id = loadedID, let entry = model.noteDrafts.entries[id] else { return .idle }
        if entry.saving { return .saving }
        if entry.error != nil { return .failed }
        return entry.dirty ? .dirty : (entry.hasSaved ? .saved : .idle)
    }
    private var draftValue: NoteDraftStore.Text { .init(title: titleDraft, body: notesDraft) }
    @State private var loadedID: String?
    @State private var placeID = ""
    @State private var applyingPlace = false
    @State private var converting = false
    @State private var confirmingDelete = false
    @State private var preview = false
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
            if embedded {
                HStack {
                    Button("All notes", .back, action: onClose).buttonStyle(SecondaryButtonStyle(small: true))
                    Spacer()
                    if note != nil {
                        Picker("Note view", selection: $preview) {
                            Text("Write").tag(false)
                            Text("Preview").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    }
                }.padding(Theme.Space.m)
                ThemeRule()
            } else {
                InspectorChromeBar(onClose: onClose) {
                    InspectorTitle(title: "Note", symbol: "note.text", tint: Theme.secondary)
                    Spacer(minLength: 0)
                }
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
            if let old {
                retainDraft(for: old)
                Task { await model.saveNoteDraft(old) }
            }
            syncDrafts()
        }
        .onChange(of: focused) { _, new in
            if new == nil { Task { await persistDrafts() } }
        }
        .onChange(of: titleDraft) { _, _ in markDirtyIfNeeded() }
        .onChange(of: notesDraft) { _, _ in markDirtyIfNeeded() }
        .task(id: draftValue) {
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await persistDrafts()
        }
        .onDisappear {
            guard let id = loadedID else { return }
            retainDraft(for: id)
            Task { await model.saveNoteDraft(id) }
        }
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

                if !embedded {
                    Picker("Note view", selection: $preview) {
                        Text("Write").tag(false)
                        Text("Preview").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if preview {
                    MarkdownText(notesDraft.isEmpty ? "Nothing written yet." : notesDraft)
                        .textSelection(.enabled)
                        .frame(minHeight: embedded ? 300 : 120, alignment: .topLeading)
                } else {
                    notesEditor
                    Text("Markdown supported: headings, lists, links and code.")
                        .font(Theme.caption).foregroundStyle(.tertiary)
                }

                FieldSaveBar(
                    state: saveState,
                    canSave: !titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await persistDrafts() }
                } onCancel: {
                    guard let id = loadedID, let saved = model.noteDrafts.discard(id) else { return }
                    titleDraft = saved.title
                    notesDraft = saved.body
                }

                // A note belongs somewhere, and until now the only way to
                // change where was to write it again in the right place.
                AppMenuPicker(
                    title: "Project",
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
        NoteMarkdownEditor(text: $notesDraft)
            .font(Theme.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: embedded ? 360 : 180, maxHeight: embedded ? 700 : 360)
            .padding(Theme.Space.xs)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1)
            )
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
        guard let id = loadedID else { return }
        retainDraft(for: id)
    }

    private func retainDraft(for id: String) {
        model.noteDrafts.edit(id, value: draftValue,
                             saved: .init(title: baselineTitle, body: baselineNotes))
    }

    private func syncDrafts() {
        guard let note else {
            loadedID = nil
            titleDraft = ""
            notesDraft = ""
            baselineTitle = ""
            baselineNotes = ""
            placeID = ""
            return
        }
        guard loadedID != note.id else { return }
        loadedID = note.id
        let value = model.noteDrafts.open(note.id, saved: .init(title: note.title, body: note.notes))
        titleDraft = value.title
        notesDraft = value.body
        baselineTitle = note.title
        baselineNotes = note.notes
        applyingPlace = true
        placeID = note.workspaceID
        applyingPlace = false
    }

    private func persistDrafts() async {
        guard let id = loadedID else { return }
        let submitted = draftValue
        retainDraft(for: id)
        guard model.noteDrafts.entries[id]?.dirty == true else { return }
        await model.saveNoteDraft(id)
        guard loadedID == id, let entry = model.noteDrafts.entries[id] else { return }
        baselineTitle = entry.saved.title
        baselineNotes = entry.saved.body
        if draftValue == submitted {
            titleDraft = entry.value.title
            notesDraft = entry.value.body
        }
    }
}
