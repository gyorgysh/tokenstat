// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Every card on this machine, in one place, and a way to add one.
///
/// The phone had tasks only inside a folder, which answers "what is left here"
/// and never "what is left". This is the other question, and it is the one a
/// phone is actually good for: reading the list on the way somewhere, and
/// writing down the thing you just thought of before it is gone.
///
/// **Uncategorized comes first, as a heading rather than a filter.** A card with
/// no folder is the easiest kind to lose, and on a list this short it costs
/// nothing to show it rather than hide it behind a selector.
struct ClientTasksOverview: View {
    let peer: String
    let hostName: String
    let folders: [WorkspaceFolder]

    @State private var cards: [TodoCard] = []
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var composing = false
    @State private var showingArchive = false

    /// Folder id to the name a person would recognise. Cards carry the path.
    private var folderNames: [String: String] {
        var out: [String: String] = [:]
        for folder in folders {
            out[ClientRemote.rawWorkspaceID(of: folder) ?? folder.id] = folder.name
        }
        return out
    }

    private var visible: [TodoCard] {
        cards.filter { ($0.column == "archive") == showingArchive }
    }

    private var unfiled: [TodoCard] {
        visible.filter { $0.workspaceID.isEmpty }.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    /// Cards by folder, folders in the order the sidebar shows them, and any
    /// folder this machine no longer lists kept under the path it carries.
    private var byFolder: [(id: String, name: String, cards: [TodoCard])] {
        let filed = visible.filter { !$0.workspaceID.isEmpty }
        let groups = Dictionary(grouping: filed, by: \.workspaceID)
        return groups
            .map { id, cards in
                let name = folderNames[id] ?? id.split(separator: "/").last.map(String.init) ?? id
                return (id: id, name: name, cards: cards.sorted { $0.createdAtMs > $1.createdAtMs })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ClientCardList(
            title: "Tasks",
            errorMessage: errorMessage,
            isLoaded: loaded,
            isEmpty: visible.isEmpty,
            emptyText: showingArchive
                ? "Nothing archived on this machine."
                : "No cards yet. Add one with the plus.",
            refreshKey: "todo-overview-\(peer)",
            reload: { await load() }
        ) {
            if !unfiled.isEmpty {
                heading("Uncategorized", count: unfiled.count)
                ForEach(unfiled) { card in
                    row(card, folder: nil)
                }
            }
            ForEach(byFolder, id: \.id) { group in
                heading(group.name, count: group.cards.count)
                ForEach(group.cards) { card in
                    row(card, folder: group.name)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", .create) { composing = true }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    showingArchive ? "Show open cards" : "Show archive",
                    showingArchive ? .restore : .archive
                ) {
                    showingArchive.toggle()
                }
                .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $composing) {
            ClientTaskComposer(
                peer: peer,
                workspaceID: "",
                folderName: "Uncategorized",
                hostName: hostName,
                folders: folders
            ) {
                await load()
            }
        }
        .task { await load() }
    }

    private func heading(_ text: String, count: Int) -> some View {
        HStack {
            Text(text.uppercased())
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("\(count)")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, Theme.Space.xs)
        .clientCardRow()
    }

    private func row(_ card: TodoCard, folder: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.xs) {
                if card.kind == .note {
                    Image(systemName: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(card.title)
                    .font(ClientType.label.weight(.medium))
                Spacer(minLength: 0)
                if !showingArchive, card.column != "backlog" {
                    Text(card.column == "doing" ? "Doing" : "Done")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if card.column == "archive" {
                Button("Restore") { Task { await move(card, to: "backlog") } }
            } else {
                Button("Archive") { Task { await move(card, to: "archive") } }
            }
            Button("Delete", role: .destructive) { Task { await remove(card) } }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if card.kind != .note, card.column != "done" {
                Button("Done") { Task { await move(card, to: "done") } }
            }
        }
        .clientCardRow()
    }

    private func move(_ card: TodoCard, to column: String) async {
        do {
            _ = try await ClientRemote.todoMove(peer: peer, id: card.id, column: column)
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func remove(_ card: TodoCard) async {
        do {
            try await ClientRemote.todoRemove(peer: peer, id: card.id)
            await load()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func load() async {
        do {
            cards = try await ClientRemote.todoCards(peer: peer)
            errorMessage = nil
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }
}

#endif
