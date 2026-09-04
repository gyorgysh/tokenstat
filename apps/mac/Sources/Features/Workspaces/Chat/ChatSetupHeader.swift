// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Conversation setup before the first turn, then a one-line chip strip.
///
/// Settings matter most before you commit and least once you are reading.
/// After a turn has run, the same controls live behind Edit setup.
struct ChatSetupHeader: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var collapsed: Bool
    /// The in-conversation header explains that settings will move. The
    /// inspector already is that place, so it skips the intro.
    var showsIntro: Bool = true
    var onOpenInspector: (() -> Void)? = nil

    var body: some View {
        Group {
            if collapsed {
                chips
            } else {
                form
            }
        }
        .onAppear { enforceBypassOnly() }
        .onChange(of: chat.backend) { _, _ in enforceBypassOnly() }
    }

    /// The persona picker, with the chosen one's face beside it.
    ///
    /// The face is the point of the row: a name in a menu is a setting, and a
    /// character sitting next to it is the thing you recognise from the
    /// transcript. Split out of `form` because the type checker gave up on
    /// that expression once the options list grew a second clause.
    private var personaRow: some View {
        HStack(spacing: Theme.Space.s) {
            PersonaMark(seed: model.faceSeed, size: 30)
            AppMenuPicker(
                title: "Persona",
                options: personaOptions,
                selection: personaBinding
            )
            .disabled(chat.running)
        }
    }

    private var personaOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [(value: "", label: "No persona")]
        for persona in model.personas {
            options.append((value: persona.id, label: persona.name))
        }
        return options
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if showsIntro {
                Text("How this chat should work")
                    .font(Theme.callout.weight(.semibold))
                Text("These stay here until the first message. After that they collapse, and Edit setup still has them.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            agentRow
            if !model.personas.isEmpty {
                personaRow
            }
            SegmentedCapsulePicker(
                options: [
                    (value: "plan", label: "Plan", symbol: ActionIcon.plan.symbol),
                    (value: "execute", label: "Execute", symbol: "hammer"),
                ],
                selection: modeBinding
            )
            .disabled(chat.running)
            Toggle("Work without asking", isOn: bypassBinding)
                .toggleStyle(.brandCheckbox)
                .disabled(chat.running || isBypassOnly)
            Text(ChatGateCopy.explanation(backend?.gateTier, bypass: chat.autonomy == "bypass"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private var chips: some View {
        HStack(spacing: Theme.Space.s) {
            chip("Next response: \(backend?.label ?? chat.backend)")
            chip(chat.mode == "plan" ? "Plan" : "Execute")
            if let modelName = chat.model, !modelName.isEmpty {
                chip(modelName)
            }
            chip(chat.autonomy == "bypass"
                ? "Bypass"
                : ChatGateCopy.chip(backend?.gateTier))
            Spacer(minLength: 0)
            if let onOpenInspector {
                Button("Edit setup", .settings) { onOpenInspector() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .environment(\.compactActions, true)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
    }

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                AppMenuPicker(
                    title: "Agent",
                    options: agentOptions,
                    selection: backendBinding
                )
                .disabled(chat.running)
            }
            if let backend, !backend.models.isEmpty || !backend.efforts.isEmpty {
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    if !backend.models.isEmpty {
                        FavoriteModelPicker(
                            backendID: backend.id,
                            models: backend.models,
                            extra: chat.model ?? "",
                            selection: modelBinding
                        )
                        .disabled(chat.running)
                    }
                    if !backend.efforts.isEmpty {
                        AppMenuPicker(
                            title: "Effort",
                            options: [(value: "", label: "Default")]
                                + backend.efforts.map { (value: $0, label: $0) },
                            selection: effortBinding
                        )
                        .disabled(chat.running)
                    }
                }
            }
        }
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var isBypassOnly: Bool { backend?.gateTier == "bypassOnly" }

    private var agentOptions: [(value: String, label: String)] {
        model.backends
            .filter { $0.id != "sh" || $0.id == chat.backend }
            .map { (value: $0.id, label: $0.label) }
    }

    private var backendBinding: Binding<String> {
        Binding(
            get: { chat.backend },
            set: { next in
                Task {
                    if model.backend(for: next)?.gateTier == "bypassOnly" {
                        await model.update(backend: next, autonomy: "bypass")
                    } else {
                        await model.update(backend: next)
                    }
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { chat.model ?? "" },
            set: { next in Task { await model.update(model: next) } }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { chat.effort ?? "" },
            set: { next in Task { await model.update(effort: next) } }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { chat.mode },
            set: { next in Task { await model.update(mode: next) } }
        )
    }

    private var bypassBinding: Binding<Bool> {
        Binding(
            get: { chat.autonomy == "bypass" },
            set: { next in Task { await model.update(autonomy: next ? "bypass" : "standard") } }
        )
    }

    private var personaBinding: Binding<String> {
        Binding(
            get: { chat.personaID ?? "" },
            set: { id in
                Task { await model.applyPersona(model.personas.first { $0.id == id }) }
            }
        )
    }

    private func enforceBypassOnly() {
        guard isBypassOnly, chat.autonomy != "bypass", !chat.running else { return }
        Task { await model.update(autonomy: "bypass") }
    }
}

/// One field for agent, model and effort. Plan and permission sit beside it.
///
/// Full setup stays in the inspector. These controls must not stretch across
/// the well: each takes its own width, the field is the message.
struct ChatComposerControls: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.s) { content }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ChatAgentMenu(model: model, chat: chat, locked: locked)
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    pills
                }
            }
        }
        .onAppear { enforceBypassOnly() }
        .onChange(of: chat.backend) { _, _ in enforceBypassOnly() }
    }

    @ViewBuilder
    private var content: some View {
        ChatAgentMenu(model: model, chat: chat, locked: locked)
        pills
    }

    @ViewBuilder
    private var pills: some View {
        ChatCompactPills(
            options: [
                (value: "plan", label: "Plan"),
                (value: "execute", label: "Execute"),
            ],
            selection: modeBinding
        )
        .disabled(locked)
        if isBypassOnly {
            Text("Bypass")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.accentSoft, in: Capsule())
        } else {
            ChatCompactPills(
                options: [
                    (value: "standard", label: "Ask"),
                    (value: "bypass", label: "Bypass"),
                ],
                selection: autonomyBinding
            )
            .disabled(locked)
        }
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var isBypassOnly: Bool { backend?.gateTier == "bypassOnly" }

    private var modeBinding: Binding<String> {
        Binding(
            get: { chat.mode },
            set: { next in Task { await model.update(mode: next) } }
        )
    }

    private var autonomyBinding: Binding<String> {
        Binding(
            get: { chat.autonomy },
            set: { next in Task { await model.update(autonomy: next) } }
        )
    }

    private func enforceBypassOnly() {
        guard isBypassOnly, chat.autonomy != "bypass", !chat.running else { return }
        Task { await model.update(autonomy: "bypass") }
    }
}

/// Nested Agent / Model / Effort from one compact field.
/// Agent, model and effort in one panel you can type into.
///
/// This was three nested menus, declared twice: once for macOS and once for
/// iOS, because iOS renders a nested `Menu` bottom-up inside the glass sheet
/// and the only way to keep the visual order the same on both was to write the
/// sections out backwards. That is gone. One panel, three sections, one
/// declaration, and the filter runs across all of them, so typing "meta" in a
/// forty-model list gets there in four keystrokes instead of a scroll.
///
/// The Refresh lives here, not in the app's settings, because this is where
/// somebody notices the list is short: they added an API key to a CLI a minute
/// ago and the provider it unlocked is not in the list yet. See
/// `ChatModel.reloadBackends`.
private struct ChatAgentMenu: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool

    @State private var isPresented = false
    @State private var canRefresh = false
    @State private var favorites = ModelFavoritesStore.shared

    /// One row of the panel. Three kinds of choice share a list, so they share
    /// a value: the section a row came from is what says which of the three
    /// the person just changed.
    private enum Choice: Hashable {
        case agent(String)
        /// Empty is the agent's own default.
        case model(String)
        case effort(String)
    }

    var body: some View {
        PickerPanel(title: "Agent, model and effort", isPresented: $isPresented) {
            PickerOptionList(
                choices: choices,
                isSelected: isSelected,
                prompt: "Filter agents, models and efforts",
                emptyMessage: "No agents available",
                caption: "Three settings for this conversation.",
                refresh: canRefresh ? { await model.reloadBackends() } : nil,
                sectionValue: currentValue,
                sectionTabs: selectableSections,
                pick: pick,
                accessory: { value in AnyView(star(for: value)) }
            )
            .task(id: model.peer ?? "local") {
                canRefresh = await RemoteHostFeature.modelRefresh.isSupported(peer: model.peer)
            }
        } label: {
            HStack(spacing: 6) {
                Text(summary)
                    .font(Theme.font(12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.fixed(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .disabled(locked)
        .fixedSize(horizontal: true, vertical: true)
        .help("Agent, model and effort")
        .accessibilityLabel(summary)
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }

    /// Every row, in the order the sections have always been read in.
    private var choices: [PickerChoice<Choice>] {
        var rows = agentOptions.map {
            PickerChoice(value: Choice.agent($0.value), label: $0.label, section: "Agent")
        }
        if let backend, !backend.models.isEmpty {
            rows.append(
                PickerChoice(
                    value: .model(""),
                    label: "Default",
                    detail: "\(backend.label) picks the model",
                    section: "Model"
                )
            )
            rows += modelIDs.map {
                PickerChoice(value: Choice.model($0), label: $0, section: "Model")
            }
        }
        if let backend, !backend.efforts.isEmpty {
            rows.append(PickerChoice(value: .effort(""), label: "Default", section: "Effort"))
            rows += backend.efforts.map {
                PickerChoice(value: Choice.effort($0), label: $0, section: "Effort")
            }
        }
        return rows
    }

    /// Only show filters that have choices for the selected agent. For
    /// example, an agent with no effort control should not advertise one.
    private var selectableSections: [String] {
        var seen = Set<String>()
        return choices.compactMap { choice in
            seen.insert(choice.section).inserted ? choice.section : nil
        }
    }

    /// What each section is set to, for its heading. The panel is three
    /// settings, and a heading that only names the group leaves somebody
    /// scrolling to find which row carries the mark.
    private func currentValue(_ section: String) -> String? {
        switch section {
        case "Agent": backend?.label ?? chat.backend
        case "Model": (chat.model?.isEmpty == false ? chat.model : "Default")
        case "Effort": (chat.effort?.isEmpty == false ? chat.effort : "Default")
        default: nil
        }
    }

    /// Three marks in one list, one per section, each reading the
    /// conversation's own setting.
    private func isSelected(_ choice: Choice) -> Bool {
        switch choice {
        case let .agent(id): id == chat.backend
        case let .model(id): id == (chat.model ?? "")
        case let .effort(id): id == (chat.effort ?? "")
        }
    }

    private func pick(_ choice: Choice) {
        switch choice {
        case let .agent(id):
            Task {
                if model.backend(for: id)?.gateTier == "bypassOnly" {
                    await model.update(backend: id, autonomy: "bypass")
                } else {
                    await model.update(backend: id)
                }
            }
        case let .model(id):
            Task { await model.update(model: id) }
            isPresented = false
        case let .effort(id):
            Task { await model.update(effort: id) }
            isPresented = false
        }
    }

    /// The favourite star, on model rows only. Same store as before, so what
    /// somebody starred in the old menu is still pinned in this one.
    @ViewBuilder
    private func star(for choice: Choice) -> some View {
        if case let .model(id) = choice, !id.isEmpty, let backend {
            Button {
                favorites.toggle(backend: backend.id, model: id)
            } label: {
                Image(systemName: favorites.contains(backend: backend.id, model: id)
                    ? "star.fill" : "star")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(
                        favorites.contains(backend: backend.id, model: id)
                            ? Theme.accent : Color.secondary.opacity(0.4)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                favorites.contains(backend: backend.id, model: id)
                    ? "Unpin \(id)" : "Pin \(id)"
            )
        }
    }

    private var agentOptions: [(value: String, label: String)] {
        model.backends
            .filter { $0.id != "sh" || $0.id == chat.backend }
            .map { (value: $0.id, label: $0.label) }
    }

    private var modelIDs: [String] {
        guard let backend else { return [] }
        var ids = backend.models
        let extra = chat.model ?? ""
        if !extra.isEmpty, !ids.contains(extra) {
            ids.insert(extra, at: 0)
        }
        let favs = ModelFavoritesStore.shared.ids(for: backend.id).filter { ids.contains($0) }
        let rest = ids.filter { !favs.contains($0) }
        return favs + rest
    }

    private var summary: String {
        let agent = backend?.label ?? chat.backend
        var parts = [agent]
        if let name = chat.model, !name.isEmpty {
            parts.append(name)
        } else {
            parts.append("Default")
        }
        if let effort = chat.effort, !effort.isEmpty {
            parts.append(effort)
        }
        return parts.joined(separator: " · ")
    }
}

/// Compact pills that keep their own width. `SegmentedCapsulePicker` stretches.
struct ChatCompactPills: View {
    var options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(option.value == selection ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.value == selection ? Theme.accentSoft : .clear)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}
