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
    /// Open a delegated run's transcript on the Automations screen.
    var onViewRun: ((String) -> Void)? = nil

    private static let columns: [(String, String)] = [
        ("backlog", "To Do"), ("doing", "Doing"), ("done", "Done"),
    ]
    @AppStorage("todo.sortNewestFirst") private var newestFirst = true
    @State private var dropTarget: String?
    /// Card id the drag would land before, or "__end__".
    @State private var dropBeforeID: String?
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
            DetailChromeBar {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Add a card to To Do"
                ) {
                    addingIn = "backlog"
                }
                Picker("Order", selection: $newestFirst) {
                    Text("Newest").tag(true)
                    Text("Your order").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: newestFirst) { _, on in
                    model.sortNewestFirst = on
                }
            }
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
                    DisplayFit.box(240),
                    min(
                        DisplayFit.box(300),
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
        .task {
            model.sortNewestFirst = newestFirst
            await model.appeared()
        }
        .onChange(of: model.sortNewestFirst) { _, on in
            newestFirst = on
        }
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
                        if dropTarget == id && dropBeforeID == card.id {
                            insertionLine
                        }
                        CardView(
                            model: model,
                            card: card,
                            folders: folders,
                            isSelected: model.selectedCardID == card.id,
                            onSelect: { model.selectCard(card.id) },
                            onViewRun: onViewRun,
                            onDropBefore: { dragged in
                                guard dragged.id != card.id else { return }
                                let list = model.cards(in: id).filter { $0.id != dragged.id }
                                let order = Int64(list.firstIndex(where: { $0.id == card.id }) ?? list.count)
                                Task { await model.reorder(dragged, to: id, order: order) }
                            },
                            onTargeted: { on in
                                if on {
                                    dropTarget = id
                                    dropBeforeID = card.id
                                }
                            }
                        )
                    }
                    if dropTarget == id && dropBeforeID == "__end__" {
                        insertionLine
                    }
                    if isWarming {
                        // Card-shaped grey, so the columns are already the
                        // right width and the board does not jump when the
                        // real cards land. Backlog gets more of them because
                        // that is where cards usually are. Sharp, then fade.
                        ForEach(0..<(id == "backlog" ? 3 : 1), id: \.self) { _ in
                            Skeleton.CardPlaceholder(rows: 2)
                        }
                        .transition(.opacity)
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
            let others = model.cards(in: id).filter { $0.id != card.id }.count
            Task { await model.reorder(card, to: id, order: Int64(others)) }
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = id
                dropBeforeID = "__end__"
            } else if dropTarget == id {
                dropTarget = nil
                dropBeforeID = nil
            }
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(height: 2)
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
    @State private var confirmingDelete = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var delegating = false
    @FocusState private var titleFocused: Bool
    @Bindable var model: TodoModel
    var card: TodoCard
    var folders: [WorkspaceFolder]
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    /// Opens the run's transcript on the Automations screen.
    var onViewRun: ((String) -> Void)?
    var onDropBefore: ((TodoCard) -> Void)?
    var onTargeted: ((Bool) -> Void)?

    private var tint: Color {
        switch card.delegate?.status {
        case "queued", "running": return Theme.accent
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
                        .focused($titleFocused)
                        .onSubmit { saveTitle() }
                        .onChange(of: titleFocused) { _, on in
                            if !on { saveTitle() }
                        }
                } else {
                    Text(card.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .onTapGesture {
                            onSelect()
                            titleDraft = card.title
                            editingTitle = true
                            titleFocused = true
                        }
                }
                Spacer()
                if card.priority == "high" {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.warning)
                }
            }
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        if card.budgetSeconds == 0 {
                            Label("No time limit", systemImage: "timer")
                                .foregroundStyle(.tertiary)
                        } else {
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
        .background(
            (isSelected ? Theme.rowSelected : Theme.background),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(
                    isSelected ? Theme.accent.opacity(0.45)
                        : (card.delegate == nil ? Theme.border : tint.opacity(0.4)),
                    lineWidth: 1
                )
        )
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .draggable(card.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let cardID = ids.first,
                  let dragged = model.cards.first(where: { $0.id == cardID }) else { return false }
            onDropBefore?(dragged)
            return true
        } isTargeted: { on in
            onTargeted?(on)
        }
        .sheet(isPresented: $delegating) {
            DelegateSheet(model: model, card: card, folders: folders)
        }
    }

    private func saveTitle() {
        editingTitle = false
        Task { await model.updateTitle(card, title: titleDraft) }
    }

    private static func budgetLabel(_ seconds: UInt64) -> String {
        seconds % 60 == 0
            ? "\(seconds / 60)m time limit"
            : "\(seconds)s time limit"
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
            // The result lives on the Automations screen; this is the door to
            // it, so a delegated card is never a dead end that only says
            // "Done" with nowhere to look.
            Button("View result") {
                onViewRun?(delegate.runId)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Open this run's transcript on the Automations screen")
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
                    delegating = true
                }
            }
            Button("Delete", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .confirmationDialog(
            "Delete this card?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.remove(card) } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The card is removed from the board. This cannot be undone.")
        }
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
    /// The selected backend's model alias and effort level. Empty means the
    /// backend's default, which is also what the pickers start on.
    @State private var modelChoice = ""
    @State private var effortChoice = ""
    /// Minutes, because that is the unit people think in. Converted to seconds
    /// for the daemon, which stores the raw number.
    @State private var budgetMinutes = "180"
    @State private var noTimeLimit = false
    @State private var kind: TodoKind = .task

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            AddCardTrigger(expanded: $expanded)

            if expanded {
                SegmentedCapsulePicker(
                    options: [
                        (TodoKind.task, "Task", "checkmark.square"),
                        (TodoKind.note, "Note", "note.text"),
                    ],
                    selection: $kind
                )
                TextField(kind == .note ? "What do you want to remember?" : "Task title", text: $title)
                // A task's notes are what the agent gets. For the Shell
                // backend that is a command, not a prompt, so the field says
                // so and its placeholder answers the only question a shell
                // has: what do I run?
                TextField(
                    kind == .note ? "Note" : (isShellBackend ? "Command" : "Prompt"),
                    text: $notes,
                    prompt: Text(
                        isShellBackend
                            ? "Command to run, e.g. npm test"
                            : "What should the agent do?"
                    ),
                    axis: .vertical
                )
                .lineLimit(2...4)
                if kind == .task {
                    HStack(spacing: Theme.Space.s) {
                        AppMenuPicker(
                            title: "Agent",
                            options: [(value: "", label: "Choose later")]
                                + model.backends.map { (value: $0.id, label: $0.label) },
                            selection: $backendID
                        )
                        AppMenuPicker(
                            title: "Workspace",
                            options: [(value: "", label: "Choose later")]
                                + folders.map { (value: $0.id, label: $0.name) },
                            selection: $workspaceID
                        )
                    }
                    // Model and effort exist only for backends that advertise
                    // them, so the pair appears for Claude and never for
                    // Shell. Both start on the backend's default.
                    if let backend = selectedBackend,
                       !backend.models.isEmpty || !backend.efforts.isEmpty {
                        HStack(spacing: Theme.Space.s) {
                            if !backend.models.isEmpty {
                                AppMenuPicker(
                                    title: "Model",
                                    options: [(value: "", label: "Default")]
                                        + backend.models.map { (value: $0, label: $0) },
                                    selection: $modelChoice
                                )
                            }
                            if !backend.efforts.isEmpty {
                                AppMenuPicker(
                                    title: "Effort",
                                    options: [(value: "", label: "Default")]
                                        + backend.efforts.map { (value: $0, label: $0) },
                                    selection: $effortChoice
                                )
                            }
                        }
                    }
                    HStack(spacing: Theme.Space.xs) {
                        Text("Time limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("180", text: $budgetMinutes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                            .disabled(noTimeLimit)
                        Text("minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("No limit", isOn: $noTimeLimit)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
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
            budgetMinutes = model.defaultBudgetMinutes
            noTimeLimit = model.defaultNoLimit
        }
        .onChange(of: backendID) { _, _ in
            // A model that meant something to one backend means nothing to
            // the next; go back to defaults when the agent changes.
            modelChoice = ""
            effortChoice = ""
        }
    }

    private var selectedBackend: AgentBackend? {
        model.backends.first { $0.id == backendID }
    }

    private var isShellBackend: Bool {
        selectedBackend?.id == "sh"
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let minutes = UInt64(budgetMinutes) ?? 180
        let budget: UInt64 = noTimeLimit ? 0 : minutes * 60
        await model.create(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            notes: notes,
            backend: backendID,
            workspaceID: kind == .note ? "" : workspaceID,
            budgetSeconds: budget,
            column: kind == .note ? "backlog" : column,
            model: modelChoice.isEmpty ? nil : modelChoice,
            effort: effortChoice.isEmpty ? nil : effortChoice
        )
        if model.errorMessage == nil { cancel() }
    }

    private func cancel() {
        title = ""
        notes = ""
        workspaceID = ""
        budgetMinutes = model.defaultBudgetMinutes
        noTimeLimit = model.defaultNoLimit
        backendID = ""
        expanded = false
        kind = .task
    }
}

/// Last-minute agent pick before a card is handed to a run.
struct DelegateSheet: View {
    @Bindable var model: TodoModel
    var card: TodoCard
    var folders: [WorkspaceFolder]
    @Environment(\.dismiss) private var dismiss

    @State private var backendID = ""
    @State private var workspaceID = ""
    @State private var modelChoice = ""
    @State private var effortChoice = ""
    @State private var budgetMinutes = "180"
    @State private var noTimeLimit = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Delegate to agent")
                .font(.system(size: 17, weight: .semibold))
            Text(card.title)
                .font(.callout)
                .foregroundStyle(.secondary)
            AppMenuPicker(
                title: "Agent",
                options: model.backends.map { (value: $0.id, label: $0.label) },
                selection: $backendID
            )
            AppMenuPicker(
                title: "Workspace",
                options: [(value: "", label: "Choose workspace")]
                    + folders.map { (value: $0.id, label: $0.name) },
                selection: $workspaceID
            )
            if let backend = model.backends.first(where: { $0.id == backendID }),
               !backend.models.isEmpty || !backend.efforts.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    if !backend.models.isEmpty {
                        AppMenuPicker(
                            title: "Model",
                            options: [(value: "", label: "Default")]
                                + backend.models.map { (value: $0, label: $0) },
                            selection: $modelChoice
                        )
                    }
                    if !backend.efforts.isEmpty {
                        AppMenuPicker(
                            title: "Effort",
                            options: [(value: "", label: "Default")]
                                + backend.efforts.map { (value: $0, label: $0) },
                            selection: $effortChoice
                        )
                    }
                }
            }
            HStack {
                Text("Time limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("180", text: $budgetMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .disabled(noTimeLimit)
                Text("minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("No limit", isOn: $noTimeLimit)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Run") {
                    working = true
                    Task { await run() }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!canRun || working)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 420)
        .onAppear {
            backendID = card.backend
            workspaceID = card.workspaceID
            modelChoice = card.model ?? ""
            effortChoice = card.effort ?? ""
            noTimeLimit = card.budgetSeconds == 0
            if card.budgetSeconds > 0 {
                budgetMinutes = String(max(1, card.budgetSeconds / 60))
            }
            if backendID.isEmpty, let first = model.backends.first {
                backendID = first.id
            }
        }
    }

    private var canRun: Bool {
        !backendID.isEmpty && !workspaceID.isEmpty
    }

    private func run() async {
        let minutes = UInt64(budgetMinutes) ?? 180
        let budget: UInt64 = noTimeLimit ? 0 : minutes * 60
        let saved = await model.updateCard(
            card,
            backend: backendID,
            model: modelChoice.isEmpty ? nil : modelChoice,
            effort: effortChoice.isEmpty ? nil : effortChoice,
            workspaceID: workspaceID,
            budgetSeconds: budget
        )
        guard saved, let latest = model.cards.first(where: { $0.id == card.id }) else { return }
        await model.delegate(latest)
        working = false
        if model.errorMessage == nil { dismiss() }
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
