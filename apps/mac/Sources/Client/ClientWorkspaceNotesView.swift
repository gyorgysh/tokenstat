// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Small things worth keeping, for one folder, on the machine that owns it.
///
/// The Mac's `NotesView` for a single project, with the scope chips left out:
/// there is no global list here to scope, and a filter on top of "this
/// folder's notes" would be two answers to one question.
///
/// **Quick capture is the whole point.** One field at the top, return saves,
/// the field keeps focus so the next note is ready, and an Add button beside
/// it so the keyboard is not the only way in. The cost of writing something
/// down has to stay below the cost of deciding not to.
///
/// A note is a `todo` card whose kind is `note`, which is why every action
/// here is a method that already existed. Notes are not tasks and no longer
/// share a screen with them.
struct ClientWorkspaceNotesView: View {
    let peer: String
    let workspaceID: String
    let hostName: String
    var folderName: String = ""

    @State private var cards: [TodoCard] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var showingArchive = false
    @State private var showingComposer = false
    @State private var search = ""
    @State private var alphabetical = false
    @State private var pendingDelete: TodoCard?
    @State private var editing: TodoCard?
    @State private var editText = ""
    @State private var editBody = ""
    @State private var editPreview = false
    @State private var editSaving = false
    @State private var editError: String?
    @FocusState private var writing: Bool

    @Environment(ConnectivityModel.self) private var connectivity: ConnectivityModel?

    /// Newest first. A note is a moment, not a position in a queue, so the
    /// order it was written in is the only order that means anything.
    private var notes: [TodoCard] {
        cards
            .filter { $0.kind == .note && ($0.column == "archive") == showingArchive }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search) }
            .sorted { alphabetical ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.createdAtMs > $1.createdAtMs }
    }

    private var archivedCount: Int {
        cards.filter { $0.kind == .note && $0.column == "archive" }.count
    }

    private var place: String { folderName.isEmpty ? L10n.text("apple.clientworkspacenotesview.this_folder.9d6325c8") : folderName }

    /// Offline the machine that owns these notes cannot be reached, so there
    /// is nothing to write to. Saying so beside a disabled field beats a field
    /// that takes text and loses it.
    private var isOffline: Bool { connectivity?.isOffline ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if showingComposer && !showingArchive {
                composer
            }
            list
        }
        .background(Theme.background)
        .searchable(text: $search, prompt: L10n.text("apple.clientworkspacenotesview.search_notes.6e7a2179"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("apple.clientworkspacenotesview.new_note.76ea482f"), .create) {
                    showingArchive = false
                    showingComposer = true
                    writing = true
                }
                .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L10n.text("apple.clientworkspacenotesview.sort_notes.ea06e19b"), selection: $alphabetical) {
                        Text(L10n.text("apple.clientworkspacenotesview.newest_first.ffb6f576")).tag(false)
                        Text(L10n.text("apple.clientworkspacenotesview.title_a_z.ab217de6")).tag(true)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel(L10n.text("apple.clientworkspacenotesview.sort_notes.ea06e19b"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    showingArchive ? L10n.text("apple.clientworkspacenotesview.show_notes.1415fb63") : L10n.text("apple.clientworkspacenotesview.show_archive.039872c4"),
                    showingArchive ? .restore : .archive
                ) {
                    showingArchive.toggle()
                    showingComposer = false
                    writing = false
                }
                .labelStyle(.iconOnly)
                .disabled(archivedCount == 0 && !showingArchive)
            }
        }
        .confirmationDialog(
            L10n.text("apple.clientworkspacenotesview.delete_this_note.f8069d7e"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let note = pendingDelete { Task { await delete(note) } }
                pendingDelete = nil
            }
            Button(L10n.text("apple.clientworkspacenotesview.keep_it.fdce5da2"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.text("apple.clientworkspacenotesview.archiving_keeps_it_deleting_does_not.55919870"))
        }
        .sheet(item: $editing) { note in
            editor(note)
        }
        .task { await load() }
    }

    // MARK: - Capture

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Theme.accent)
                TextField(L10n.text("apple.clientworkspacenotesview.something_worth_remembering.a56cd69e"), text: $draft)
                    .focused($writing)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .disabled(isOffline)
                Button(L10n.text("common.add"), .create) { save() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(canSave ? Theme.accent : .secondary)
                    .disabled(!canSave)
            }
            HStack {
                Text(isOffline
                    ? L10n.text("apple.clientworkspacenotesview.offline_notes_are_kept_on_0_so_this_waits.a2dae42d", "\(hostName.isEmpty ? L10n.text("apple.clientworkspacenotesview.the_computer.da52d93a") : hostName)")
                    : L10n.text("apple.clientworkspacenotesview.saves_to_0.49357925", "\(place)"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("common.close"), .dismiss) {
                    showingComposer = false
                    writing = false
                }
                .font(ClientType.caption)
                .accessibilityHint(L10n.text("apple.clientworkspacenotesview.your_draft_stays_here.b3e8e522"))
            }
        }
        .task { writing = true }
        .padding(Theme.Space.m)
        .background(Theme.tabStrip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var canSave: Bool {
        !isOffline && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - List

    private var list: some View {
        ClientCardList(
            title: L10n.text("common.notes"),
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: notes.isEmpty,
            emptyText: !search.isEmpty ? L10n.text("apple.clientworkspacenotesview.no_matching_notes.5a859d10") : showingArchive ? L10n.text("apple.clientworkspacenotesview.nothing_archived.cd084fd7") : L10n.text("apple.clientworkspacenotesview.no_notes_yet.a092ad6b"),
            emptyArt: .notes,
            emptyMessage: showingArchive
                ? L10n.text("apple.clientworkspacenotesview.notes_you_put_away_in_0_show_up_here.bab677fb", "\(place)")
                : L10n.text("apple.clientworkspacenotesview.keep_anything_worth_remembering_about_0_ch.ca4055ff", "\(place)"),
            refreshKey: "notes-\(workspaceID)",
            reload: { await load() }
        ) {
            ClientSectionTitle(title: showingArchive ? L10n.text("apple.clientworkspacenotesview.archived_notes.27a341f0") : L10n.text("common.notes"), mark: "mark_note")
                .clientCardRow()
            ForEach(notes) { note in
                row(note)
                    .clientCardRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(showingArchive ? L10n.text("common.restore") : L10n.text("common.archive")) {
                            Task { await setArchived(note, archived: !showingArchive) }
                        }
                        .tint(Theme.accent)
                        Button(L10n.text("common.delete"), role: .destructive) { pendingDelete = note }
                    }
                    .contextMenu {
                        Button(L10n.text("common.edit")) { startEditing(note) }
                        if !showingArchive {
                            Button(L10n.text("apple.clientworkspacenotesview.make_a_task.0cfbd102")) { Task { await convert(note) } }
                        }
                        Button(L10n.text("common.delete"), role: .destructive) { pendingDelete = note }
                    }
            }
        }
    }

    private func row(_ note: TodoCard) -> some View {
        Button {
            startEditing(note)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(ClientType.label.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if !note.notes.isEmpty {
                    Text(note.notes).font(ClientType.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                RelativeTimeText(
                    date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000),
                    unitsStyle: .abbreviated
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .cardSurface()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Editing

    private func startEditing(_ note: TodoCard) {
        editText = note.title
        editBody = note.notes
        editPreview = false
        editError = nil
        editing = note
    }

    private func editor(_ note: TodoCard) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("apple.clientworkspacenotesview.title.7e8cd205"), text: $editText, axis: .vertical)
                        .font(Theme.headline)
                        .disabled(editSaving)
                    Picker(L10n.text("apple.clientworkspacenotesview.note_view.a6857193"), selection: $editPreview) {
                        Text(L10n.text("apple.clientworkspacenotesview.write.3f00927a")).tag(false)
                        Text(L10n.text("apple.clientworkspacenotesview.preview.324b134f")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    ZStack(alignment: .topLeading) {
                        ClientNoteTextEditor(text: $editBody, enabled: !editSaving && !editPreview)
                            .frame(minHeight: 280)
                            .opacity(editPreview ? 0 : 1)
                            .frame(height: editPreview ? 0 : nil)
                            .clipped()
                            .accessibilityHidden(editPreview)
                        if editPreview {
                            MarkdownText(editBody.isEmpty ? L10n.text("apple.clientworkspacenotesview.nothing_written_yet.4f01da04") : editBody)
                                .textSelection(.enabled)
                                .frame(minHeight: 280, alignment: .topLeading)
                        }
                    }
                } footer: {
                    Text(L10n.text("apple.clientworkspacenotesview.markdown_supported_headings_lists_links_an.9e2568aa"))
                }
                if let editError {
                    Section { Text(editError).foregroundStyle(Theme.danger) }
                }
            }
            .navigationTitle(L10n.text("apple.clientworkspacenotesview.note.d8da2c49"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("common.cancel")) { editing = nil }.disabled(editSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editSaving ? L10n.text("apple.clientworkspacenotesview.saving.23e39291") : L10n.text("common.save")) {
                        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let body = editBody
                        editSaving = true
                        Task {
                            if await saveEdit(note, title: text, body: body) { editing = nil }
                            editSaving = false
                        }
                    }
                    .disabled(editSaving || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(editSaving || editText != note.title || editBody != note.notes)
    }

    // MARK: - Work

    private func load() async {
        do {
            cards = try await ClientRemote.todoCards(peer: peer)
                .filter { $0.workspaceID == workspaceID }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }

    /// Write it down, and show it before the round trip finishes.
    ///
    /// The optimistic row carries a temporary id and is swapped for the card
    /// the host returns. A failure takes it back off and says why: a note left
    /// on screen that does not exist on the machine is the one unforgivable
    /// bug a notes screen can have.
    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        writing = true
        let pending = TodoCard(pendingNote: text, workspaceID: workspaceID)
        cards.append(pending)
        Task {
            do {
                let saved = try await ClientRemote.todoCreate(
                    peer: peer,
                    title: text,
                    kind: .note,
                    notes: "",
                    workspaceID: workspaceID
                )
                cards.removeAll { $0.id == pending.id }
                cards.append(saved)
                errorMessage = nil
            } catch {
                cards.removeAll { $0.id == pending.id }
                // Only if nothing has been typed since. The round trip
                // outlives the field, and putting the old text back over a
                // half-written note loses the wrong one of the two.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = text }
                errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            }
        }
    }

    private func setArchived(_ note: TodoCard, archived: Bool) async {
        do {
            let updated = try await ClientRemote.todoMove(
                peer: peer,
                id: note.id,
                column: archived ? "archive" : "backlog"
            )
            replace(updated)
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func saveEdit(_ note: TodoCard, title: String, body: String) async -> Bool {
        guard !title.isEmpty else { return false }
        guard title != note.title || body != note.notes else { return true }
        do {
            let updated = try await ClientRemote.todoRetitle(peer: peer, id: note.id, title: title, notes: body)
            replace(updated)
            editError = nil
            errorMessage = nil
            return true
        } catch {
            editError = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return false
        }
    }

    /// The note becomes a card on this folder's board and leaves this screen.
    private func convert(_ note: TodoCard) async {
        do {
            _ = try await ClientRemote.todoConvertToTask(
                peer: peer,
                id: note.id,
                prompt: note.notes.isEmpty ? note.title : note.notes,
                workspaceID: workspaceID
            )
            cards.removeAll { $0.id == note.id }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func delete(_ note: TodoCard) async {
        do {
            try await ClientRemote.todoRemove(peer: peer, id: note.id)
            cards.removeAll { $0.id == note.id }
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func replace(_ card: TodoCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
    }
}

#endif
