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
    @State private var pendingDelete: TodoCard?
    @State private var editing: TodoCard?
    @State private var editText = ""
    @FocusState private var writing: Bool

    @Environment(ConnectivityModel.self) private var connectivity: ConnectivityModel?

    /// Newest first. A note is a moment, not a position in a queue, so the
    /// order it was written in is the only order that means anything.
    private var notes: [TodoCard] {
        cards
            .filter { $0.kind == .note && ($0.column == "archive") == showingArchive }
            .sorted { $0.createdAtMs > $1.createdAtMs }
    }

    private var archivedCount: Int {
        cards.filter { $0.kind == .note && $0.column == "archive" }.count
    }

    private var place: String { folderName.isEmpty ? "this folder" : folderName }

    /// Offline the machine that owns these notes cannot be reached, so there
    /// is nothing to write to. Saying so beside a disabled field beats a field
    /// that takes text and loses it.
    private var isOffline: Bool { connectivity?.isOffline ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if !showingArchive {
                composer
            }
            list
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    showingArchive ? "Show notes" : "Show archive",
                    showingArchive ? .restore : .archive
                ) {
                    showingArchive.toggle()
                }
                .labelStyle(.iconOnly)
                .disabled(archivedCount == 0 && !showingArchive)
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let note = pendingDelete { Task { await delete(note) } }
                pendingDelete = nil
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Archiving keeps it. Deleting does not.")
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
                TextField("Something worth remembering", text: $draft)
                    .focused($writing)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .disabled(isOffline)
                Button("Add", .create) { save() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(canSave ? Theme.accent : .secondary)
                    .disabled(!canSave)
            }
            Text(isOffline
                ? "Offline. Notes are kept on \(hostName.isEmpty ? "the computer" : hostName), so this waits."
                : "Saves to \(place).")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.m)
        .background(Theme.panel)
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
            title: "Notes",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: notes.isEmpty,
            emptyText: showingArchive ? "Nothing archived" : "No notes yet",
            emptyArt: .notes,
            emptyMessage: showingArchive
                ? "Notes you put away in \(place) show up here."
                : "Anything worth remembering about \(place). Type above and press return.",
            refreshKey: "notes-\(workspaceID)",
            reload: { await load() }
        ) {
            ForEach(notes) { note in
                row(note)
                    .clientCardRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(showingArchive ? "Restore" : "Archive") {
                            Task { await setArchived(note, archived: !showingArchive) }
                        }
                        .tint(Theme.accent)
                        Button("Delete", role: .destructive) { pendingDelete = note }
                    }
                    .contextMenu {
                        Button("Edit") { startEditing(note) }
                        if !showingArchive {
                            Button("Make a task") { Task { await convert(note) } }
                        }
                        Button("Delete", role: .destructive) { pendingDelete = note }
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
                    .font(ClientType.label)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
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
        editing = note
    }

    private func editor(_ note: TodoCard) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note", text: $editText, axis: .vertical)
                        .lineLimit(3 ... 10)
                } footer: {
                    Text("A note is its text, so this is the whole of it.")
                }
            }
            .navigationTitle("Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                        editing = nil
                        Task { await rename(note, to: text) }
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
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

    private func rename(_ note: TodoCard, to text: String) async {
        guard !text.isEmpty, text != note.title else { return }
        do {
            let updated = try await ClientRemote.todoRetitle(peer: peer, id: note.id, title: text)
            replace(updated)
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
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
