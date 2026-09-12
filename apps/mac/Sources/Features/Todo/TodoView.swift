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
    @State private var search = ""
    @State private var agentFilter = ""
    @State private var attentionOnly = false
    @State private var dropTarget: String?
    /// Card id the drag would land before, or "__end__".
    @State private var dropBeforeID: String?
    /// Scroll-view height per column, so empty space under the cards is a drop target.
    @State private var columnBodyHeights: [String: CGFloat] = [:]

    /// The sheet belongs to the board, so a lazy column cannot unmount it.
    @State private var addingIn: String?
    private struct CreationColumn: Identifiable { let id: String }

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
            filterBar
            if let error = model.errorMessage {
                ErrorBanner(message: error) { Task { await model.load() } }
                    .padding(Theme.Space.m)
            }
            GeometryReader { proxy in
                let available = proxy.size.height - Theme.Space.m * 2
                let gap = Theme.Space.m
                let usable = proxy.size.width - Theme.Space.m * 2 - Theme.Space.s * 6
                // Three columns only when they stay readable. A 240 floor
                // overflowed a tiled half-screen. Below that, stack them.
                let minCol: CGFloat = 240
                let sideBySide = usable >= minCol * 3 + gap * 2
                let columnWidth = sideBySide
                    ? (usable - gap * 2) / 3
                    : max(0, proxy.size.width - Theme.Space.m * 2 - Theme.Space.s * 2)
                ScrollView(sideBySide ? .horizontal : .vertical) {
                    let columns = ForEach(Self.columns, id: \.0) { id, label in
                        column(id, label, width: columnWidth)
                            .frame(height: sideBySide ? max(0, available) : min(650, max(280, CGFloat(visibleCards(in: id).count) * 160 + 110)))
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
            }
        }
        .background(Theme.background)
        .navigationTitle("Tasks")
        .sheet(item: creationColumn) { column in
            TaskCreationDestination(target: TaskEditorTarget(peer: nil), workspaceID: model.defaultWorkspaceID ?? "",
                                    column: column.id, hostName: "This computer") { card in
                if let card { await model.taskCreated(card, folders: folders) }
                else { await model.load() }
            }
        }
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

    private var creationColumn: Binding<CreationColumn?> {
        Binding(get: { addingIn.map { CreationColumn(id: $0) } }, set: { addingIn = $0?.id })
    }

    private var hasFilters: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !agentFilter.isEmpty || attentionOnly
    }

    private func visibleCards(in column: String) -> [TodoCard] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.cards(in: column).filter { card in
            (agentFilter.isEmpty || card.backend == agentFilter)
                && (!attentionOnly || card.priority == "high" || card.delegate?.status == "error")
                && (term.isEmpty || card.title.localizedStandardContains(term) || card.notes.localizedStandardContains(term))
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { searchField; filterControls }
            VStack(alignment: .leading, spacing: Theme.Space.s) { searchField; filterControls }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) { ThemeRule().opacity(0.5) }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tasks", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
        }
        .font(Theme.callout).padding(8)
        .frame(minWidth: 160, maxWidth: 340)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }

    private var filterControls: some View {
        HStack(spacing: Theme.Space.m) {
            AppMenuPicker(options: [(value: "", label: "All agents")]
                + model.pickerBackends(keeping: agentFilter).map { (value: $0.id, label: $0.label) }, selection: $agentFilter)
                .frame(width: 150)
            Toggle("Needs attention", isOn: $attentionOnly).toggleStyle(.button)
                .font(Theme.caption).tint(Theme.accent)
                .help("High-priority tasks and failed runs")
            if hasFilters {
                Button("Clear", .dismiss) { search = ""; agentFilter = ""; attentionOnly = false }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.caption)
            }
            Spacer(minLength: 0)
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
                Text(columnTitle(id, label)).font(Theme.fit(14, weight: .semibold))
                Text("\(visibleCards(in: id).count)")
                    .font(Theme.numeric(11, weight: .medium)).foregroundStyle(tint(for: id))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tint(for: id).opacity(0.12), in: Capsule())
                Spacer()
                if !(id == "done" && model.showingArchive) {
                    Button { addingIn = addingIn == id ? nil : id } label: {
                        Image(systemName: addingIn == id ? "xmark" : "plus")
                            .font(Theme.font(12, weight: .medium)).frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                        .help("Add a task to \(label)")
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)

            ScrollView {
                LazyVStack(spacing: Theme.Space.s) {
                    ForEach(visibleCards(in: id)) { card in
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
                    } else if visibleCards(in: id).isEmpty {
                        VStack(spacing: Theme.Space.s) {
                            Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle" : symbol(for: id))
                                .font(Theme.font(22)).foregroundStyle(tint(for: id).opacity(0.6))
                            Text(hasFilters ? "No matching tasks" : emptyCopy(for: id))
                                .font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
                    }
                    if !(id == "done" && model.showingArchive) {
                        AddCardTrigger(expanded: Binding(
                                get: { addingIn == id },
                                set: { open in
                                    if open { addingIn = id } else if addingIn == id { addingIn = nil }
                                }
                        ))
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
        }
        .frame(width: width)
        .padding(Theme.Space.s)
        .background(
            Theme.panel.opacity(dropTarget == id ? 0.95 : 0.6),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(dropTarget == id ? Theme.accent : Theme.border.opacity(0.55), lineWidth: 1)
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

    private func columnTitle(_ id: String, _ label: String) -> String {
        if id == "done", model.showingArchive { return "Archive" }
        return label
    }

    private func emptyCopy(for id: String) -> String {
        if id == "done" {
            return model.showingArchive ? "Archived tasks appear here" : "Completed tasks appear here"
        }
        return id == "doing" ? "Move a task here when work begins" : "Add a task or drop one here"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                FeatureMark(name: card.isNote ? "mark_note" : "mark_todo",
                            tint: card.isNote ? Theme.secondary : Theme.accent,
                            size: 16)
                if editingTitle {
                    TextField("Title", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(Theme.callout.weight(.medium))
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
                                .font(Theme.font(10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Discard title")
                        Button {
                            saveTitle()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(Theme.font(10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help("Save title")
                    } else if titleSaveState == .saving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if titleSaveState == .saved {
                        Image(systemName: "checkmark")
                            .font(Theme.font(10, weight: .bold))
                            .foregroundStyle(Theme.success)
                            .help("Saved")
                    }
                } else {
                    Text(card.title)
                        .font(Theme.font(14, weight: .semibold))
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
                controls
            }
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let delegate = card.delegate {
                delegateStatus(delegate)
            }
            if card.priority == "high" {
                Label("High priority", systemImage: "flag.fill")
                    .font(Theme.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.secondary.opacity(0.1), in: Capsule())
            } else if card.priority == "low" {
                Label("Low priority", systemImage: "flag")
                    .font(Theme.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.secondary.opacity(0.07), in: Capsule())
            }
            HStack(spacing: Theme.Space.s) {
                Label(folders.first(where: { $0.id == card.workspaceID })?.name ?? "Uncategorized", systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !card.backend.isEmpty {
                    Label(model.backends.first { $0.id == card.backend }?.label ?? card.backend, systemImage: "cpu")
                        .lineLimit(1)
                }
            }
            .font(Theme.caption2).foregroundStyle(.secondary)
            if card.budgetSeconds != 10_800 || card.delegate?.isRunning == true {
                Label(card.budgetSeconds == 0 ? "No time limit" : Self.budgetLabel(card.budgetSeconds), systemImage: "timer")
                    .font(Theme.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
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
                .font(Theme.caption2.weight(.medium))
                .foregroundStyle(tint)
            if let error = delegate.error {
                Text(error)
                    .font(Theme.caption2)
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
            ThemeRule()
            Menu("Priority") {
                ForEach(["low", "normal", "high"], id: \.self) { level in
                    Button {
                        Task { await model.updateCard(card, priority: level) }
                    } label: {
                        if card.priority == level || (card.priority.isEmpty && level == "normal") {
                            Label(level.capitalized, systemImage: "checkmark")
                        } else {
                            Text(level.capitalized)
                        }
                    }
                }
            }
            ThemeRule()
            if !card.isNote {
                Button("Run…", .run) {
                    delegating = true
                }
            }
            Button("Delete", .delete, role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Task actions")
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

/// The full-width row that opens New Task.
///
/// One of these sits above the card list and one below it, both driving the
/// presentation flag, so a long backlog still has a nearby way to add work.
private struct AddCardTrigger: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Label("New task", systemImage: ActionIcon.create.symbol)
            .font(Theme.caption.weight(.medium))
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
    @State private var budgetUnit = "minutes"
    @State private var noTimeLimit = false
    @State private var working = false
    @State private var chatTask: TodoCard?

    var body: some View {
        ThemedSheet(
            title: "Run this task",
            subtitle: card.title,
            icon: .run,
            onClose: { if !working { dismiss() } }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
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
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    TextField("180", text: $budgetMinutes)
                        .themedFieldBox(small: true)
                        .frame(width: 64)
                        .disabled(noTimeLimit)
                    Text(budgetUnit)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    BrandToggleChip(title: "No limit", isOn: $noTimeLimit)
                }
                if let validation = runDraft.validation {
                    Text(validation).font(Theme.caption).foregroundStyle(Theme.danger)
                }
                if let error = model.errorMessage {
                    Text(error).font(Theme.callout).foregroundStyle(Theme.danger)
                }
            }
            .disabled(working)
        } actions: {
            Button("Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Spacer()
            TaskRunBar(canRun: canRun, running: working) { placement in
                working = true
                Task { await run(inFront: placement == .foreground, asChat: placement == .chat) }
            }
        }
        .interactiveDismissDisabled(working)
        .sheet(item: $chatTask) { card in
            TaskChatLaunchView(card: card, peer: nil)
        }
        .modalFrame(width: 540, height: 520)
        .onAppear {
            backendID = card.backend
            workspaceID = card.workspaceID
            modelChoice = card.cleanedModel
            effortChoice = card.effort ?? ""
            noTimeLimit = card.budgetSeconds == 0
            if card.budgetSeconds > 0 {
                let draft = TaskEditorDraft(card)
                budgetMinutes = draft.budgetValue
                budgetUnit = draft.budgetUnit
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
        !backendID.isEmpty && !workspaceID.isEmpty && runDraft.validation == nil
    }

    private var runDraft: TaskEditorDraft {
        var draft = TaskEditorDraft(card)
        draft.backend = backendID
        draft.model = modelChoice
        draft.effort = effortChoice
        draft.workspaceID = workspaceID
        draft.budgetValue = budgetMinutes
        draft.budgetUnit = budgetUnit
        draft.noTimeLimit = noTimeLimit
        return draft
    }

    private func run(inFront: Bool, asChat: Bool = false) async {
        guard runDraft.validation == nil, let budget = runDraft.budgetSeconds else {
            working = false
            return
        }
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
        if asChat {
            chatTask = latest
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

private struct ColumnBodyHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
