// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// A kanban board of work. A card is tracked here; delegating it hands it to an
/// agent on the chosen backend, and the run's transcript shows up in the
/// Automations screen.
struct TodoView: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]

    private static let columns: [(String, String)] = [
        ("backlog", "To Do"), ("doing", "Doing"), ("done", "Done"),
    ]
    @State private var dropTarget: String?
    /// The tallest stack of cards on the board, measured.
    @State private var tallestColumn: CGFloat = 0

    /// How much of the window an empty board takes.
    ///
    /// Three columns stretched to the full height of a large window is a lot of
    /// empty panel for a board with nothing on it. Just over half reads as a
    /// board rather than as three empty walls, and the columns grow from there
    /// as cards arrive.
    private let restingFraction: CGFloat = 0.55

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(Theme.Space.m)
            }
            GeometryReader { proxy in
                let available = proxy.size.height - Theme.Space.m * 2
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(Self.columns, id: \.0) { id, label in
                            // Every column takes the height of the fullest one,
                            // so the board is three columns rather than three
                            // unrelated boxes, and drop targets stay the same
                            // size whichever column a card is dragged from.
                            column(id, label)
                                .frame(height: boardHeight(available: available))
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .onPreferenceChange(ColumnHeightKey.self) { tallestColumn = $0 }
            }
        }
        .background(Theme.background)
        .navigationTitle("Todo")
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task { await model.appeared() }
        // The model outlives this view, and its poll loop must not.
        .onDisappear { model.disappeared() }
    }

    /// Waiting on the first read of the board.
    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
    }

    private func column(_ id: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: id == "doing" ? "mark_automation" : (id == "done" ? "mark_note" : "mark_todo"), tint: tint(for: id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(model.cards(in: id).count) card\(model.cards(in: id).count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)

            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(model.cards(in: id)) { card in
                        CardView(model: model, card: card, folders: folders)
                    }
                    if isWarming {
                        // Card-shaped grey, so the columns are already the
                        // right width and the board does not jump when the
                        // real cards land. Backlog gets more of them because
                        // that is where cards usually are.
                        ForEach(0..<(id == "backlog" ? 3 : 1), id: \.self) { _ in
                            Skeleton.CardPlaceholder(rows: 2)
                        }
                        .warming(true)
                    } else if model.cards(in: id).isEmpty {
                        Text(id == "done" ? "Nothing done yet" : "No cards")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.xl)
                    }
                }
                // Measured inside the scroll view, so this is the height the
                // cards want rather than the height the column was given.
                // Measuring the column itself would report what was just set
                // and the board would never settle.
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ColumnHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(maxWidth: .infinity)

            if id == "backlog" {
                NewCardForm(model: model, folders: folders)
            }
        }
        .frame(width: 300)
        .padding(Theme.Space.s)
        .background(
            Theme.panel.opacity(dropTarget == id ? 0.82 : 1),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(dropTarget == id ? Theme.accent : Theme.border, lineWidth: 1)
        )
        .dropDestination(for: String.self) { ids, _ in
            guard let cardID = ids.first,
                  let card = model.cards.first(where: { $0.id == cardID }) else { return false }
            Task { await model.reorder(card, to: id, order: Int64(model.cards(in: id).count)) }
            return true
        } isTargeted: { targeted in
            // The column's background stays calm until a card is actually over
            // it. The drop target itself supplies the interaction affordance.
            if targeted {
                dropTarget = id
            } else if dropTarget == id {
                dropTarget = nil
            }
        }
    }

    /// The height every column takes: what the fullest one needs, never less
    /// than the resting share of the window and never more than all of it.
    private func boardHeight(available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        // The header, the new-card form under the backlog column, and the
        // padding around the stack. Added so a column that has just enough
        // cards to fill the window does not end up with its form cut off.
        let chrome: CGFloat = 150
        let resting = available * restingFraction
        return min(available, max(resting, tallestColumn + chrome))
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "doing": return "bolt.fill"
        case "done": return "checkmark.circle.fill"
        default: return "tray"
        }
    }

    private func tint(for id: String) -> Color {
        switch id {
        case "doing": return Theme.secondary
        case "done": return Theme.success
        default: return Theme.accent
        }
    }
}

// MARK: - One card

private struct CardView: View {
    @Bindable var model: TodoModel
    var card: TodoCard
    var folders: [WorkspaceFolder]

    @State private var editingTitle = false
    @State private var editingNotes = false
    @State private var titleDraft = ""
    @State private var notesDraft = ""

    private var tint: Color {
        switch card.delegate?.status {
        case "running": return Theme.accent
        case "ok": return Theme.success
        case "error": return Theme.danger
        case "stopped": return Theme.warning
        default: return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                FeatureMark(name: card.isNote ? "mark_note" : "mark_todo",
                            tint: card.isNote ? Theme.secondary : Theme.accent,
                            size: 16)
                if editingTitle {
                    TextField("Title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .onSubmit { saveTitle() }
                } else {
                    Text(card.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .onTapGesture {
                            titleDraft = card.title
                            editingTitle = true
                        }
                }
                Spacer()
                if card.priority == "high" {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.warning)
                }
            }
            if editingNotes {
                TextField("Note", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(2...4)
                    .onSubmit { saveNotes() }
            } else if !card.notes.isEmpty {
                Text(card.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        notesDraft = card.notes
                        editingNotes = true
                    }
            } else {
                Text(card.isNote ? "Click to add a note" : "Click to add a note")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .onTapGesture {
                        notesDraft = ""
                        editingNotes = true
                    }
            }
            if let delegate = card.delegate {
                delegateStatus(delegate)
            }
            HStack(spacing: Theme.Space.xs) {
                Group {
                    if card.isNote {
                        Label("Note", systemImage: "bookmark")
                    } else {
                        Label(model.backends.first { $0.id == card.backend }?.label ?? card.backend,
                              systemImage: "cpu")
                        if let folder = folders.first(where: { $0.id == card.workspaceID }) {
                            Text(folder.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .font(.caption2)
                Spacer()
                controls
            }
        }
        .padding(Theme.Space.s)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(card.delegate == nil ? Theme.border : tint.opacity(0.4), lineWidth: 1)
        )
        .onExitCommand {
            editingTitle = false
            editingNotes = false
        }
        .onAppear {
            titleDraft = card.title
            notesDraft = card.notes
        }
        .draggable(card.id)
    }

    private func saveTitle() {
        editingTitle = false
        Task { await model.updateTitle(card, title: titleDraft) }
    }

    private func saveNotes() {
        editingNotes = false
        Task { await model.updateNotes(card, notes: notesDraft) }
    }

    private func delegateStatus(_ delegate: TodoDelegate) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if delegate.isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(delegate.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            if let error = delegate.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
            if delegate.isRunning {
                Button("Stop") { Task { await model.stop(card) } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        Menu {
            if card.column != "backlog" {
                Button("Move to To Do") { Task { await model.move(card, to: "backlog") } }
            }
            if card.column != "doing" {
                Button("Move to Doing") { Task { await model.move(card, to: "doing") } }
            }
            if card.column != "done" {
                Button("Move to Done") { Task { await model.move(card, to: "done") } }
            }
            Divider()
            if !card.isNote {
                Button("Delegate to agent", systemImage: "paperplane") {
                    Task { await model.delegate(card) }
                }
            }
            Button("Delete", role: .destructive) { Task { await model.remove(card) } }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - New card

private struct NewCardForm: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]

    @State private var title = ""
    @State private var notes = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var budget = "900"
    @State private var expanded = false
    @State private var kind: TodoKind = .task

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                expanded.toggle()
            } label: {
                Label(expanded ? "New card" : "Add a card", systemImage: expanded ? "chevron.up" : "plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)

            if expanded {
                Picker("Type", selection: $kind) {
                    Label("Task", systemImage: "checkmark.square").tag(TodoKind.task)
                    Label("Note", systemImage: "note.text").tag(TodoKind.note)
                }
                .pickerStyle(.segmented)
                TextField(kind == .note ? "What do you want to remember?" : "Task title", text: $title)
                TextField("Note", text: $notes, axis: .vertical)
                    .lineLimit(2...4)
                if kind == .task {
                    HStack(spacing: Theme.Space.xs) {
                        Picker("Agent", selection: $backendID) {
                            ForEach(model.backends) { backend in
                                Text(backend.label).tag(backend.id)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Picker("Workspace", selection: $workspaceID) {
                            Text("Choose workspace").tag("")
                            ForEach(folders) { folder in
                                Text(folder.name).tag(folder.id)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    HStack {
                        TextField("Budget seconds", text: $budget)
                            .frame(width: 110)
                        Spacer()
                    }
                }
                HStack {
                    Button("Cancel") { cancel() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Save") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind == .note || (!workspaceID.isEmpty && !backendID.isEmpty))
    }

    private func save() async {
        await model.create(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            notes: notes,
            backend: backendID,
            workspaceID: kind == .note ? "" : workspaceID,
            budgetSeconds: UInt64(budget) ?? 900
        )
        if model.errorMessage == nil { cancel() }
    }

    private func cancel() {
        title = ""
        notes = ""
        workspaceID = ""
        expanded = false
        kind = .task
    }
}

/// The tallest stack of cards on the board.
///
/// Max rather than sum: the columns are alternatives, not a list, and the board
/// takes the height of whichever one has the most in it.
private struct ColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
