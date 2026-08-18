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
    /// Spawn an interactive terminal for this card. Not an automation.
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)? = nil

    private static let columns: [(String, String)] = [
        ("backlog", "To Do"), ("doing", "Doing"), ("done", "Done"),
    ]
    @AppStorage("todo.sortNewestFirst") private var newestFirst = true
    @State private var dropTarget: String?
    /// Card id the drag would land before, or "__end__".
    @State private var dropBeforeID: String?
    /// The tallest stack of cards on the board, measured.
    @State private var tallestColumn: CGFloat = 0
    /// Scroll-view height per column, so empty space under the cards is a drop target.
    @State private var columnBodyHeights: [String: CGFloat] = [:]

    /// Which column's new-card form is open. Held here, not in the form, so a
    /// column's trigger and its form drive the same flag.
    @State private var addingIn: String?

    /// A value the menu can hold. Not a folder id anyone could own: ids are
    /// paths or `remote:…`, and neither starts with two underscores.
    private static let unfiledValue = "__unfiled__"

    private static func value(of scope: TodoScope) -> String {
        switch scope {
        case .all: return ""
        case .inbox: return unfiledValue
        case let .workspace(id): return id
        }
    }

    private static func filter(from value: String) -> TodoScope {
        switch value {
        case "": return .all
        case unfiledValue: return .inbox
        default: return .workspace(value)
        }
    }

    /// The folder this board is scoped to, named on the chrome bar.
    private var scopeChip: ScopeChip? {
        guard let id = model.scope else { return nil }
        guard let folder = folders.first(where: { $0.id == id }) else { return nil }
        return ScopeChip(
            label: folder.isRemote
                ? "\(folder.machineLabel ?? "Remote") / \(folder.name)"
                : folder.name,
            symbol: folder.isRemote ? "network" : "folder.fill"
        )
    }

    /// How much of the window an empty board takes.
    ///
    /// Three columns stretched to the full height of a large window is a lot of
    /// empty panel for a board with nothing on it. Just over half reads as a
    /// board rather than as three empty walls, and the columns grow from there
    /// as cards arrive.
    private let restingFraction: CGFloat = 0.55

    var body: some View {
        VStack(spacing: 0) {
            DetailChromeBar(scope: scopeChip) {
                if model.scope == nil {
                    // Only the global board gets a selector. A folder's board
                    // is that folder's, and a filter on top of it would be two
                    // answers to one question.
                    AppMenuPicker(
                        options: [
                            (value: "", label: "All workspaces"),
                            (
                                value: Self.unfiledValue,
                                label: "Uncategorized"
                                    + (model.unfiledCount > 0 ? " (\(model.unfiledCount))" : "")
                            ),
                        ] + folders.map { (value: $0.id, label: $0.name) },
                        selection: Binding(
                            get: { Self.value(of: model.filter) },
                            set: { model.filter = Self.filter(from: $0) }
                        )
                    )
                    .frame(maxWidth: 200)
                }
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Add a card to To Do"
                ) {
                    addingIn = "backlog"
                }
                SegmentedCapsulePicker(
                    options: [
                        (true, "Newest", ""),
                        (false, "Your order", ""),
                    ],
                    selection: $newestFirst
                )
                .frame(maxWidth: 220)
                .onChange(of: newestFirst) { _, on in
                    model.sortNewestFirst = on
                }
                ToolbarIconButton(
                    systemImage: model.showingArchive ? "archivebox.fill" : "archivebox",
                    help: model.showingArchive
                        ? "Show Done"
                        : (model.archivedCount == 0
                            ? "No archived cards"
                            : "Show \(model.archivedCount) archived card\(model.archivedCount == 1 ? "" : "s")"),
                    isAccent: model.showingArchive,
                    showsBadge: model.archivedCount > 0 && !model.showingArchive
                ) {
                    model.showingArchive.toggle()
                }
                .disabled(model.archivedCount == 0 && !model.showingArchive)
            }
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(Theme.Space.m)
            }
            notesStrip
            GeometryReader { proxy in
                let available = proxy.size.height - Theme.Space.m * 2
                let gap = Theme.Space.m
                let usable = proxy.size.width - Theme.Space.m * 4
                // Three columns only when they stay readable. A 240 floor
                // overflowed a tiled half-screen. Below that, stack them.
                let minCol: CGFloat = 160
                let sideBySide = usable >= minCol * 3 + gap * 2
                let columnWidth = sideBySide
                    ? min(DisplayFit.box(300), (usable - gap * 2) / 3)
                    : max(minCol, usable)
                ScrollView(sideBySide ? .horizontal : .vertical) {
                    let columns = ForEach(Self.columns, id: \.0) { id, label in
                        column(id, label, width: columnWidth)
                            .frame(height: sideBySide ? boardHeight(available: available) : nil)
                    }
                    Group {
                        if sideBySide {
                            HStack(alignment: .top, spacing: gap) { columns }
                        } else {
                            VStack(alignment: .leading, spacing: gap) { columns }
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
            TransientToast(
                message: $model.noticeMessage,
                severity: .success,
                actionLabel: model.noticeScope == nil ? nil : "Show",
                action: model.noticeScope.map { scope in
                    { model.filter = scope }
                }
            )
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

    /// The notes for this scope, across the top of the board.
    ///
    /// One strip rather than a fourth column: a note is something to remember,
    /// not a stage of work, and it never moves left to right. Hidden entirely
    /// when there are none, so a board of pure tasks looks like one.
    @ViewBuilder
    private var notesStrip: some View {
        let notes = model.notes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    FeatureMark(name: "mark_note", tint: Theme.secondary)
                    Text("Notes")
                        .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                    Text("\(notes.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        ForEach(notes) { note in
                            CardView(
                                model: model,
                                card: note,
                                folders: folders,
                                isSelected: model.selectedCardID == note.id,
                                onSelect: { model.selectCard(note.id) },
                                onViewRun: onViewRun,
                                onRunInFront: onRunInFront,
                                onDropBefore: { _ in },
                                onTargeted: { _ in }
                            )
                            .frame(width: DisplayFit.box(240))
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
        }
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
                    Text(columnTitle(id, label))
                        .font(.system(size: DisplayFit.dp(13), weight: .semibold))
                    Text("\(model.cards(in: id).count) card\(model.cards(in: id).count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)

            if !(id == "done" && model.showingArchive) {
                AddCardTrigger(
                    expanded: Binding(
                        get: { addingIn == id },
                        set: { open in
                            if open { addingIn = id } else if addingIn == id { addingIn = nil }
                        }
                    )
                )
            }

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
                            onRunInFront: onRunInFront,
                            onDropBefore: { dragged in
                                guard dragged.id != card.id else { return }
                                let list = model.cards(in: id).filter { $0.id != dragged.id }
                                let order = Int64(list.firstIndex(where: { $0.id == card.id }) ?? list.count)
                                clearDropChrome()
                                Task { await model.reorder(dragged, to: model.storageColumn(id), order: order) }
                            },
                            onTargeted: { on in
                                if on {
                                    dropTarget = id
                                    dropBeforeID = card.id
                                } else if dropTarget == id && dropBeforeID == card.id {
                                    clearDropChrome()
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
                        Text(emptyCopy(for: id))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.xl)
                    }
                    // Empty space under the last card is a drop target. The
                    // outer column destination only wins on the header.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .dropDestination(for: String.self) { ids, _ in
                            dropOnColumn(ids, column: id)
                        } isTargeted: { targeted in
                            if targeted {
                                dropTarget = id
                                dropBeforeID = "__end__"
                            } else if dropTarget == id && dropBeforeID == "__end__" {
                                clearDropChrome()
                            }
                        }
                }
                .frame(minHeight: columnBodyHeights[id] ?? 0, alignment: .top)
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
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ColumnBodyHeightKey.self,
                        value: [id: proxy.size.height]
                    )
                }
            )
            .onPreferenceChange(ColumnBodyHeightKey.self) { next in
                columnBodyHeights.merge(next, uniquingKeysWith: { _, n in n })
            }
            .frame(maxWidth: .infinity)

            if !(id == "done" && model.showingArchive) {
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
            dropOnColumn(ids, column: id)
        } isTargeted: { targeted in
            if targeted {
                dropTarget = id
                dropBeforeID = "__end__"
            } else if dropTarget == id {
                clearDropChrome()
            }
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(height: 2)
    }

    /// Drop highlight is local to the pointer. A same-column drop never
    /// leaves the column, so `isTargeted(false)` on the column does not fire
    /// and the insertion line would stay without this.
    private func clearDropChrome() {
        dropTarget = nil
        dropBeforeID = nil
    }

    /// Append a dragged card to this column. Shared by header chrome and the
    /// empty space under the last card.
    private func dropOnColumn(_ ids: [String], column: String) -> Bool {
        guard let cardID = ids.first,
              let card = model.cards.first(where: { $0.id == cardID }) else { return false }
        let others = model.cards(in: column).filter { $0.id != card.id }.count
        Task { await model.reorder(card, to: model.storageColumn(column), order: Int64(others)) }
        clearDropChrome()
        return true
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

    private func columnTitle(_ id: String, _ label: String) -> String {
        if id == "done", model.showingArchive { return "Archive" }
        return label
    }

    private func emptyCopy(for id: String) -> String {
        if id == "done" {
            return model.showingArchive ? "Nothing archived" : "Nothing done yet"
        }
        return "No cards"
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
    @State private var titleSaveState: FieldSaveState = .idle
    @State private var delegating = false
    /// A drop onto this card also looks like a tap. Ignore that one so the
    /// inspector stays on the card that moved, not the one it landed on.
    @State private var ignoreNextTap = false
    @FocusState private var titleFocused: Bool
    @Bindable var model: TodoModel
    var card: TodoCard
    var folders: [WorkspaceFolder]
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    /// Opens the run's transcript on the Automations screen.
    var onViewRun: ((String) -> Void)?
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)?
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
                        .onChange(of: titleDraft) { _, value in
                            if value != card.title {
                                titleSaveState = .dirty
                            }
                        }
                        .onChange(of: titleFocused) { _, on in
                            if !on { saveTitle() }
                        }
                    if titleSaveState == .dirty || titleSaveState == .failed {
                        Button {
                            cancelTitle()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Discard title")
                        Button {
                            saveTitle()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Save title")
                    } else if titleSaveState == .saving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if titleSaveState == .saved {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.success)
                            .help("Saved")
                    }
                } else {
                    Text(card.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .onTapGesture {
                            onSelect()
                            titleDraft = card.title
                            titleSaveState = .idle
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
        .highPriorityGesture(TapGesture().onEnded {
            guard !ignoreNextTap else {
                ignoreNextTap = false
                return
            }
            onSelect()
        })
        .draggable(card.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let cardID = ids.first,
                  let dragged = model.cards.first(where: { $0.id == cardID }) else { return false }
            ignoreNextTap = true
            onDropBefore?(dragged)
            return true
        } isTargeted: { on in
            onTargeted?(on)
        }
        .sheet(isPresented: $delegating) {
            DelegateSheet(
                model: model,
                card: card,
                folders: folders,
                onViewRun: onViewRun,
                onRunInFront: onRunInFront
            )
        }
    }

    private func cancelTitle() {
        titleDraft = card.title
        titleSaveState = .idle
        editingTitle = false
        titleFocused = false
    }

    private func saveTitle() {
        if titleSaveState == .saving { return }
        let value = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            titleDraft = card.title
            titleSaveState = .idle
            editingTitle = false
            return
        }
        if value == card.title {
            titleSaveState = .idle
            editingTitle = false
            return
        }
        titleSaveState = .saving
        Task {
            let ok = await model.updateTitle(card, title: value)
            if ok {
                titleSaveState = .saved
                editingTitle = false
                try? await Task.sleep(for: .seconds(2))
                if titleSaveState == .saved { titleSaveState = .idle }
            } else {
                titleSaveState = .failed
                editingTitle = true
                titleFocused = true
            }
        }
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
                Button("Stop", .stop) { Task { await model.stop(card) } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
            // The result lives on the Automations screen; this is the door to
            // it, so a delegated card is never a dead end that only says
            // "Done" with nowhere to look.
            Button("View result", .preview) {
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
                Button("Move to To Do", .move) { Task { await model.move(card, to: "backlog") } }
            }
            if card.column != "doing" {
                Button("Move to Doing", .move) { Task { await model.move(card, to: "doing") } }
            }
            if card.column != "done" && card.column != "archive" {
                Button("Move to Done", .move) { Task { await model.move(card, to: "done") } }
            }
            if card.column == "done" {
                Button("Archive", .archive) { Task { await model.move(card, to: "archive") } }
            }
            if card.column == "archive" {
                Button("Restore to Done", .restore) { Task { await model.move(card, to: "done") } }
            }
            Divider()
            if !card.isNote {
                Button("Run…", .run) {
                    delegating = true
                }
            }
            Button("Delete", .delete, role: .destructive) { confirmingDelete = true }
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
                // A card added on a folder's board belongs to that folder. The
                // picker stays, because a card can be moved, but it is a
                // correction rather than a decision every time.
                .onChange(of: expanded, initial: true) { _, open in
                    guard open, let folder = model.defaultWorkspaceID else { return }
                    workspaceID = folder
                }

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
                // Where this is going, said before Save rather than found out
                // afterwards. Notes get it too: a note used to be forced to
                // Inbox, which is a place you can only reach from another
                // screen, so it read as not saved at all.
                AppMenuPicker(
                    title: "Saving to",
                    options: [(value: "", label: "Uncategorized (no folder)")]
                        + folders.map { (value: $0.id, label: $0.name) },
                    selection: $workspaceID
                )
                .frame(maxWidth: 260)
                if kind == .task {
                    HStack(spacing: Theme.Space.s) {
                        AppMenuPicker(
                            title: "Agent",
                            options: [(value: "", label: "Choose later")]
                                + model.pickerBackends(keeping: backendID).map { (value: $0.id, label: $0.label) },
                            selection: $backendID
                        )
                    }
                    // Model and effort exist only for backends that advertise
                    // them, so the pair appears for Claude and never for
                    // Shell. Both start on the backend's default.
                    if let backend = selectedBackend,
                       !backend.models.isEmpty || !backend.efforts.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            if !backend.models.isEmpty {
                                FavoriteModelPicker(
                                    backendID: backend.id,
                                    models: backend.models,
                                    extra: modelChoice,
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
                        BrandToggleChip(title: "No limit", isOn: $noTimeLimit)
                        Spacer()
                    }
                }
                HStack {
                    Button("Cancel", .dismiss) { cancel() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Save", .save) {
                        Task { await save() }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            budgetMinutes = "180"
            noTimeLimit = false
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

    /// What the toast calls the place this card is going.
    private var destinationName: String {
        if workspaceID.isEmpty { return "Uncategorized" }
        return folders.first { $0.id == workspaceID }?.name ?? "another folder"
    }

    private func save() async {
        let minutes = UInt64(budgetMinutes) ?? 180
        let budget: UInt64 = noTimeLimit ? 0 : minutes * 60
        await model.create(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            notes: notes,
            backend: backendID,
            // The folder this board is, or the one the picker says. A note
            // used to be forced out of the folder it was written in and into
            // Inbox, where the board it came from could not show it.
            workspaceID: workspaceID,
            budgetSeconds: budget,
            column: kind == .note ? "backlog" : column,
            model: {
                let cleaned = TodoCard.cleanModelID(modelChoice)
                return cleaned.isEmpty ? nil : cleaned
            }(),
            effort: effortChoice.isEmpty ? nil : effortChoice,
            destinationName: destinationName
        )
        if model.errorMessage == nil { cancel() }
    }

    private func cancel() {
        title = ""
        notes = ""
        workspaceID = ""
        budgetMinutes = "180"
        noTimeLimit = false
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
    var onViewRun: ((String) -> Void)? = nil
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)? = nil
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
            Text("Run this task")
                .font(.system(size: 17, weight: .semibold))
            Text(card.title)
                .font(.callout)
                .foregroundStyle(.secondary)
            AppMenuPicker(
                title: "Agent",
                options: model.pickerBackends(keeping: card.backend).map { (value: $0.id, label: $0.label) },
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
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if !backend.models.isEmpty {
                        FavoriteModelPicker(
                            backendID: backend.id,
                            models: backend.models,
                            extra: modelChoice,
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
                BrandToggleChip(title: "No limit", isOn: $noTimeLimit)
            }
            TaskRunBar(canRun: canRun, running: working) { placement in
                working = true
                Task { await run(inFront: placement == .front) }
            }
            Button("Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(Theme.Space.l)
        .frame(width: 420)
        .onAppear {
            backendID = card.backend
            workspaceID = card.workspaceID
            modelChoice = card.cleanedModel
            effortChoice = card.effort ?? ""
            noTimeLimit = card.budgetSeconds == 0
            if card.budgetSeconds > 0 {
                budgetMinutes = String(max(1, card.budgetSeconds / 60))
            }
            if backendID.isEmpty, let first = model.pickerBackends().first {
                backendID = first.id
            }
        }
        .onChange(of: backendID) { old, new in
            guard !old.isEmpty, old != new else { return }
            modelChoice = ""
            effortChoice = ""
        }
    }

    private var canRun: Bool {
        !backendID.isEmpty && !workspaceID.isEmpty
    }

    private func run(inFront: Bool) async {
        let minutes = UInt64(budgetMinutes) ?? 180
        let budget: UInt64 = noTimeLimit ? 0 : minutes * 60
        let saved = await model.updateCard(
            card,
            backend: backendID,
            model: TodoCard.cleanModelID(modelChoice),
            effort: effortChoice,
            workspaceID: workspaceID,
            budgetSeconds: budget
        )
        guard saved, let latest = model.cards.first(where: { $0.id == card.id }) else {
            working = false
            return
        }
        if inFront {
            onRunInFront?(InteractiveTaskLaunch(
                workspaceID: latest.workspaceID,
                backend: latest.backend,
                model: latest.cleanedModel.isEmpty ? nil : latest.cleanedModel,
                effort: latest.effort,
                prompt: latest.promptForRun,
                title: latest.title
            ))
            working = false
            if model.errorMessage == nil { dismiss() }
            return
        }
        let runID = await model.delegate(latest)
        working = false
        if model.errorMessage == nil {
            dismiss()
            if let runID { onViewRun?(runID) }
        }
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

private struct ColumnBodyHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
