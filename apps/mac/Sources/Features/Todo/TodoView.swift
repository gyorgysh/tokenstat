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
    var onViewRun: ((String, String) -> Void)? = nil
    /// Spawn an interactive terminal for this card. Not an automation.
    var onRunInFront: ((InteractiveTaskLaunch) -> Void)? = nil

    private static let columns: [(String, String)] = [
        ("backlog", L10n.text("apple.todoview.to_do.150d92c4")), ("doing", L10n.text("apple.todoview.in_progress.c1f88e9d")), ("done", L10n.text("common.done")),
    ]
    @AppStorage("todo.sortNewestFirst") private var newestFirst = false
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
                ? "\(folder.machineLabel ?? L10n.text("apple.todoview.remote.ffa98e02")) / \(folder.name)"
                : folder.name,
            symbol: folder.isRemote ? "network" : "folder.fill"
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // The bar names the place. Everything the board does sits on the
            // one row under it, filters on the left and actions on the right,
            // the way Automations reads.
            DetailChromeBar(scope: scopeChip) {
                EmptyView()
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
                // Show all three stages at ordinary desktop widths; smaller
                // windows can still scroll without changing stage order.
                let columnWidth = max(210, (usable - gap * 2) / 3)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(Self.columns, id: \.0) { id, label in
                            column(id, label, width: columnWidth)
                                .frame(height: max(0, available))
                        }
                    }
                    .padding(Theme.Space.m)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("common.tasks"))
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
                actionLabel: model.noticeScope == nil ? nil : L10n.text("apple.todoview.show.0df6f1ca"),
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
            HStack(spacing: Theme.Space.s) {
                filterControls
                Spacer(minLength: Theme.Space.s)
                boardActions
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) { filterControls }
                HStack(spacing: Theme.Space.s) {
                    Spacer(minLength: 0)
                    boardActions
                }
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .overlay(alignment: .bottom) { ThemeRule() }
    }

    /// Order, the archive and a new card: what changes the board rather
    /// than what narrows it.
    private var boardActions: some View {
        HStack(spacing: Theme.Space.s) {
            Picker(L10n.text("apple.todoview.sort_tasks.952f3831"), selection: $newestFirst) {
                Text(L10n.text("apple.todoview.board_order.a919c850")).tag(false)
                Text(L10n.text("apple.todoview.newest_first.ffb6f576")).tag(true)
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .onChange(of: newestFirst) { _, on in model.sortNewestFirst = on }
            ToolbarIconButton(systemImage: model.showingArchive ? "archivebox.fill" : "archivebox",
                help: model.showingArchive ? L10n.text("apple.todoview.back_to_the_board.0ebe76d6") : L10n.text("apple.todoview.show_archived_tasks_0.fdba34f9", "\(model.archivedCount)"),
                isAccent: model.showingArchive) { model.showingArchive.toggle() }
                .disabled(model.archivedCount == 0 && !model.showingArchive)
            Button(L10n.text("apple.todoview.new_task.3e992276"), .create) { addingIn = "backlog" }
                .buttonStyle(AccentButtonStyle(small: true))
                .help(L10n.text("apple.todoview.add_a_card_to_to_do.ca83de8d"))
        }
        .fixedSize()
    }

    private var filterControls: some View {
        HStack(spacing: Theme.Space.s) {
            SearchField(text: $search, prompt: L10n.text("apple.todoview.search_tasks.46c6f1de"))
                .frame(minWidth: 120, maxWidth: 220)
            if model.scope == nil {
                // Only the global board gets a selector. A folder's board is
                // that folder's, and a filter on top of it would be two
                // answers to one question.
                AppMenuPicker(
                    options: [
                        (value: "", label: L10n.text("apple.todoview.all_projects.4b87271b")),
                        (
                            value: Self.unfiledValue,
                            label: L10n.text("apple.todoview.uncategorized_0.413afa8b", "\((model.unfiledCount > 0 ? " (\(model.unfiledCount))" : ""))")
                        ),
                    ] + folders.map { (value: $0.id, label: $0.name) },
                    selection: Binding(
                        get: { Self.value(of: model.filter) },
                        set: { model.filter = Self.filter(from: $0) }
                    )
                )
                .frame(width: 140)
            }
            Menu {
                Picker(L10n.text("apple.todoview.agent.11b39c93"), selection: $agentFilter) {
                    Text(L10n.text("apple.todoview.all_agents.54c32d3e")).tag("")
                    ForEach(model.pickerBackends(keeping: agentFilter), id: \.id) { backend in
                        Text(backend.label).tag(backend.id)
                    }
                }
                Toggle(L10n.text("apple.todoview.needs_attention.c1ebc781"), isOn: $attentionOnly)
            } label: {
                Label(agentFilter.isEmpty && !attentionOnly ? L10n.text("apple.todoview.filters.546ebb8e") : L10n.text("apple.todoview.filters_applied.bb7cd36c"),
                      systemImage: agentFilter.isEmpty && !attentionOnly ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .fixedSize()
            .labelStyle(.titleAndIcon)
            .help(L10n.text("apple.todoview.filter_by_agent_or_show_high_priority_task.4683acb4"))
            if hasFilters {
                Button(L10n.text("apple.todoview.clear.83b12c22"), .dismiss) { search = ""; agentFilter = ""; attentionOnly = false }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
            }
            // One way in per column, at the foot of its cards, where a board
            // puts it. A second "+" in the header was the same button twice.
            .frame(minHeight: 32)
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
                                model.sortNewestFirst = false
                                let list = model.cards.filter { $0.column == model.storageColumn(id) && $0.id != dragged.id }.sorted { $0.order < $1.order }
                                let order = Int64(list.firstIndex(where: { $0.id == card.id }) ?? list.count)
                                clearDropChrome()
                                Task { await model.reorder(dragged, to: model.storageColumn(id), order: order) }
                            },
                            onTargeted: { on in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    if on {
                                        dropTarget = id
                                        dropBeforeID = card.id
                                    } else if dropTarget == id && dropBeforeID == card.id {
                                        clearDropChrome()
                                    }
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
                            Text(hasFilters ? L10n.text("apple.todoview.no_matching_tasks.ff36d18d") : emptyCopy(for: id))
                                .font(Theme.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.xl)
                    }
                    // Work lands in Done by being finished, not by being
                    // written there, so that column has no way to add.
                    if id != "done" {
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
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if targeted {
                                    dropTarget = id
                                    dropBeforeID = "__end__"
                                } else if dropTarget == id && dropBeforeID == "__end__" {
                                    clearDropChrome()
                                }
                            }
                        }
                }
                .frame(minHeight: columnBodyHeights[id] ?? 0, alignment: .top)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dropBeforeID)

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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if targeted {
                    dropTarget = id
                    dropBeforeID = "__end__"
                } else if dropTarget == id {
                    clearDropChrome()
                }
            }
        }
    }

    /// Accent rule marking where the dragged card would land. Rows above
    /// and below slide apart with a spring, like home-screen icon reorder.
    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(height: 2)
            .transition(.opacity.combined(with: .scale))
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
        model.sortNewestFirst = false
        let others = model.cards.filter { $0.column == model.storageColumn(column) && $0.id != card.id }.count
        Task { await model.reorder(card, to: model.storageColumn(column), order: Int64(others)) }
        clearDropChrome()
        return true
    }

    private func columnTitle(_ id: String, _ label: String) -> String {
        if id == "done", model.showingArchive { return L10n.text("common.archive") }
        return label
    }

    private func emptyCopy(for id: String) -> String {
        if id == "done" {
            return model.showingArchive ? L10n.text("apple.todoview.archived_tasks_appear_here.b33f5e59") : L10n.text("apple.todoview.completed_tasks_appear_here.6d7064fc")
        }
        return id == "doing" ? L10n.text("apple.todoview.move_a_task_here_when_work_begins.c470717a") : L10n.text("apple.todoview.add_a_task_or_drop_one_here.8bb8aa6a")
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
    var onViewRun: ((String, String) -> Void)?
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
                if editingTitle {
                    TextField(L10n.text("apple.todoview.title.7e8cd205"), text: $titleDraft)
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
                        .help(L10n.text("apple.todoview.discard_title.52f03907"))
                        Button {
                            saveTitle()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(Theme.font(10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help(L10n.text("apple.todoview.save_title.c4ecfe02"))
                    } else if titleSaveState == .saving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if titleSaveState == .saved {
                        Image(systemName: "checkmark")
                            .font(Theme.font(10, weight: .bold))
                            .foregroundStyle(Theme.success)
                            .help(L10n.text("apple.todoview.saved.b5c120b3"))
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
                Label(L10n.text("apple.todoview.high_priority.b699a8c8"), systemImage: "flag.fill")
                    .font(Theme.caption2.weight(.medium)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.secondary.opacity(0.1), in: Capsule())
            } else if card.priority == "low" {
                Label(L10n.text("apple.todoview.low_priority.904d0a4a"), systemImage: "flag")
                    .font(Theme.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.secondary.opacity(0.07), in: Capsule())
            }
            HStack(spacing: Theme.Space.s) {
                Label(folders.first(where: { $0.id == card.workspaceID })?.name ?? L10n.text("apple.todoview.uncategorized.8d40d123"), systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !card.backend.isEmpty {
                    Label(model.backends.first { $0.id == card.backend }?.label ?? card.backend, systemImage: "cpu")
                        .lineLimit(1)
                }
            }
            .font(Theme.caption2).foregroundStyle(.secondary)
            if card.budgetSeconds != 10_800 || card.delegate?.isRunning == true {
                Label(card.budgetSeconds == 0 ? L10n.text("apple.todoview.no_time_limit.436b4b94") : Self.budgetLabel(card.budgetSeconds), systemImage: "timer")
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
        .help(L10n.text("apple.todoview.select_to_edit_drag_to_move_or_reorder_thi.550cf9dc"))
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
            ? L10n.text("apple.todoview.0_m_time_limit.b1348c43", "\(seconds / 60)")
            : L10n.text("apple.todoview.0_s_time_limit.12b76484", "\(seconds)")
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
                Button(L10n.text("common.stop"), .stop) { Task { await model.stop(card) } }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
            // The result lives on the Automations screen; this is the door to
            // it, so a delegated card is never a dead end that only says
            // "Done" with nowhere to look.
            Button(L10n.text("apple.todoview.view_result.fdb7eafd"), .preview) {
                onViewRun?(delegate.runId, card.workspaceID)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help(L10n.text("apple.todoview.open_this_run_s_transcript_on_the_automati.1f81d9a3"))
        }
    }

    @ViewBuilder
    private var controls: some View {
        Menu {
            if card.column != "backlog" {
                Button(L10n.text("apple.todoview.move_to_to_do.740804f2"), .move) { Task { await model.move(card, to: "backlog") } }
            }
            if card.column != "doing" {
                Button(L10n.text("apple.todoview.move_to_doing.2d0966e8"), .move) { Task { await model.move(card, to: "doing") } }
            }
            if card.column != "done" && card.column != "archive" {
                Button(L10n.text("apple.todoview.move_to_done.a37bc1a6"), .move) { Task { await model.move(card, to: "done") } }
            }
            if card.column == "done" {
                Button(L10n.text("common.archive"), .archive) { Task { await model.move(card, to: "archive") } }
            }
            if card.column == "archive" {
                Button(L10n.text("apple.todoview.restore_to_done.7c7ceb11"), .restore) { Task { await model.move(card, to: "done") } }
            }
            ThemeRule()
            Menu(L10n.text("apple.todoview.priority.d60dbba0")) {
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
                Button(L10n.text("apple.todoview.run.1dcb1ca8"), .run) {
                    delegating = true
                }
            }
            Button(L10n.text("common.delete"), .delete, role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("apple.todoview.task_actions.6135aebe"))
        .confirmationDialog(
            L10n.text("apple.todoview.delete_this_card.52c85ff8"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) { Task { await model.remove(card) } }
            Button(L10n.text("apple.todoview.keep_it.fdce5da2"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.todoview.the_card_is_removed_from_the_board_this_ca.b909cbf6"))
        }
    }
}

// MARK: - New card

/// The full-width row that opens New Task.
///
/// It sits at the foot of a column's cards, the one place a board offers to
/// add. The toolbar's New task covers a backlog too long to scroll.
private struct AddCardTrigger: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Label(L10n.text("apple.todoview.new_task.3e992276"), systemImage: ActionIcon.create.symbol)
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
    var onViewRun: ((String, String) -> Void)? = nil
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
            title: L10n.text("apple.todoview.run_this_task.5ba8e499"),
            subtitle: card.title,
            icon: .run,
            onClose: { if !working { dismiss() } }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                AppMenuPicker(
                    title: L10n.text("apple.todoview.agent.11b39c93"),
                    options: model.pickerBackends(keeping: card.backend).map { (value: $0.id, label: $0.label) },
                    selection: $backendID
                )
                AppMenuPicker(
                    title: L10n.text("apple.todoview.project.98595978"),
                    options: [(value: "", label: L10n.text("apple.todoview.choose_workspace.94b211b5"))]
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
                                title: L10n.text("apple.todoview.effort.4387e5d3"),
                                options: [(value: "", label: L10n.text("apple.todoview.default.21b111cb"))]
                                    + backend.efforts.map { (value: $0, label: $0) },
                                selection: $effortChoice
                            )
                        }
                    }
                }
                HStack {
                    Text(L10n.text("apple.todoview.time_limit.e592a9ca"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    TextField("180", text: $budgetMinutes)
                        .themedFieldBox(small: true)
                        .frame(width: 64)
                        .disabled(noTimeLimit)
                    Text(budgetUnit)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    BrandToggleChip(title: L10n.text("apple.todoview.no_limit.f7fcff0d"), isOn: $noTimeLimit)
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
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
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
            if let runID { onViewRun?(runID, latest.workspaceID) }
        }
    }
}

private struct ColumnBodyHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
