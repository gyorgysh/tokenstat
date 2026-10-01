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
        .navigationTitle(L10n.text("common.workflows"))
        .background(Theme.background)
        .sheet(item: $running) { graph in
            RunWorkflowSheet(model: model, graph: graph, folders: folders)
        }
        .confirmationDialog(
            L10n.text("apple.workflowsview.delete_0.dc6c5ae4", "\(confirmingDelete?.name ?? L10n.text("apple.workflowsview.this_workflow.a7b5fc94"))"),
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            )
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                if let graph = confirmingDelete {
                    Task { await model.remove(graph) }
                }
                confirmingDelete = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(L10n.text("apple.workflowsview.the_graph_is_removed_past_runs_stay_on_thi.a2583b27"))
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
                EmptyView()
            }
            // Search on the left, a blank canvas on the right: the same row
            // Automations and Tasks have. The intro and the count tiles that
            // used to stand here said what the tab already says.
            HStack(spacing: Theme.Space.s) {
                SearchField(text: $search, prompt: L10n.text("apple.workflowsview.search_workflows.e827cf3e"))
                    .frame(maxWidth: 260)
                    .focused($searchFocused)
                Spacer(minLength: Theme.Space.s)
                Button(L10n.text("apple.workflowsview.blank_draft.0e175b42"), .create) {
                    model.startBlank(scope: defaultScope, workspaceID: defaultWorkspaceID)
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(!model.canStartNewDraft)
                .help(L10n.text("apple.workflowsview.arrange_the_steps_yourself_on_a_canvas.e0752ec8"))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            ThemeRule()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let error = model.errorMessage {
                        ErrorBanner(message: error) { Task { await model.load() } }
                    }
                    builderCard
                    if let draft = model.draft, draft.id.isEmpty {
                        draftCard(draft)
                    }
                    if isWarming {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Skeleton.CardPlaceholder(rows: 2)
                            Skeleton.CardPlaceholder(rows: 2)
                        }
                        .transition(.opacity)
                    } else if filtered.isEmpty && model.draft == nil {
                        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView.search(text: search)
                        } else { nothingYet }
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
                ? "\(folder.machineLabel ?? L10n.text("apple.workflowsview.remote.ffa98e02")) / \(folder.name)"
                : folder.name,
            symbol: folder.isRemote ? "network" : "folder.fill"
        )
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
            title: L10n.text("apple.workflowsview.design_a_workflow.0988799d"),
            subtitle: L10n.text("apple.workflowsview.describe_the_outcome_review_the_generated.9033b885"),
            mark: "mark_workflow"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                designCard
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
                Text(L10n.text("apple.workflowsview.or_start_from_an_example.a144c61b"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(examplesExpanded ? L10n.text("apple.workflowsview.hide_the_examples.80398b38") : L10n.text("apple.workflowsview.show_the_examples.4a2afda5"))
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
            Text(L10n.text("apple.workflowsview.build_it_yourself.72369f88"))
                .font(Theme.callout.weight(.medium))
            Text(L10n.text("apple.workflowsview.opens_the_blank_canvas_with_a_start_card_a.a7edec56"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("apple.workflowsview.start_blank.456d31e9"), .create) {
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
            WidthReader { width in
            let layout = width >= 720 ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.l)) : AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.m))
            layout {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.workflowsview.what_should_happen.cfb17824")).font(Theme.callout.weight(.medium))
                TextField(L10n.text("apple.workflowsview.rewrite_the_prompt_plan_it_build_it_then_r.29987a60"), text: $designPrompt, axis: .vertical)
                    .textFieldStyle(.themedMultiline)
                    .lineLimit(6...10)
                    .focused($designFocused)
                    .disabled(model.isDesigning)
                if !designRecipes.isEmpty {
                    examplesSection
                }
                Text(L10n.text("apple.workflowsview.prefer_to_build_visually_start_a_blank_dra.a4b0aefd"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.workflowsview.draft_configuration.95c3b7b9")).font(Theme.callout.weight(.medium))
                WorkflowDesignPickers(
                    agents: WorkflowRecipes.designAgents(from: model.pickerBackends(keeping: designBackend)),
                    folders: folders,
                    backendID: $designBackend,
                    modelID: $designModel,
                    effort: $designEffort,
                    workspaceID: $designWorkspaceID
                )
                HStack(spacing: Theme.Space.s) {
                    if model.isDesigning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(model.isDesigning ? L10n.text("apple.workflowsview.designing.f3b6dd36") : L10n.text("apple.workflowsview.generate_draft.12696858"), .create) {
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
            .padding(Theme.Space.m)
            .frame(width: width >= 720 ? 290 : nil)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Space.s))
            .overlay(RoundedRectangle(cornerRadius: Theme.Space.s).strokeBorder(Theme.border))
            }
            }
        }
    }

    private func draftCard(_ draft: WorkflowGraph) -> some View {
        Card(
            title: draft.name.isEmpty ? L10n.text("apple.workflowsview.draft.ebf12ef4") : draft.name,
            subtitle: L10n.text("apple.workflowsview.unsaved_review_the_outline_then_save_it_wi.c57fe6b3"),
            mark: "mark_workflow"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                // Steps first, then the outline that spells each one out. A
                // draft is reviewed before it is saved, and the run in one line
                // is what tells you the model understood the description.
                WorkflowStepStrip(nodes: draft.nodes, edges: draft.edges)
                WorkflowOutline(nodes: draft.nodes, edges: draft.edges)
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("common.save"), .save) { Task { await model.saveDraft() } }
                        .buttonStyle(AccentButtonStyle())
                    Button(L10n.text("apple.workflowsview.discard.eb1a70e3"), .dismiss) { model.discardDraft() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Text(L10n.text("apple.workflowsview.0_nodes.42495a92", "\(draft.nodes.count)"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onTapGesture { model.selectDraft() }
    }

    private var nothingYet: some View {
        Card(title: L10n.text("common.workflows"), subtitle: nil, mark: "mark_workflow") {
            EmptyState(
                symbol: "point.3.connected.trianglepath.dotted",
                title: L10n.text("apple.workflowsview.no_workflows_yet.d3e72e00"),
                message: L10n.text("apple.workflowsview.your_saved_workflows_will_appear_here_desc.6ef86f49")
            ) {
                EmptyView()
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
                title: L10n.text("apple.workflowsview.global.a258b30f"),
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
            title: L10n.text("apple.workflowsview.recent_runs.237112b8"),
            subtitle: L10n.text("apple.workflowsview.select_a_run_to_read_a_step_in_the_inspect.738e1797"),
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
                    Button(L10n.text("apple.workflowsview.continue.31fbef16"), .next) { onViewRun(last) }
                        .buttonStyle(AccentButtonStyle(small: true))
                } else {
                    Button(L10n.text("common.open"), .preview) { onViewRun(last) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            } else {
                Button(L10n.text("common.run"), .run) { onRun() }
                    .buttonStyle(AccentButtonStyle(small: true))
            }
            Button(L10n.text("common.delete"), .delete, role: .destructive) { onDelete() }
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
            Text(L10n.text("apple.workflowsview.joins_0_steps.fe010394", "\(incoming.count)"))
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
        ThemedSheet(
            title: L10n.text("apple.workflowsview.run_0.815f1347", "\(graph.name)"),
            subtitle: L10n.text("apple.workflowsview.the_starting_prompt_fills_input_in_every_n.1cfd180d"),
            icon: .run,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error = model.errorMessage {
                    ErrorBanner(message: error) { Task { await model.load() } }
                }
                TextField(L10n.text("apple.workflowsview.starting_prompt.407bec2f"), text: $input, axis: .vertical)
                    .textFieldStyle(.themed)
                    .lineLimit(3...8)
                if folders.isEmpty {
                    Text(L10n.text("apple.workflowsview.add_a_project_first_agents_run_in_a_folder.21857ea2"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                } else {
                    AppMenuPicker(
                        title: L10n.text("apple.workflowsview.project.98595978"),
                        options: [(value: "", label: L10n.text("apple.workflowsview.choose_a_project.8ba607b1"))]
                            + folders.map { (value: $0.id, label: $0.name) },
                        selection: $workspaceID
                    )
                    Text(L10n.text("apple.workflowsview.agents_and_commands_run_in_this_workspace.0ab3feab"))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(working ? L10n.text("apple.workflowsview.starting.aeed4d26") : L10n.text("common.run"), .run) {
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
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 540, height: 440)
        .onAppear {
            workspaceID = graph.workspaceID ?? folders.first?.id ?? ""
        }
    }
}
