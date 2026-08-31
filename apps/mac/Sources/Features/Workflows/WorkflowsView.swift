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
    @State private var designModel = ""
    @State private var designEffort = ""
    @State private var designWorkspaceID = ""
    /// "1", "0", or empty for "nobody has said yet".
    @AppStorage("workflows.examplesExpanded") private var examplesExpandedStored = ""
    @State private var running: WorkflowGraph?
    @State private var confirmingDelete: WorkflowGraph?

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
            #if os(macOS)
            await LaunchCatalog.shared.resolve()
            #endif
            await model.appeared()
            if designBackend.isEmpty {
                designBackend = WorkflowRecipes.defaultBackend(from: model.pickerBackends())
            }
            syncDesignWorkspace()
        }
        .onChange(of: model.scope) { _, _ in
            syncDesignWorkspace()
        }
        .onDisappear { model.disappeared() }
    }

    private var library: some View {
        VStack(spacing: 0) {
            DetailChromeBar(scope: scopeChip) {
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
                    builderCard
                    if let draft = model.draft, draft.id.isEmpty {
                        draftCard(draft)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "magnifyingglass")
                            .font(Theme.font(12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("Search workflows", text: $search)
                            .textFieldStyle(.plain)
                            .font(Theme.font(13))
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
                    if !model.scopedRuns.isEmpty {
                        recentRuns
                    }
                }
                .padding(Theme.Space.m)
            }
        }
    }

    private var designRecipes: [WorkflowRecipe] {
        WorkflowRecipes.recipes(from: model.pickerBackends())
    }

    private var isWarming: Bool {
        !model.hasLoaded && model.errorMessage == nil
    }

    /// A new graph belongs where you are standing. Inside a folder that is
    /// this folder, and with one folder registered there is nowhere else it
    /// could sensibly go.
    private var defaultScope: WorkflowScope {
        defaultWorkspaceID == nil ? .global : .workspace
    }

    private var defaultWorkspaceID: String? {
        model.scope ?? (folders.count == 1 ? folders.first?.id : nil)
    }

    /// Design binds to the folder whose board this is, not the first
    /// registered folder. Empty until a folder exists.
    private func syncDesignWorkspace() {
        designWorkspaceID = model.scope ?? folders.first?.id ?? ""
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

    private var intro: some View {
        HStack(alignment: .top) {
            FeatureMark(name: "mark_workflow", tint: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Workflows")
                    .font(Theme.font(24, weight: .semibold))
                Text("A map of agents, automations, HTTP and commands. Describe a run, review the draft, then save. It never starts on its own.")
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Blank draft", .create) {
                model.startBlank(scope: defaultScope, workspaceID: defaultWorkspaceID)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.canStartNewDraft)
        }
    }

    /// Whether the examples are open.
    ///
    /// Only the examples collapse. The builder itself is the point of the
    /// screen and hiding the field somebody came to type in behind a chevron
    /// costs a click every time. The examples are the part that is read once
    /// and then in the way, so they are the part that folds, and the choice is
    /// remembered. Until one is made, an empty library shows them.
    private var examplesExpanded: Bool {
        switch examplesExpandedStored {
        case "1": return true
        case "0": return false
        default: return model.hasLoaded && model.scoped.isEmpty
        }
    }

    private var builderCard: some View {
        Card(
            title: "Workflow builder",
            subtitle: "Describe a run and a cheap local agent drafts the steps, or lay them out yourself.",
            mark: "mark_workflow"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                designCard
                manualCard
            }
        }
    }

    /// The examples, behind a disclosure that remembers itself.
    @ViewBuilder
    private var examplesSection: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                examplesExpandedStored = examplesExpanded ? "0" : "1"
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "chevron.down")
                    .font(Theme.font(9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(examplesExpanded ? 0 : -90))
                Text("Or start from an example")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(examplesExpanded ? "Hide the examples" : "Show the examples")
        if examplesExpanded {
            WorkflowRecipeChips(recipes: designRecipes) { designPrompt = $0.prompt }
        }
    }

    /// The manual path, for somebody who already knows the shape they want.
    ///
    /// A blank draft used to be one unlabelled button in the header, which is
    /// no way to find the half of this feature that does not involve a model.
    /// It says what you get before you press it.
    private var manualCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Build it yourself")
                .font(Theme.callout.weight(.medium))
            Text("""
            Opens the blank canvas with a Start card. Add a step under any card, \
            drag from the dot on the bottom to join two of them, and pick who runs \
            each step in the inspector. Green joins run on success, red on error. \
            Nothing runs until you press Run.
            """)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Start blank", .create) {
                    model.startBlank(scope: defaultScope, workspaceID: defaultWorkspaceID)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.canStartNewDraft)
                Spacer()
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
        .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
    }

    private var designCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Describe the run")
                .font(Theme.callout.weight(.medium))
            Text("A cheap local agent turns the description into steps. It writes a draft you review, and it never starts the run.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Rewrite the prompt, plan it, build it, then review", text: $designPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                    .focused($designFocused)
                    .disabled(model.isDesigning)
                if !designRecipes.isEmpty {
                    examplesSection
                }
                WorkflowDesignPickers(
                    agents: WorkflowRecipes.designAgents(from: model.pickerBackends(keeping: designBackend)),
                    folders: folders,
                    backendID: $designBackend,
                    modelID: $designModel,
                    effort: $designEffort,
                    workspaceID: $designWorkspaceID
                )
                HStack(spacing: Theme.Space.s) {
                    Spacer()
                    Button(model.isDesigning ? "Designing" : "Design", .create) {
                        Task {
                            await model.design(
                                prompt: designPrompt,
                                workspaceID: designWorkspaceID.isEmpty ? nil : designWorkspaceID,
                                backend: designBackend.isEmpty ? nil : designBackend,
                                model: designModel.isEmpty ? nil : designModel,
                                effort: designEffort.isEmpty ? nil : designEffort
                            )
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(
                        model.isDesigning
                            || !model.canStartNewDraft
                            || designPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || WorkflowRecipes.designAgents(from: model.pickerBackends()).isEmpty
                    )
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
                // Steps first, then the outline that spells each one out. A
                // draft is reviewed before it is saved, and the run in one line
                // is what tells you the model understood the description.
                WorkflowStepStrip(nodes: draft.nodes, edges: draft.edges)
                WorkflowOutline(nodes: draft.nodes, edges: draft.edges)
                HStack(spacing: Theme.Space.s) {
                    Button("Save", .save) { Task { await model.saveDraft() } }
                        .buttonStyle(AccentButtonStyle())
                    Button("Discard", .dismiss) { model.discardDraft() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Text("\(draft.nodes.count) nodes")
                        .font(Theme.caption)
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
                .disabled(!model.canStartNewDraft)
            }
        }
    }

    private var filtered: [WorkflowGraph] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.scoped }
        return model.scoped.filter { graph in
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
                WidthReader { width in
                VStack(spacing: 0) {
                    ForEach(graphs) { graph in
                        WorkflowRow(
                            graph: graph,
                            compact: width > 0 && width < .rowDetailWidth,
                            last: model.lastRun(for: graph),
                            history: model.runs(of: graph),
                            folder: folders.first { $0.id == graph.workspaceID },
                            isSelected: model.selectedGraphID == graph.id,
                            onSelect: { model.selectGraph(graph.id) },
                            onRun: { running = graph },
                            onViewRun: { model.selectRun($0) },
                            onDelete: { confirmingDelete = graph }
                        )
                        if graph.id != graphs.last?.id { ThemeRule() }
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
                }
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
                ForEach(Array(model.scopedRuns.prefix(6))) { run in
                    runRow(run)
                    if run.id != model.scopedRuns.prefix(6).last?.id { ThemeRule() }
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
                .font(Theme.callout.weight(.medium))
            Text(run.endedLabel)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Against the longest run on screen, so the list answers "which of
            // these was the long one" without anybody doing subtraction.
            DurationBar(seconds: seconds(of: run), longest: longestRunSeconds)
            Text(run.startedAt.formatted(date: .omitted, time: .shortened))
                .font(Theme.caption)
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

    /// Seconds a run took, or has taken so far.
    private func seconds(of run: WorkflowRunRecord) -> Double {
        guard let ended = run.endedAtMs else { return 0 }
        return max(0, Double(ended - run.startedAtMs) / 1000)
    }

    /// Scale for the duration bars, from the runs actually on screen.
    private var longestRunSeconds: Double {
        model.runs.prefix(6).map { seconds(of: $0) }.max() ?? 0
    }

    static func statusTint(_ status: String) -> Color {
        RunOutcome.tint(status)
    }
}

/// One saved graph in the library.
private struct WorkflowRow: View {
    let graph: WorkflowGraph
    /// A narrow window. The name and the state stay, the detail beside them
    /// goes, rather than every element keeping a share of a width none of them
    /// can use.
    var compact: Bool = false
    let last: WorkflowRunRecord?
    /// Newest first, as the model keeps them.
    let history: [WorkflowRunRecord]
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(graph.name)
                            .font(Theme.font(13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        // The graph itself, and where a live run has got to.
                        // The old caption said "7 nodes", which is the one fact
                        // about a workflow nobody needs.
                        MiniGraph(
                            nodes: graph.nodes,
                            edges: graph.edges,
                            steps: live?.steps ?? [],
                            currentNodeID: live?.currentNodeID,
                            dot: 18
                        )
                    }
                    Spacer(minLength: 0)
                    if !compact {
                        Text(caption)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        RunHistoryStrip(ticks: ticks, height: 12)
                    }
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

    /// The run whose progress the strip should show, if one is in flight.
    private var live: WorkflowRunRecord? {
        guard let last, last.isLive else { return nil }
        return last
    }

    /// Where it lives. The outcome is a pill and the shape is a strip, so this
    /// is down to the one fact neither of those carries.
    private var caption: String {
        if let folder { return folder.name }
        return graph.scope.label
    }

    /// Oldest first, which is the direction the strip reads.
    private var ticks: [RunHistoryStrip.Tick] {
        history.reversed().map { run in
            RunHistoryStrip.Tick(
                id: run.id,
                status: run.status,
                label: "\(run.endedLabel) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        }
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
                                .font(Theme.font(12, weight: .medium))
                                .foregroundStyle(.primary)
                            Text(node.subtitle)
                                .font(Theme.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let step = steps.first(where: { $0.nodeID == node.id }) {
                            StatusPill(status: step.status, text: step.endedLabel)
                        } else {
                            Text(node.kind.label)
                                .font(Theme.caption2)
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
                .font(Theme.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 28)
        }
    }
}

/// Confirm the starting prompt and the workspace this run should use.
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
                        .font(Theme.font(15, weight: .semibold))
                    Text("The starting prompt fills {{input}} in every node.")
                        .font(Theme.caption)
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
            if folders.isEmpty {
                Text("Add a workspace first. Agents run in a folder.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                AppMenuPicker(
                    title: "Workspace",
                    options: [(value: "", label: "Choose a workspace")]
                        + folders.map { (value: $0.id, label: $0.name) },
                    selection: $workspaceID
                )
                Text("Agents and commands run in this workspace.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(working ? "Starting" : "Run", .run) {
                    working = true
                    Task {
                        await model.run(
                            graph,
                            input: input,
                            workspaceID: workspaceID.isEmpty ? nil : workspaceID
                        )
                        working = false
                        if model.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(working || workspaceID.isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 420)
        .onAppear {
            workspaceID = graph.workspaceID ?? folders.first?.id ?? ""
        }
    }
}
