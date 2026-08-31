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
            Button("Library", .back) { onBack() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            // No button for a palette this window has no room for: a toggle
            // that changes nothing is worse than the missing column.
            if roomForPalette {
                Button(paletteOpen ? "Hide palette" : "Palette", .layout) {
                    paletteOpen.toggle()
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
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
                Text("Unsaved")
                    .font(Theme.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
            }
            Spacer()
            Button("Undo", .restore) { model.undo() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(!model.canUndo)
            if model.canRedo {
                Button("Redo", .next) { model.redo() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            if model.isDirty {
                Button("Discard", .dismiss) { discardEdits() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            Button("Save", .save) { Task { await model.saveWorking() } }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(!model.isDirty && !(model.working?.id.isEmpty ?? true))
            Button("Design", .create) {
                if model.isDirty {
                    model.errorMessage = "Save or discard this draft first."
                } else {
                    designing = true
                }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            if let graph = model.working, !graph.id.isEmpty {
                if let run = liveRun, run.isWaiting {
                    Button("Continue", .next) { Task { await model.continueRun(run) } }
                        .buttonStyle(AccentButtonStyle(small: true))
                } else if let run = liveRun {
                    Button("Stop", .stop) { Task { await model.stop(run) } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                } else {
                    Button("Run", .run) { running = graph }
                        .buttonStyle(AccentButtonStyle(small: true))
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
                Text("ADD")
                    .font(Theme.sectionHeader)
                    .foregroundStyle(.tertiary)
                paletteButton(title: "Input", subtitle: "Starting prompt", kind: .input, mark: "mark_todo")
                ForEach(model.pickerBackends()) { backend in
                    Button {
                        model.addNode(kind: .agent, backend: backend.id)
                    } label: {
                        paletteLabel(
                            title: backend.label,
                            subtitle: "Agent",
                            leading: { HarnessMark(id: backend.id, size: 20) }
                        )
                    }
                    .buttonStyle(.plain)
                }
                paletteButton(title: "HTTP", subtitle: "Host-owned request", kind: .http, mark: "mark_sync")
                paletteButton(title: "Command", subtitle: "Shell in the folder", kind: .command, mark: "mark_terminal")
                paletteButton(title: "Gate", subtitle: "Wait for you", kind: .gate, mark: "mark_note")
                paletteButton(title: "If", subtitle: "Then or else", kind: .condition, mark: "mark_plan")
                paletteButton(title: "Loop", subtitle: "Repeat a body", kind: .loop, mark: "mark_scheduler")
                if !model.jobs.isEmpty {
                    Text("AUTOMATIONS")
                        .font(Theme.sectionHeader)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Space.s)
                    ForEach(model.jobs) { job in
                        Button {
                            model.addNode(kind: .automation, automationID: job.id)
                        } label: {
                            paletteLabel(
                                title: job.name,
                                subtitle: "Run automation",
                                leading: { FeatureMark(name: "mark_automation", tint: Theme.accent, size: 20) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("A timer cannot commit. Use an agent, an automation, or a command you press Run on.")
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
            title: "Design a workflow",
            subtitle: "A cheap local backend drafts the graph. You review it. It does not run.",
            icon: .create,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let error = model.errorMessage {
                    Banner(text: error, severity: .warning)
                }
                TextField("Describe the run", text: $prompt, axis: .vertical)
                    .textFieldStyle(.themed)
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
            Button("Cancel", .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(model.isDesigning ? "Designing" : "Design", .create) {
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
