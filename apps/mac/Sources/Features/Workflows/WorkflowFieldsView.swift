// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Which half of the editor is on screen. Phone uses one at a time. iPad
/// shows both.
enum WorkflowFieldsSection: Hashable {
    case graph
    case settings
}

/// Creation and editing use the same graph preview and settings vocabulary.
struct WorkflowFieldsView: View {
    @Bindable var session: WorkflowEditorSession
    let wide: Bool
    let draftStatus: String
    var showValidation = true
    var hostName: String = ""
    var nextCaption: String? = nil
    var section: WorkflowFieldsSection? = nil
    @Binding var stepPath: [String]
    /// iPad selects a step into the inspector. Phone pushes a detail.
    var selectsInPlace = false
    @State private var choosingStarter = false

    var body: some View {
        switch section {
        case .graph:
            graph(fills: true)
        case .settings:
            settings
        case nil:
            if wide {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    graph(fills: false)
                    ThemeRule.vertical
                    settings.frame(width: 280)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    graph(fills: false)
                    settings
                }
            }
        }
    }

    private func graph(fills: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            TextField("Workflow name", text: $session.fields.name, axis: .vertical)
                .font(Theme.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Workflow name")
            ThemeRule()
            if session.isCreate {
                starter
            }
            WorkflowStepListView(session: session, path: $stepPath, selectsInPlace: selectsInPlace)
            Text(draftStatus)
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }

    private var starter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start from")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    Text(starterName)
                        .font(Theme.callout.weight(.medium))
                }
                Spacer(minLength: Theme.Space.s)
                Button(choosingStarter ? "Done" : "Change", choosingStarter ? .done : .edit) {
                    choosingStarter.toggle()
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(session.creating)
            }
            if choosingStarter {
                Text("Blank is a Start step. An example fills the rest. You can change the steps after.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                WorkflowStarterPicker(
                    recipes: session.recipes,
                    selectedID: session.fields.starterID,
                    onBlank: {
                        session.applyBlank()
                        stepPath = []
                        choosingStarter = false
                    },
                    onRecipe: { recipe in
                        session.applyRecipe(recipe)
                        stepPath = []
                        choosingStarter = false
                    }
                )
            }
            describe
        }
    }

    /// Draft the steps from a prompt. The host saves nothing and runs
    /// nothing: the result is an editable draft like an example.
    @ViewBuilder
    private var describe: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Or describe it")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            TextField("Describe the run", text: $session.designPrompt, axis: .vertical)
                .textFieldStyle(.themedMultiline)
                .lineLimit(2...6)
                .disabled(session.designing || session.creating)
                .accessibilityLabel("Describe the run")
            if !session.designAgents.isEmpty {
                AppMenuPicker(
                    title: "Agent",
                    options: session.designAgents.map { (value: $0.id, label: $0.label) },
                    selection: $session.designBackend
                )
                .disabled(session.designing || session.creating)
                if let backend = session.designAgents.first(where: { $0.id == session.designBackend }) {
                    if !backend.models.isEmpty {
                        FavoriteModelPicker(
                            backendID: backend.id,
                            models: backend.models,
                            extra: session.designModel,
                            preservesSavedSelection: true,
                            selection: $session.designModel
                        )
                        .disabled(session.designing || session.creating)
                    }
                    if !backend.efforts.isEmpty {
                        AppMenuPicker(
                            title: "Effort",
                            options: [(value: "", label: "Default")]
                                + backend.efforts.map { (value: $0, label: $0) },
                            selection: $session.designEffort
                        )
                        .disabled(session.designing || session.creating)
                    }
                }
            }
            HStack(spacing: Theme.Space.s) {
                if session.designing {
                    ProgressView("Designing")
                        .font(Theme.callout)
                    Spacer(minLength: 0)
                    Button("Cancel", .dismiss) { session.cancelDesign() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                } else {
                    Button("Design", .create) { session.design() }
                        .buttonStyle(AccentButtonStyle(comfortable: true))
                        .disabled(!session.canDesign)
                }
            }
            if !session.designTranscript.isEmpty {
                Text(session.designTranscript)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.designAgents.isEmpty, session.loaded {
                Text("No supported agent is installed on this computer yet, so there is nothing to draft with. You can still start Blank.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var starterName: String {
        if session.fields.starterID == WorkflowEditorDraft.blankStarterID || session.fields.starterID.isEmpty {
            return "Blank"
        }
        if session.fields.starterID == WorkflowEditorDraft.designedStarterID {
            return "Described"
        }
        return session.recipes.first { $0.id == session.fields.starterID }?.name ?? "Example"
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if section != .settings {
                Text("Workflow settings").font(Theme.callout.weight(.semibold))
            }
            if session.lockedFolder {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    Text(session.folderName)
                        .font(Theme.callout)
                    Text("This workflow runs in this folder on the connected computer.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            }
            ThemeRule()
            AutomationScheduleFields(
                fields: $session.fields,
                hostName: hostName,
                timezone: session.schedulerTimezone,
                nextCaption: nextCaption
            )
            if session.fields.builtSchedule.repeats {
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enabled")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                        Text("On lets this schedule fire on the connected computer. Off keeps it until you press Run.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.controlGlyph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.s)
                    BrandToggleChip(
                        title: session.fields.enabled ? "On" : "Off",
                        isOn: $session.fields.enabled
                    )
                    .accessibilityLabel("Enabled")
                }
            }
            ThemeRule()
            AutomationBudgetFields(fields: $session.fields)
            if showValidation, let validation = session.fields.validation {
                Text(validation)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
    }
}

/// Blank or an example pipeline. Selected card uses the accent stroke, never
/// a system checkbox.
struct WorkflowStarterPicker: View {
    let recipes: [WorkflowRecipe]
    let selectedID: String
    var onBlank: () -> Void
    var onRecipe: (WorkflowRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            starterCard(
                id: WorkflowEditorDraft.blankStarterID,
                name: "Blank",
                nodes: WorkflowEditorDraft.blankNodes,
                edges: [],
                selected: selectedID == WorkflowEditorDraft.blankStarterID
                    || (selectedID.isEmpty && recipes.isEmpty)
            ) {
                onBlank()
            }
            ForEach(recipes) { recipe in
                starterCard(
                    id: recipe.id,
                    name: recipe.name,
                    nodes: recipe.nodes,
                    edges: recipe.edges,
                    selected: selectedID == recipe.id
                ) {
                    onRecipe(recipe)
                }
            }
        }
    }

    private func starterCard(
        id: String,
        name: String,
        nodes: [WorkflowNode],
        edges: [WorkflowEdge],
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(.primary)
                    WorkflowStepStrip(nodes: nodes, edges: edges)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Space.s))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Space.s)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
