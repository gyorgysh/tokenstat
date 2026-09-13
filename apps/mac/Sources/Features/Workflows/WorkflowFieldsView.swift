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
    @Binding var fields: WorkflowEditorDraft
    let recipes: [WorkflowRecipe]
    let folderName: String
    let folderLocked: Bool
    let wide: Bool
    let isCreate: Bool
    let draftStatus: String
    var showValidation = true
    var hostName: String = ""
    var timezone: String = ""
    var nextCaption: String? = nil
    var section: WorkflowFieldsSection? = nil
    var onBlank: () -> Void = {}
    var onRecipe: (WorkflowRecipe) -> Void = { _ in }

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
            TextField("Workflow name", text: $fields.name, axis: .vertical)
                .font(Theme.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Workflow name")
            ThemeRule()
            if isCreate {
                Text("Start from")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                Text("Blank is a Start step. An example fills the rest.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                WorkflowStarterPicker(
                    recipes: recipes,
                    selectedID: fields.starterID,
                    onBlank: onBlank,
                    onRecipe: onRecipe
                )
            } else {
                Text("Steps")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                Text("This save updates the name, schedule and budget. The steps stay as they are.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                WorkflowStepStrip(nodes: fields.nodes, edges: fields.edges)
            }
            Text(draftStatus)
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if section != .settings {
                Text("Workflow settings").font(Theme.callout.weight(.semibold))
            }
            if folderLocked {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                    Text(folderName)
                        .font(Theme.callout)
                    Text("This workflow runs in this folder on the connected computer.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                }
            }
            ThemeRule()
            AutomationScheduleFields(
                fields: $fields,
                hostName: hostName,
                timezone: timezone,
                nextCaption: nextCaption
            )
            if fields.builtSchedule.repeats {
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
                        title: fields.enabled ? "On" : "Off",
                        isOn: $fields.enabled
                    )
                    .accessibilityLabel("Enabled")
                }
            }
            ThemeRule()
            AutomationBudgetFields(fields: $fields)
            if showValidation, let validation = fields.validation {
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
