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
    @State private var saving = false
    @State private var showingComposer = false
    @State private var showingArchive = false
    @State private var picked: TodoModel.NoteScope = .all
    @State private var converting: TodoCard?
    @State private var search = ""
    @State private var sortByTitle = false
    @AppStorage("notes.gridLayout") private var gridLayout = false
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            DetailChromeBar(scope: nil) { EmptyView() }
            notesToolbar
            #else
            DetailChromeBar(scope: nil) {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Write a note"
                ) {
                    showingArchive = false
                    showingComposer = true
                    writing = true
                }
                ToolbarIconButton(
                    systemImage: gridLayout ? "list.bullet" : "square.grid.2x2",
                    help: gridLayout ? "Show notes as a list" : "Show notes as cards"
                ) { gridLayout.toggle() }
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
            #endif
            if let error = model.errorMessage {
                ErrorBanner(message: error) { Task { await model.load() } }
                    .padding(Theme.Space.m)
            }
            if showingComposer && !showingArchive { composer }
            #if !os(macOS)
            libraryBar
            if workspaceID == nil { scopeBar }
            #endif
            #if os(macOS)
            GeometryReader { proxy in
                let wide = proxy.size.width >= 640
                let selected = model.selectedCard?.isNote == true
                let showList = wide || !selected
                HStack(spacing: 0) {
                    list
                        .frame(width: showList ? (wide ? min(320, proxy.size.width * 0.36) : proxy.size.width) : 0)
                        .clipped().opacity(showList ? 1 : 0)
                        .allowsHitTesting(showList).accessibilityHidden(!showList)
                    if wide { ThemeRule.vertical }
                    NotesInspector(model: model, folders: folders, embedded: true) { model.selectedCardID = nil }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped().opacity(wide || selected ? 1 : 0)
                        .allowsHitTesting(wide || selected).accessibilityHidden(!wide && !selected)
                }
            }
            #else
            list
            #endif
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

    #if os(macOS)
    private var notesToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.s) {
                noteFilters
                Spacer(minLength: Theme.Space.s)
                noteActions
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack { noteFilters }
                HStack { Spacer(minLength: 0); noteActions }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) { ThemeRule() }
    }

    private var noteFilters: some View {
        HStack(spacing: Theme.Space.s) {
            SearchField(text: $search, prompt: "Search notes")
                .frame(minWidth: 160, maxWidth: 260)
            if workspaceID == nil {
                AppMenuPicker(options: [
                    (value: "", label: "All projects"),
                    (value: "__unassigned__", label: "Unassigned")
                ] + folders.map { (value: $0.id, label: $0.name) }, selection: Binding(
                    get: {
                        switch picked {
                        case .all: return ""
                        case .unassigned: return "__unassigned__"
                        case .workspace(let id): return id
                        }
                    },
                    set: { value in
                        picked = value.isEmpty ? .all : value == "__unassigned__" ? .unassigned : .workspace(value)
                    }
                ))
                .frame(width: 160)
                .help("Filter notes by project")
            }
        }
    }

    private var noteActions: some View {
        HStack(spacing: Theme.Space.s) {
            sortPicker
            ToolbarIconButton(systemImage: gridLayout ? "list.bullet" : "square.grid.2x2",
                help: gridLayout ? "Show notes as a list" : "Show notes as cards") { gridLayout.toggle() }
            Button(showingArchive ? "Current notes" : "Archive", showingArchive ? .back : .archive) {
                showingArchive.toggle()
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(archivedCount == 0 && !showingArchive)
            Button("New note", .create) {
                showingArchive = false
                showingComposer = true
                writing = true
            }
            .buttonStyle(AccentButtonStyle(small: true))
        }
        .fixedSize()
    }
    #endif

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

    private var shownNotes: [TodoCard] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = model.notes(in: scope, archived: showingArchive).filter {
            term.isEmpty || $0.title.localizedStandardContains(term) || $0.notes.localizedStandardContains(term)
        }
        return sortByTitle ? notes.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        } : notes
    }

    private func count(in scope: TodoModel.NoteScope) -> Int {
        model.notes(in: scope, archived: showingArchive).count
    }

    private var libraryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { libraryTitle; Spacer(); searchField; sortPicker }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack { libraryTitle; Spacer(); sortPicker }
                searchField
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private var libraryTitle: some View {
        HStack(spacing: Theme.Space.s) {
            Text(showingArchive ? "Archived notes" : "Your notes")
                .font(Theme.headline)
            Text("\(shownNotes.count)")
                .font(Theme.numeric(11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.secondary.opacity(0.1), in: Capsule())
        }.fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear note search")
            }
        }
        .font(Theme.callout).padding(8)
        .frame(minWidth: 160, maxWidth: 300)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private var sortPicker: some View {
        AppMenuPicker(options: [(value: false, label: "Newest first"), (value: true, label: "Title A–Z")],
                      selection: $sortByTitle)
            .frame(width: 130).help("Sort notes")
    }

    /// Opened from New note; closing it keeps the draft for next time.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_note", tint: Theme.secondary, size: 22)
                Text("Quick note").font(Theme.callout.weight(.semibold))
                Spacer()
                Button("Close", .dismiss) { showingComposer = false; writing = false }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .help("Close the composer; your draft stays here")
                Label(destinationName, systemImage: "folder")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: Theme.Space.s) {
                TextField("Capture an idea, a decision, or something to follow up…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.fit(14))
                    .focused($writing)
                    .onSubmit { save() }
                if saving { ProgressView().controlSize(.small) }
                Button("Save note", .create) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Return to save · Select a note to edit its full text")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(writing ? Theme.accent.opacity(0.5) : Theme.border))
        .padding(Theme.Space.m)
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChoiceChip(title: "All · \(count(in: .all))", isSelected: picked == .all) {
                    picked = .all
                }
                ChoiceChip(title: "Unassigned · \(count(in: .unassigned))", isSelected: picked == .unassigned) {
                    picked = .unassigned
                }
                ForEach(folders) { folder in
                    ChoiceChip(
                        title: "\(folder.name) · \(count(in: .workspace(folder.id)))",
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
        let shown = shownNotes
        if !model.hasLoaded && model.errorMessage == nil {
            VStack(spacing: Theme.Space.m) {
                Skeleton.CardPlaceholder(rows: 3)
                Skeleton.CardPlaceholder(rows: 3)
                Spacer()
            }.padding(Theme.Space.m)
        } else if shown.isEmpty {
            VStack(spacing: Theme.Space.s) {
                Spacer()
                Image(systemName: "note.text")
                    .font(Theme.font(30, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.5))
                Text(search.isEmpty ? emptyTitle : "No matching notes")
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                if !search.isEmpty {
                    Button("Clear search", .dismiss) { search = "" }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else if !showingArchive {
                    Text("Choose New note to capture an idea. You can turn it into a task later.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                WidthReader { width in
                    let columns = gridLayout ? min(shown.count, max(1, min(3, Int(width / 340)))) : 1
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top), count: columns), spacing: gridLayout ? Theme.Space.m : 0) {
                        ForEach(shown) { note in
                            if gridLayout { row(note) } else { compactRow(note) }
                        }
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

    private func compactRow(_ note: TodoCard) -> some View {
        Button { model.selectCard(note.id) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.title).font(Theme.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    RelativeTimeText(date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000), unitsStyle: .abbreviated)
                        .font(Theme.caption2).foregroundStyle(.secondary)
                }
                if !note.notes.isEmpty {
                    Text(note.notes).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if workspaceID == nil {
                    Text(placeName(for: note)).font(Theme.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedCardID == note.id ? Theme.accentSoft : Color.clear)
            .overlay(alignment: .bottom) { ThemeRule() }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if showingArchive {
                Button("Restore", .restore) { Task { await model.archiveNote(note, archived: false) } }
            } else {
                Button("Make a task", .move) { converting = note }
                Button("Archive", .archive) { Task { await model.archiveNote(note, archived: true) } }
            }
        }
    }

    private func row(_ note: TodoCard) -> some View {
        let selected = model.selectedCardID == note.id
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_note", tint: Theme.secondary, size: 22)
                Label(placeName(for: note), systemImage: "folder")
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Menu {
                    Button("Open note", .edit) { model.selectCard(note.id) }
                    if showingArchive {
                        Button("Restore", .restore) { Task { await model.archiveNote(note, archived: false) } }
                    } else {
                        Button("Make a task", .move) { converting = note }
                        Divider()
                        Button("Archive", .archive) { Task { await model.archiveNote(note, archived: true) } }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.accent)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Note actions")
            }
            HStack(alignment: .top, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    // Not selectable any more. Selectable text hit-tests the
                    // click for a selection, which is most of this card's
                    // surface: pressing a note where somebody naturally
                    // presses it did nothing, and only the padding around the
                    // words opened the pane. The pane is where the text can be
                    // read and copied now.
                    Text(note.title)
                        .font(Theme.font(15, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !note.notes.isEmpty {
                        Text(note.notes)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(gridLayout ? 5 : 2)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: Theme.Space.s)
            ThemeRule().opacity(0.5)
            HStack {
                RelativeTimeText(
                    date: Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000),
                    unitsStyle: .abbreviated
                )
                .font(Theme.caption2).foregroundStyle(.secondary)
                .help(Date(timeIntervalSince1970: Double(note.createdAtMs) / 1000).formatted(date: .long, time: .shortened))
                Spacer()
                if showingArchive {
                    Button("Restore", .restore) { Task { await model.archiveNote(note, archived: false) } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                } else {
                    Button("Make a task", .move) { converting = note }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: gridLayout ? 185 : nil, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.m)
        .background(
            selected ? Theme.accentSoft : Theme.panel,
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1)
        }
        // The whole card, not a disclosure control. A note is one paragraph
        // and the pane beside it is where the rest of it is, so reaching that
        // pane has to be the ordinary thing pressing a note does.
        .contentShape(.rect)
        .onTapGesture { model.selectCard(note.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open note") { model.selectCard(note.id) }
    }

    private func placeName(for note: TodoCard) -> String {
        if note.workspaceID.isEmpty { return "Unassigned" }
        return folders.first { $0.id == note.workspaceID }?.name ?? "Folder"
    }

    private func save() {
        guard !saving, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        let folderID = destinationID
        saving = true
        Task {
            let saved = await model.addNote(text, workspaceID: folderID)
            // Keep edits made while saving; a failed save keeps the whole draft.
            if saved, draft == text { draft = "" }
            saving = false
            writing = true
        }
    }
}

/// Pick a folder, then the note becomes a card on that board.
///
/// Capture stays cheap because this decision happens later, in a panel that
/// says what it is doing, not a hidden menu of folder names.
///
/// Not private: the list offers this on a row and the inspector offers it on
/// the selected note, and two copies of one sheet is how they end up asking
/// different questions.
struct ConvertNoteSheet: View {
    let note: TodoCard
    let folders: [WorkspaceFolder]
    let onConvert: (String) -> Void
    let onCancel: () -> Void

    @State private var folderID = ""

    var body: some View {
        ThemedSheet(
            title: "Make a task",
            subtitle: "This note becomes a card on the board. Pick a folder, or leave it unassigned.",
            icon: .move,
            onClose: onCancel
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text(note.title)
                    .font(Theme.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Folder")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
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
                }
            }
        } actions: {
            Button("Cancel", .dismiss, role: .cancel) { onCancel() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Make a task", .move) { onConvert(folderID) }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 520, height: 440)
        .onAppear {
            folderID = note.workspaceID
        }
    }
}
