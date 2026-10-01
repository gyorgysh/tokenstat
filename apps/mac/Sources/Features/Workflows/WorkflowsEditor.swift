// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import SwiftUI

#if os(macOS)
/// The Blueprint: palette, canvas, and the graph currently being edited.
///
/// The host IR is the source of truth. This view edits a working copy and
/// writes it back on Save. Design-from-prompt still lands as a draft here.
struct WorkflowsEditor: View {
    @Bindable var model: WorkflowsModel
    var folders: [WorkspaceFolder]
    var onBack: () -> Void

    @State private var paletteOpen = true
    @State private var running: WorkflowGraph?
    @State private var designing = false
    @State private var name = ""

    /// Width below which the palette would leave no canvas worth having.
    ///
    /// A 220 point column beside a 480 point window is most of the editor spent
    /// on a list of things to add, with nowhere to put them. Below this the
    /// canvas keeps the pane and nodes are added with the + under each card,
    /// which is the way most of them get added anyway.
    private static let paletteFloor: CGFloat = 700

    var body: some View {
        WidthReader { width in
            // An unmeasured width is not a narrow one: treating the first
            // frame's zero as "no room" flashed the palette closed every time
            // the editor opened.
            let roomForPalette = width == 0 || width >= Self.paletteFloor
            VStack(spacing: 0) {
                chrome(width: width, roomForPalette: roomForPalette)
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.top, Theme.Space.s)
                }
                ThemeRule()
                HStack(spacing: 0) {
                    if paletteOpen && roomForPalette {
                        WorkflowPalette(model: model)
                            .frame(width: 220)
                        ThemeRule.vertical
                    }
                    WorkflowCanvas(
                        model: model,
                        run: liveRun
                    )
                }
            }
        }
        .background(Theme.background)
        .onAppear { name = model.working?.name ?? "" }
        .onChange(of: model.working?.id) { _, _ in
            name = model.working?.name ?? ""
        }
        .sheet(item: $running) { graph in
            RunWorkflowSheet(model: model, graph: graph, folders: folders)
        }
        .sheet(isPresented: $designing) {
            WorkflowDesignSheet(model: model, folders: folders)
        }
        #if os(macOS)
        .onDeleteCommand { model.deleteSelection() }
        #endif
    }

    private var liveRun: WorkflowRunRecord? {
        guard let graph = model.working else { return nil }
        return model.lastRun(for: graph)?.isLive == true ? model.lastRun(for: graph) : nil
    }

    /// Width below which the toolbar drops its button labels.
    ///
    /// Save and Run are the two things somebody came to this screen to press,
    /// and both sit at the right end, so a row that overflows takes exactly
    /// those away. Glyph-only buttons keep every action on screen at a width
    /// where the labels cannot all fit.
    private static let labelFloor: CGFloat = 1000

    private func chrome(width: CGFloat, roomForPalette: Bool) -> some View {
        let compact = width > 0 && width < Self.labelFloor
        // Shrink first, scroll only as the last resort. The scroll view is what
        // keeps a 400 point window usable at all, but it is not the answer to
        // an ordinary narrow window: it would hide the Run button rather than
        // make room for it. `fixedSize` vertically because a ScrollView is
        // greedy on both axes, and this one would otherwise take its share of
        // the pane's height from the canvas.
        return ScrollView(.horizontal, showsIndicators: false) {
            chromeContent(compact: compact, roomForPalette: roomForPalette)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 8)
                .environment(\.compactActions, compact)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.tabStrip)
    }

    private func chromeContent(compact: Bool, roomForPalette: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Button(L10n.text("apple.workflowseditor.library.dc20b3d5"), .back) { onBack() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            // No button for a palette this window has no room for: a toggle
            // that changes nothing is worse than the missing column.
            if roomForPalette {
                Button(paletteOpen ? L10n.text("apple.workflowseditor.hide_palette.7bf7d98e") : L10n.text("apple.workflowseditor.palette.85794eff"), .layout) {
                    paletteOpen.toggle()
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
            TextField(L10n.text("apple.workflowseditor.name.dcd1d522"), text: $name)
                .textFieldStyle(.themed)
                .frame(width: compact ? 150 : 220)
                .onChange(of: name) { _, next in
                    guard next != model.working?.name else { return }
                    model.beginGroupedEdit()
                    model.writeWorking { $0.name = next }
                }
            if let graph = model.working {
                AppMenuPicker(
                    title: "",
                    options: WorkflowScope.allCases.map { (value: $0, label: $0.label) },
                    selection: Binding(
                        get: { graph.scope },
                        set: { model.setWorkingScope($0, workspaceID: graph.workspaceID ?? folders.first?.id) }
                    )
                )
                .frame(width: compact ? 118 : 148)
                if graph.scope == .workspace {
                    AppMenuPicker(
                        title: "",
                        options: folders.map { (value: $0.id, label: $0.name) },
                        selection: Binding(
                            get: { graph.workspaceID ?? folders.first?.id ?? "" },
                            set: { model.setWorkingScope(.workspace, workspaceID: $0) }
                        )
                    )
                    .frame(width: compact ? 128 : 168)
                }
            }
            if model.isDirty {
                Text(L10n.text("apple.workflowseditor.unsaved.6250d572"))
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            }
            Spacer()
            Button(L10n.text("apple.workflowseditor.undo.a8283ade"), .restore) { model.undo() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!model.canUndo)
            if model.canRedo {
                Button(L10n.text("apple.workflowseditor.redo.74273989"), .next) { model.redo() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            if model.isDirty {
                Button(L10n.text("apple.workflowseditor.discard.eb1a70e3"), .dismiss) { discardEdits() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            Button(L10n.text("common.save"), .save) { Task { await model.saveWorking() } }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(!model.isDirty && !(model.working?.id.isEmpty ?? true))
            Button(L10n.text("apple.workflowseditor.design.0072e6b9"), .create) {
                if model.isDirty {
                    model.errorMessage = L10n.text("apple.workflowseditor.save_or_discard_this_draft_first.274b905e")
                } else {
                    designing = true
                }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            if let graph = model.working, !graph.id.isEmpty {
                if let run = liveRun, run.isWaiting {
                    Button(L10n.text("apple.workflowseditor.continue.31fbef16"), .next) { Task { await model.continueRun(run) } }
                        .buttonStyle(AccentButtonStyle(small: true))
                } else if let run = liveRun {
                    Button(L10n.text("common.stop"), .stop) { Task { await model.stop(run) } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                } else {
                    Button(L10n.text("common.run"), .run) { running = graph }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(model.isDirty)
                        .help(model.isDirty
                            ? L10n.text("apple.workflowseditor.save_or_discard_the_unsaved_changes_before.97876b0e")
                            : L10n.text("apple.workflowseditor.run_this_workflow.e1912bd8"))
                }
            }
        }
        // Every control keeps the width its label needs. Without this the
        // scroll view proposes its own width to the row and the labels wrap
        // again, inside a view that was supposed to fix exactly that.
        .fixedSize()
    }

    private func discardEdits() {
        if model.working?.id.isEmpty == true {
            model.discardDraft()
            onBack()
        } else {
            model.revertWorking()
            name = model.working?.name ?? name
        }
    }
}

/// Left of the canvas. Tiles add a node to the working graph.
struct WorkflowPalette: View {
    @Bindable var model: WorkflowsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("apple.workflowseditor.add.0ecba137"))
                    .font(Theme.sectionHeader)
                    .foregroundStyle(.tertiary)
                paletteButton(title: L10n.text("apple.workflowseditor.input.36ecb4f8"), subtitle: L10n.text("apple.workflowseditor.starting_prompt.407bec2f"), kind: .input, mark: "mark_todo")
                ForEach(model.pickerBackends()) { backend in
                    Button {
                        model.addNode(kind: .agent, backend: backend.id)
                    } label: {
                        paletteLabel(
                            title: backend.label,
                            subtitle: L10n.text("apple.workflowseditor.agent.11b39c93"),
                            leading: { HarnessMark(id: backend.id, size: 20) }
                        )
                    }
                    .buttonStyle(.plain)
                }
                paletteButton(title: L10n.text("apple.workflowseditor.http.56d6f321"), subtitle: L10n.text("apple.workflowseditor.host_owned_request.f7355983"), kind: .http, mark: "mark_sync")
                paletteButton(title: L10n.text("apple.workflowseditor.command.71316697"), subtitle: L10n.text("apple.workflowseditor.shell_in_the_folder.b6875024"), kind: .command, mark: "mark_terminal")
                paletteButton(title: L10n.text("apple.workflowseditor.gate.fa77a525"), subtitle: L10n.text("apple.workflowseditor.wait_for_you.d955a62d"), kind: .gate, mark: "mark_note")
                paletteButton(title: L10n.text("apple.workflowseditor.if.1e3abf61"), subtitle: L10n.text("apple.workflowseditor.then_or_else.2318a255"), kind: .condition, mark: "mark_plan")
                paletteButton(title: L10n.text("apple.workflowseditor.loop.f2f6a018"), subtitle: L10n.text("apple.workflowseditor.repeat_a_body.a05cb63b"), kind: .loop, mark: "mark_scheduler")
                if !model.jobs.isEmpty {
                    Text(L10n.text("apple.workflowseditor.automations.e5ced470"))
                        .font(Theme.sectionHeader)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Space.s)
                    ForEach(model.jobs) { job in
                        Button {
                            model.addNode(kind: .automation, automationID: job.id)
                        } label: {
                            paletteLabel(
                                title: job.name,
                                subtitle: L10n.text("apple.workflowseditor.run_automation.4c10763f"),
                                leading: { FeatureMark(name: "mark_automation", tint: Theme.accent, size: 20) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(L10n.text("apple.workflowseditor.a_timer_cannot_commit_use_an_agent_an_auto.09e8f357"))
                    .font(Theme.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.s)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.sidebar)
    }

    private func paletteButton(title: String, subtitle: String, kind: WorkflowNodeKind, mark: String) -> some View {
        Button {
            model.addNode(kind: kind)
        } label: {
            paletteLabel(
                title: title,
                subtitle: subtitle,
                leading: { FeatureMark(name: mark, tint: Theme.accent, size: 20) }
            )
        }
        .buttonStyle(.plain)
    }

    private func paletteLabel<Leading: View>(
        title: String,
        subtitle: String,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .contentShape(.rect)
    }
}

/// Design-from-prompt from the canvas. Same contract as the library card.
struct WorkflowDesignSheet: View {
    @Bindable var model: WorkflowsModel
    var folders: [WorkspaceFolder]
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var backend = ""
    @State private var modelID = ""
    @State private var effort = ""
    @State private var workspaceID = ""

    var body: some View {
        ThemedSheet(
            title: L10n.text("apple.workflowseditor.design_a_workflow.0988799d"),
            subtitle: L10n.text("apple.workflowseditor.a_cheap_local_backend_drafts_the_graph_you.8f2ae7a1"),
            icon: .create,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                }
                TextField(L10n.text("apple.workflowseditor.describe_the_run.4c35945c"), text: $prompt, axis: .vertical)
                    .textFieldStyle(.themedMultiline)
                    .lineLimit(3...8)
                    .disabled(model.isDesigning)
                if !designRecipes.isEmpty {
                    WorkflowRecipeChips(recipes: designRecipes) { prompt = $0.prompt }
                }
                WorkflowDesignPickers(
                    agents: WorkflowRecipes.designAgents(from: model.pickerBackends(keeping: backend)),
                    folders: folders,
                    backendID: $backend,
                    modelID: $modelID,
                    effort: $effort,
                    workspaceID: $workspaceID
                )
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(model.isDesigning ? L10n.text("apple.workflowseditor.designing.e7034237") : L10n.text("apple.workflowseditor.design.0072e6b9"), .create) {
                Task {
                    await model.design(
                        prompt: prompt,
                        workspaceID: workspaceID.isEmpty ? nil : workspaceID,
                        backend: backend.isEmpty ? nil : backend,
                        model: modelID.isEmpty ? nil : modelID,
                        effort: effort.isEmpty ? nil : effort
                    )
                    if model.errorMessage == nil {
                        dismiss()
                    }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(
                model.isDesigning
                    || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || WorkflowRecipes.designAgents(from: model.pickerBackends()).isEmpty
            )
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 560, height: 520)
        .onAppear {
            backend = WorkflowRecipes.defaultBackend(from: model.pickerBackends())
            workspaceID = model.working?.workspaceID ?? folders.first?.id ?? ""
        }
    }

    private var designRecipes: [WorkflowRecipe] {
        WorkflowRecipes.recipes(from: model.pickerBackends())
    }
}
#endif
