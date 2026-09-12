// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

struct ClientTaskBoardDestination: View {
    let peer: String
    let hostName: String
    var folder: String? = nil
    var folderName = ""
    @State private var session: TaskBoardSession?

    var body: some View {
        Group {
            if let session, session.target.peer == peer, session.fixedFolder == folder {
                ClientTaskBoard(session: session, hostName: hostName, folderName: folderName)
            }
            else { ProgressView("Opening tasks").font(Theme.callout) }
        }
        .task(id: TaskBoardDestinationID(peer: peer, folder: folder)) {
            session = TaskBoardSessions.session(target: TaskEditorTarget(peer: peer), folder: folder)
        }
    }
}

private struct TaskBoardDestinationID: Hashable {
    let peer: String
    let folder: String?
}

struct ClientAllTasksLink: View {
    let peer: String
    let hostName: String
    @Environment(ClientNavigationModel.self) private var navigation

    var body: some View {
        Button { navigation.presentedTaskBoard = PresentedTaskBoard(peer: peer, hostName: hostName) } label: {
            HStack(spacing: Theme.Space.s) {
                Image("mark_todo").resizable().scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
                Text("All tasks").font(Theme.callout.weight(.medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(Theme.controlGlyph).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct ClientTaskBoard: View {
    @Bindable var session: TaskBoardSession
    let hostName: String
    var folderName = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var phase
    @State private var showingFilters = false
    @State private var targetedColumn: String?

    private let columns = [("backlog", "To Do", "mark_todo"), ("doing", "Doing", "mark_running"), ("done", "Done", "mark_done")]
    private var peer: String { session.target.peer ?? "" }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 960 && !typeSize.isAccessibilitySize && !session.filter.archived
            VStack(spacing: 0) {
                controls
                TextField("Search tasks", text: $session.filter.query).textFieldStyle(.themed)
                    .accessibilityLabel("Search task titles and prompts")
                    .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
                if showingFilters { filters.padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.m) }
                if !filterSummary.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        Text(filterSummary).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Clear filters", .dismiss) {
                            session.filter.folder = session.fixedFolder.map(TaskBoardFolder.folder) ?? .all
                            session.filter.backend = ""
                            session.filter.attention = .all
                            session.filter.newestFirst = false
                        }.buttonStyle(SecondaryButtonStyle(comfortable: true))
                    }.padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
                }
                ThemeRule()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if let error = session.errorMessage {
                            ClientErrorCard(message: ClientTunnelCopy.display(error, host: hostName)) { Task { await session.load() } }
                        }
                        if session.loading && !session.loaded { ProgressView("Loading tasks").font(Theme.callout) }
                        if let capabilities = session.capabilities, !capabilities.edit || !capabilities.delete {
                            Text("Update \(hostName)'s tokenstat to use all task editing and board actions.")
                                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        }
                        if let notice = session.notice { Text(notice).font(Theme.caption).foregroundStyle(Theme.controlGlyph) }
                        if session.loaded && session.visible.isEmpty {
                            ClientEmptyState(kind: .nothingYet,
                                             title: session.filter.archived ? "No archived tasks" : "No tasks here",
                                             message: "Create a task or adjust the filters to see more work.",
                                             art: .tasks)
                        }
                        if !session.visible.isEmpty && wide {
                            HStack(alignment: .top, spacing: Theme.Space.m) {
                                ForEach(columns, id: \.0) { column in
                                    boardColumn(column.0, title: column.1, mark: column.2, wide: true)
                                }
                            }
                        } else if !session.visible.isEmpty && session.filter.archived {
                            boardColumn("archive", title: "Archive", mark: "mark_todo", wide: false)
                        } else if !session.visible.isEmpty {
                            ForEach(columns, id: \.0) { column in
                                boardColumn(column.0, title: column.1, mark: column.2, wide: false)
                            }
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .refreshable { await session.load() }
            }
        }
        .background(Theme.background)
        .navigationTitle(session.fixedFolder == nil ? "All tasks" : "Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New task", .create) { session.composing = true }.labelStyle(.iconOnly)
            }
        }
        .fullScreenCover(isPresented: $session.composing) {
            TaskCreationDestination(target: session.target, workspaceID: defaultFolder, hostName: hostName) { _ in
                await session.load()
            }
        }
        .fullScreenCover(item: $session.editingTask, onDismiss: { Task { await session.load() } }) { card in
            TaskEditorDestination(target: session.target, card: card, hostName: hostName) { await session.load() }
        }
        .confirmationDialog("Delete task?", isPresented: Binding(
            get: { session.deletingTask != nil }, set: { if !$0 { session.deletingTask = nil } }
        ), titleVisibility: .visible, presenting: session.deletingTask) { card in
            Button("Delete task", role: .destructive) { Task { await session.delete(card) } }
        } message: { card in
            Text("Delete “\(card.title)”? This removes the task from this computer's board.")
        }
        .task { await session.load() }
        .task(id: needsPolling) {
            guard needsPolling else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                if !session.working && !session.loading { await session.load(includeOptions: false) }
            }
        }
        .onChange(of: phase) { _, new in if new == .active { Task { await session.load() } } }
        .onReceive(NotificationCenter.default.publisher(for: TaskEditorSession.didChange)) { note in
            guard note.object as? TaskEditorTarget == session.target, !session.working else { return }
            session.refreshAfterChange()
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.s) {
            Text(hostName).font(Theme.caption).foregroundStyle(Theme.controlGlyph).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Button("Filters", .filter) { showingFilters.toggle() }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
                .accessibilityValue(showingFilters ? "Expanded" : "Collapsed")
            Button(session.filter.archived ? "Open tasks" : "Archive", session.filter.archived ? .restore : .archive) {
                session.filter.archived.toggle()
            }.buttonStyle(SecondaryButtonStyle(comfortable: true))
        }.padding(Theme.Space.m)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.m) { filterFields }
            VStack(alignment: .leading, spacing: Theme.Space.m) { filterFields }
        }
    }

    @ViewBuilder private var filterFields: some View {
        if session.fixedFolder == nil {
            AppMenuPicker(title: "Folder", options: folderOptions, selection: $session.filter.folder)
                .frame(minWidth: 160)
        }
        AppMenuPicker(title: "Agent", options: [("", "All agents")] + agentOptions, selection: $session.filter.backend)
            .frame(minWidth: 160)
        AppMenuPicker(title: "Show", options: TaskBoardAttention.allCases.map { ($0, $0.label) }, selection: $session.filter.attention)
            .frame(minWidth: 160)
        AppMenuPicker(title: "Order", options: [(false, "Board order"), (true, "Newest first")], selection: $session.filter.newestFirst)
            .frame(minWidth: 160)
    }

    private func boardColumn(_ id: String, title: String, mark: String, wide: Bool) -> some View {
        let cards = session.visible.filter { $0.column == id }
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Image(mark).resizable().scaledToFit().frame(width: 24, height: 24).accessibilityHidden(true)
                Text(title).font(Theme.callout.weight(.semibold))
                Spacer()
                Text("\(cards.count)").font(Theme.caption).foregroundStyle(Theme.controlGlyph)
            }.padding(.vertical, Theme.Space.s)
            ForEach(cards) { card in
                taskRow(card)
                    .draggable(dragValue(card))
                    .dropDestination(for: String.self) { values, _ in
                        drop(values, column: id, before: card.id)
                    }
            }
            if wide || cards.isEmpty {
                Text(targetedColumn == id ? "Drop to move here" : cards.isEmpty ? "No tasks" : "")
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    .frame(maxWidth: .infinity, minHeight: wide ? 72 : 44)
                    .background(Theme.accent.opacity(targetedColumn == id ? 0.08 : 0), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { values, _ in drop(values, column: id, before: nil) } isTargeted: { hovering in
                        if hovering { targetedColumn = id }
                        else if targetedColumn == id { targetedColumn = nil }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func taskRow(_ card: TodoCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { session.editingTask = card } label: {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .top) {
                        Text(card.title).font(Theme.callout.weight(.semibold)).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(Theme.caption).foregroundStyle(Theme.controlGlyph).accessibilityHidden(true)
                    }
                    if !card.notes.isEmpty {
                        Text(card.notes).font(Theme.caption).foregroundStyle(Theme.controlGlyph).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if session.fixedFolder == nil {
                        Text(folderLabel(card)).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Edit task")
            HStack(spacing: Theme.Space.s) {
                if let run = card.delegate {
                    Text(run.label).font(Theme.caption).foregroundStyle(run.status == "error" ? Theme.danger : Theme.controlGlyph)
                } else if !card.backend.isEmpty {
                    Text(session.backends.first { $0.id == card.backend }?.label ?? card.backend).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                }
                if card.priority == "high" { Text("High priority").font(Theme.caption).foregroundStyle(Theme.accent) }
                Spacer(minLength: 0)
                Menu {
                    ForEach(columns, id: \.0) { column in
                        if card.column != column.0 { Button("Move to \(column.1)", .move) { Task { await session.move(card, to: column.0) } } }
                    }
                    if card.column != "archive" {
                        Button("Archive", .archive) { Task { await session.move(card, to: "archive") } }
                    }
                    Button("Move earlier", .move) { Task { await session.reorder(card, offset: -1) } }
                        .disabled(!session.canReorder(card, offset: -1))
                    Button("Move later", .move) { Task { await session.reorder(card, offset: 1) } }
                        .disabled(!session.canReorder(card, offset: 1))
                    Button("Delete…", .delete, role: .destructive) { session.deletingTask = card }
                        .disabled(card.delegate?.isRunning == true || session.capabilities?.delete != true)
                } label: { ActionLabel(title: "Move", icon: .move) }
                .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(session.working || session.capabilities?.edit != true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var defaultFolder: String {
        if let folder = session.fixedFolder { return folder }
        if case let .folder(id) = session.filter.folder { return id }
        return ""
    }
    private var needsPolling: Bool {
        phase == .active && session.cards.contains { $0.delegate?.isRunning == true }
    }
    private var agentOptions: [(String, String)] {
        let ids = Set((session.cards.map(\.backend) + [session.filter.backend]).filter { !$0.isEmpty }).union(session.backends.map(\.id)).sorted()
        return ids.map { id in (id, session.backends.first { $0.id == id }?.label ?? id) }
    }
    private var filterSummary: String {
        var parts: [String] = []
        if session.fixedFolder == nil && session.filter.folder != .all,
           let folder = folderOptions.first(where: { $0.0 == session.filter.folder }) { parts.append(folder.1) }
        if !session.filter.backend.isEmpty {
            parts.append(session.backends.first { $0.id == session.filter.backend }?.label ?? session.filter.backend)
        }
        if session.filter.attention != .all { parts.append(session.filter.attention.label) }
        if session.filter.newestFirst { parts.append("Newest first") }
        return parts.joined(separator: " · ")
    }
    private var folderOptions: [(TaskBoardFolder, String)] {
        var values: [(TaskBoardFolder, String)] = [(.all, "All folders"), (.uncategorized, "Uncategorized")]
            + session.folders.map { (.folder($0.id), $0.name) }
        if case let .folder(id) = session.filter.folder, !session.folders.contains(where: { $0.id == id }) {
            values.append((.folder(id), "Unavailable folder"))
        }
        return values
    }
    private func folderLabel(_ card: TodoCard) -> String {
        card.workspaceID.isEmpty ? "Uncategorized" : session.folders.first { $0.id == card.workspaceID }?.name ?? "Unavailable folder"
    }
    private func dragValue(_ card: TodoCard) -> String { "tokenstat-task|\(WorkReferenceKey.encode(peer))|\(WorkReferenceKey.encode(card.id))" }
    private func drop(_ values: [String], column: String, before: String?) -> Bool {
        guard !session.working, session.capabilities?.edit == true, !session.filter.newestFirst, values.count == 1,
              let card = session.cards.first(where: { dragValue($0) == values[0] }), card.id != before else { return false }
        Task { await session.move(card, to: column, before: before, atEnd: before == nil) }
        return true
    }
}
#endif
