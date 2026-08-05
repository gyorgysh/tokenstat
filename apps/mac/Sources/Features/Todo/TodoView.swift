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

    /// Which column's new-card form is open. Held here, not in the form, so a
    /// column's trigger and its form drive the same flag.
    @State private var addingIn: String?

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
                // Three columns side by side where the window allows it,
                // shrinking together on a narrow window instead of one fixed
                // 300pt column overflowing the pane.
                let columnWidth = max(
                    DisplayFit.scale(240),
                    min(
                        DisplayFit.scale(300),
                        (proxy.size.width - Theme.Space.m * 4) / 3
                    )
                )
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        ForEach(Self.columns, id: \.0) { id, label in
                            // Every column takes the height of the fullest one,
                            // so the board is three columns rather than three
                            // unrelated boxes, and drop targets stay the same
                            // size whichever column a card is dragged from.
                            column(id, label, width: columnWidth)
                                .frame(height: boardHeight(available: available))
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .onPreferenceChange(ColumnHeightKey.self) { tallestColumn = $0 }
            }
        }
        .background(Theme.background)
        .navigationTitle("Tasks")
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

    private func column(_ id: String, _ label: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: id == "doing" ? "mark_automation" : (id == "done" ? "mark_note" : "mark_todo"), tint: tint(for: id))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                    Text("\(model.cards(in: id).count) card\(model.cards(in: id).count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)

            AddCardTrigger(
                expanded: Binding(
                    get: { addingIn == id },
                    set: { open in
                        if open { addingIn = id } else if addingIn == id { addingIn = nil }
                    }
                )
            )

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

            NewCardForm(
                model: model,
                folders: folders,
                column: id,
                expanded: Binding(
                    get: { addingIn == id },
                    set: { open in
                        if open { addingIn = id } else if addingIn == id { addingIn = nil }
                    }
                )
            )
        }
        .frame(width: width)
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
        // The header, the add-card row above the list, the new-card form under
        // the backlog column, and the padding around the stack. Added so a
        // column that has just enough cards to fill the window does not end up
        // with its form cut off.
        let chrome: CGFloat = 182
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
                // A task's notes are the prompt the agent gets; only a plain
                // note card calls them notes.
                TextField(card.isNote ? "Note" : "Prompt", text: $notesDraft, axis: .vertical)
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
                Text(card.isNote ? "Click to add a note" : "Click to add a prompt")
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
                        if card.budgetSeconds > 0 {
                            Label(Self.budgetLabel(card.budgetSeconds), systemImage: "timer")
                                .foregroundStyle(.tertiary)
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

    private static func budgetLabel(_ seconds: UInt64) -> String {
        seconds % 60 == 0
            ? "\(seconds / 60)m budget"
            : "\(seconds)s budget"
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

/// The full-width row that opens the new-card form.
///
/// One of these sits above the card list and one below it, both driving the
/// same `expanded` flag, so a long backlog never has to be scrolled to reach
/// the way to add to it. Full width and with a hit shape of its own: the old
/// control was a bare `Label`, so only the glyph and the two words were
/// clickable, on a column 300pt wide.
private struct AddCardTrigger: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Label(
                expanded ? "New card" : "Add a card",
                systemImage: expanded ? "chevron.up" : "plus"
            )
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(
                Theme.background.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct NewCardForm: View {
    @Bindable var model: TodoModel
    var folders: [WorkspaceFolder]
    /// Which column the card lands in. Passed in so each column's form creates
    /// straight into that column instead of everything going to backlog.
    var column: String
    /// Shared with the trigger above the card list, so only one form is ever
    /// open and either row closes it.
    @Binding var expanded: Bool

    @State private var title = ""
    @State private var notes = ""
    @State private var backendID = ""
    @State private var workspaceID = ""
    /// Minutes, because that is the unit people think in. Converted to seconds
    /// for the daemon, which stores the raw number.
    @State private var budgetMinutes = "15"
    @State private var kind: TodoKind = .task

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            AddCardTrigger(expanded: $expanded)

            if expanded {
                Picker("Type", selection: $kind) {
                    Label("Task", systemImage: "checkmark.square").tag(TodoKind.task)
                    Label("Note", systemImage: "note.text").tag(TodoKind.note)
                }
                .pickerStyle(.segmented)
                TextField(kind == .note ? "What do you want to remember?" : "Task title", text: $title)
                TextField(kind == .note ? "Note" : "Prompt", text: $notes, axis: .vertical)
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
                    HStack(spacing: Theme.Space.xs) {
                        Text("Budget")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("15", text: $budgetMinutes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Text("minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        let minutes = UInt64(budgetMinutes) ?? 15
        await model.create(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            notes: notes,
            backend: backendID,
            workspaceID: kind == .note ? "" : workspaceID,
            budgetSeconds: minutes * 60,
            column: kind == .note ? "backlog" : column
        )
        if model.errorMessage == nil { cancel() }
    }

    private func cancel() {
        title = ""
        notes = ""
        workspaceID = ""
        budgetMinutes = "15"
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
