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

    var body: some View {
        VStack(spacing: 0) {
            chrome
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
            }
            Divider()
            HStack(spacing: 0) {
                if paletteOpen {
                    WorkflowPalette(model: model)
                        .frame(width: 220)
                    Divider()
                }
                WorkflowCanvas(
                    model: model,
                    run: liveRun
                )
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

    private var chrome: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Library", .back) { onBack() }
                .buttonStyle(SecondaryButtonStyle(small: true))
            Button(paletteOpen ? "Hide palette" : "Palette", .layout) {
                paletteOpen.toggle()
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onChange(of: name) { _, next in
                    guard next != model.working?.name else { return }
                    model.beginGroupedEdit()
                    model.writeWorking { $0.name = next }
                }
            if let graph = model.working {
                Picker("Scope", selection: Binding(
                    get: { graph.scope },
                    set: { model.setWorkingScope($0, workspaceID: graph.workspaceID ?? folders.first?.id) }
                )) {
                    ForEach(WorkflowScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                if graph.scope == .workspace {
                    Picker("Folder", selection: Binding(
                        get: { graph.workspaceID ?? "" },
                        set: { model.setWorkingScope(.workspace, workspaceID: $0) }
                    )) {
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }
            if model.isDirty {
                Text("Unsaved")
                    .font(.caption.weight(.medium))
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
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 8)
        .background(Theme.tabStrip)
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
                    .font(.caption2)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
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
    @State private var workspaceID = ""

    private static let chips = [
        "Plan then build then review",
        "Commit and push",
        "Run tests then notify",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Design a workflow")
                        .font(.system(size: 15, weight: .semibold))
                    Text("A cheap local backend drafts the graph. You review it. It does not run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close")
            }
            if let error = model.errorMessage {
                Banner(text: error, severity: .warning)
            }
            TextField("Describe the run", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .disabled(model.isDesigning)
            HStack(spacing: Theme.Space.s) {
                ForEach(Self.chips, id: \.self) { chip in
                    Button(chip, .create) { prompt = chip }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            HStack(spacing: Theme.Space.s) {
                Picker("Backend", selection: $backend) {
                    ForEach(model.pickerBackends(keeping: backend)) { item in
                        Text(item.label).tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                if !folders.isEmpty {
                    Picker("Folder", selection: $workspaceID) {
                        Text("No folder").tag("")
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                Spacer()
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(model.isDesigning ? "Designing" : "Design", .create) {
                    Task {
                        await model.design(
                            prompt: prompt,
                            workspaceID: workspaceID.isEmpty ? nil : workspaceID,
                            backend: backend.isEmpty ? nil : backend
                        )
                        if model.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(model.isDesigning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 460)
        .onAppear {
            backend = model.pickerBackends().first?.id ?? ""
            workspaceID = model.working?.workspaceID ?? folders.first?.id ?? ""
        }
    }
}
#endif
