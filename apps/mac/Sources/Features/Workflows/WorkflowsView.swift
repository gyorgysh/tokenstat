// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

/// The workflow library. Global graphs, then one section per workspace.
///
/// Opening a row on the Mac opens the canvas. Empty state is the design
/// prompt, not an empty form. The inspector stays the outline and the
/// selected-node form.
struct WorkflowsView: View {
    @Bindable var model: WorkflowsModel
    var folders: [WorkspaceFolder]

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var designFocused: Bool
    @State private var designPrompt = ""
    @State private var designBackend = ""
    @State private var designWorkspaceID = ""
    @State private var running: WorkflowGraph?
    @State private var confirmingDelete: WorkflowGraph?

    private static let chips = [
        "Plan then build then review",
        "Commit and push",
        "Run tests then notify",
    ]

    var body: some View {
        Group {
            #if os(macOS)
            if model.isEditing {
                WorkflowsEditor(
                    model: model,
                    folders: folders,
                    onBack: { model.closeEditor() }
                )
            } else {
                library
            }
            #else
            library
            #endif
        }
        .navigationTitle("Workflows")
        .background(Theme.background)
        .sheet(item: $running) { graph in
            RunWorkflowSheet(model: model, graph: graph, folders: folders)
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.name ?? "this workflow")?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let graph = confirmingDelete {
                    Task { await model.remove(graph) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("The graph is removed. Past runs stay on this Mac.")
        }
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.noticeMessage, severity: .success)
                .padding(Theme.Space.l)
        }
        .task {
            await model.appeared()
            if designBackend.isEmpty {
                designBackend = model.pickerBackends().first?.id ?? ""
            }
            if designWorkspaceID.isEmpty {
                designWorkspaceID = folders.first?.id ?? ""
            }
        }
        .onDisappear { model.disappeared() }
    }

    private var library: some View {
        VStack(spacing: 0) {
            DetailChromeBar {
                ToolbarIconButton(
                    systemImage: "plus",
                    help: "Start a blank draft"
                ) {
                    model.startBlank(
                        scope: defaultScope,
                        workspaceID: defaultWorkspaceID
                    )
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error = model.errorMessage {
                        Banner(text: error, severity: .warning)
                    }
                    intro
                    designCard
                    if let draft = model.draft, draft.id.isEmpty {
                        draftCard(draft)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("Search workflows", text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($searchFocused)
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Space.s)
                            .strokeBorder(
                                searchFocused ? Theme.accent.opacity(0.7) : Theme.border,
                                lineWidth: searchFocused ? 1.5 : 1
                            )
                    )
                    .padding(.leading, 4)
                    if isWarming {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Skeleton.CardPlaceholder(rows: 2)
                            Skeleton.CardPlaceholder(rows: 2)
                        }
                        .transition(.opacity)
                    } else if filtered.isEmpty && model.draft == nil {
                        nothingYet
                    } else {
                        librarySections
                    }
                    if !model.runs.isEmpty {
                        recentRuns
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
    }

    private var defaultScope: WorkflowScope {
        folders.count == 1 ? .workspace : .global
    }

    private var defaultWorkspaceID: String? {
        folders.count == 1 ? folders.first?.id : nil
    }

    private var intro: some View {
        HStack(alignment: .top) {
            FeatureMark(name: "mark_workflow", tint: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Workflows")
                    .font(.system(size: 24, weight: .semibold))
                Text("A map of agents, automations, HTTP and commands. Describe a run, review the draft, then save. It never starts on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Blank draft", .create) {
                model.startBlank(scope: defaultScope, workspaceID: defaultWorkspaceID)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var designCard: some View {
        Card(
            title: "Design",
            subtitle: "A cheap local backend drafts the graph. You review it. It does not run.",
            mark: "mark_workflow"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Describe the run", text: $designPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                    .focused($designFocused)
                    .disabled(model.isDesigning)
                HStack(spacing: Theme.Space.s) {
                    ForEach(Self.chips, id: \.self) { chip in
                        Button(chip, .create) { designPrompt = chip }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    Picker("Backend", selection: $designBackend) {
                        ForEach(model.pickerBackends(keeping: designBackend)) { backend in
                            Text(backend.label).tag(backend.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    if !folders.isEmpty {
                        Picker("Folder", selection: $designWorkspaceID) {
                            Text("No folder").tag("")
                            ForEach(folders) { folder in
                                Text(folder.name).tag(folder.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }
                    Spacer()
                    Button(model.isDesigning ? "Designing" : "Design", .create) {
                        Task {
                            await model.design(
                                prompt: designPrompt,
                                workspaceID: designWorkspaceID.isEmpty ? nil : designWorkspaceID,
                                backend: designBackend.isEmpty ? nil : designBackend
                            )
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(model.isDesigning || designPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func draftCard(_ draft: WorkflowGraph) -> some View {
        Card(
            title: draft.name.isEmpty ? "Draft" : draft.name,
            subtitle: "Unsaved. Review the outline, then save. It will not run until you press Run.",
            mark: "mark_workflow"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                WorkflowOutline(nodes: draft.nodes, edges: draft.edges)
                HStack(spacing: Theme.Space.s) {
                    Button("Save", .save) { Task { await model.saveDraft() } }
                        .buttonStyle(AccentButtonStyle())
                    Button("Discard", .dismiss) { model.discardDraft() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Text("\(draft.nodes.count) nodes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onTapGesture { model.selectDraft() }
    }

    private var nothingYet: some View {
        Card(title: "Workflows", subtitle: nil, mark: "mark_workflow") {
            EmptyState(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "No workflows yet",
                message: """
                Describe a run above. A cheap local backend drafts the graph. \
                You review it, then save. Automations stay: a workflow can \
                include one as a step.
                """
            ) {
                Button("Blank draft", .create) {
                    model.startBlank(scope: defaultScope, workspaceID: defaultWorkspaceID)
                }
                .buttonStyle(AccentButtonStyle())
            }
        }
    }

    private var filtered: [WorkflowGraph] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.graphs }
        return model.graphs.filter { graph in
            graph.name.localizedCaseInsensitiveContains(query)
                || graph.nodes.contains {
                    $0.displayTitle.localizedCaseInsensitiveContains(query)
                        || $0.kind.label.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var librarySections: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            section(
                title: "Global",
                graphs: filtered.filter { $0.scope == .global }
            )
            ForEach(folders) { folder in
                section(
                    title: folder.name,
                    graphs: filtered.filter {
                        $0.scope == .workspace && $0.workspaceID == folder.id
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func section(title: String, graphs: [WorkflowGraph]) -> some View {
        if !graphs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(Theme.sectionHeader)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, Theme.Space.xs)
                VStack(spacing: 0) {
                    ForEach(graphs) { graph in
                        WorkflowRow(
                            graph: graph,
                            last: model.lastRun(for: graph),
                            folder: folders.first { $0.id == graph.workspaceID },
                            isSelected: model.selectedGraphID == graph.id,
                            onSelect: { model.selectGraph(graph.id) },
                            onRun: { running = graph },
                            onViewRun: { model.selectRun($0) },
                            onDelete: { confirmingDelete = graph }
                        )
                        if graph.id != graphs.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            }
        }
    }

    private var recentRuns: some View {
        Card(
            title: "Recent runs",
            subtitle: "Select a run to read a step in the inspector.",
            mark: "mark_workflow"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(model.runs.prefix(6))) { run in
                    runRow(run)
                    if run.id != model.runs.prefix(6).last?.id { Divider() }
                }
            }
        }
    }

    private func runRow(_ run: WorkflowRunRecord) -> some View {
        HStack(spacing: Theme.Space.s) {
            Circle()
                .fill(Self.statusTint(run.status))
                .frame(width: 8, height: 8)
            Text(run.name)
                .font(.callout.weight(.medium))
            Text(run.endedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
            StatusPill(status: run.status, text: run.endedLabel)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(model.selectedRunID == run.id ? Theme.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Space.xs))
        .contentShape(.rect)
        .onTapGesture { model.selectRun(run) }
    }

    static func statusTint(_ status: String) -> Color {
        switch status {
        case "running": return Theme.accent
        case "waiting": return Theme.warning
        case "ok": return Theme.success
        case "stopped": return Theme.warning
        case "error": return Theme.danger
        case "interrupted": return Theme.warning
        default: return .secondary
        }
    }
}

/// One saved graph in the library.
private struct WorkflowRow: View {
    let graph: WorkflowGraph
    let last: WorkflowRunRecord?
    let folder: WorkspaceFolder?
    let isSelected: Bool
    let onSelect: () -> Void
    let onRun: () -> Void
    let onViewRun: (WorkflowRunRecord) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Button(action: onSelect) {
                HStack(spacing: Theme.Space.s) {
                    FeatureMark(name: "mark_workflow", tint: Theme.accent, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(graph.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let last {
                        StatusPill(status: last.status, text: last.endedLabel)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let last, last.isLive {
                if last.isWaiting {
                    Button("Continue", .next) { onViewRun(last) }
                        .buttonStyle(AccentButtonStyle(small: true))
                } else {
                    Button("Open", .preview) { onViewRun(last) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            } else {
                Button("Run", .run) { onRun() }
                    .buttonStyle(AccentButtonStyle(small: true))
            }
            Button("Delete", .delete, role: .destructive) { onDelete() }
                .buttonStyle(SecondaryButtonStyle(small: true))
        }
        .padding(.vertical, Theme.Space.s)
        .background(isSelected ? Theme.accentSoft.opacity(0.5) : .clear)
    }

    private var caption: String {
        var parts: [String] = ["\(graph.nodes.count) nodes"]
        parts.append(graph.scope.label)
        if let folder {
            parts.append(folder.name)
        }
        if let last {
            parts.append(last.endedLabel)
        }
        return parts.joined(separator: " · ")
    }
}

/// Vertical VoiceOver-friendly outline of the graph.
struct WorkflowOutline: View {
    let nodes: [WorkflowNode]
    var edges: [WorkflowEdge] = []
    var steps: [WorkflowStep] = []
    var selectedID: String?
    var onSelect: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ordered) { node in
                Button {
                    onSelect?(node.id)
                } label: {
                    HStack(spacing: Theme.Space.s) {
                        if node.kind == .agent, let backend = node.backend {
                            HarnessMark(id: backend, size: 18)
                        } else {
                            FeatureMark(name: node.kind.mark, tint: Theme.accent, size: 18)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(node.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let step = steps.first(where: { $0.nodeID == node.id }) {
                            StatusPill(status: step.status, text: step.endedLabel)
                        } else {
                            Text(node.kind.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .background(
                        selectedID == node.id ? Theme.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Space.xs)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(node.kind.label). \(node.displayTitle). \(node.subtitle)")
                if node.id != ordered.last?.id {
                    incomingHint(for: node)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Input first, then the rest in saved order. Positions are canvas metadata.
    private var ordered: [WorkflowNode] {
        let inputs = nodes.filter { $0.kind == .input }
        let rest = nodes.filter { $0.kind != .input }
        return inputs + rest
    }

    @ViewBuilder
    private func incomingHint(for node: WorkflowNode) -> some View {
        let incoming = edges.filter { $0.to == node.id }
        if incoming.count > 1 {
            Text("joins \(incoming.count) steps")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
        }
    }
}

/// Confirm the starting prompt and, for a global graph, the folder.
struct RunWorkflowSheet: View {
    @Bindable var model: WorkflowsModel
    let graph: WorkflowGraph
    var folders: [WorkspaceFolder]
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var workspaceID = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run \(graph.name)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The starting prompt fills {{input}} in every node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(
                    action: { dismiss() },
                    help: "Close",
                    label: "Close"
                )
            }
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
            }
            TextField("Starting prompt", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            if graph.scope == .global {
                Picker("Folder", selection: $workspaceID) {
                    ForEach(folders) { folder in
                        Text(folder.name).tag(folder.id)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(working ? "Starting" : "Run", .run) {
                    working = true
                    Task {
                        let folder = graph.scope == .workspace
                            ? graph.workspaceID
                            : (workspaceID.isEmpty ? nil : workspaceID)
                        await model.run(graph, input: input, workspaceID: folder)
                        working = false
                        if model.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(working || (graph.scope == .global && workspaceID.isEmpty && folders.isEmpty))
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 420)
        .onAppear {
            workspaceID = graph.workspaceID ?? folders.first?.id ?? ""
        }
    }
}
