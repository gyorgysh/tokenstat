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
                AppMenuPicker(
                    title: "Persona",
                    options: [(value: "", label: "No preset")]
                        + model.personas.map { persona in
                            (
                                value: persona.id,
                                label: persona.mark.isEmpty
                                    ? persona.name
                                    : "\(persona.mark)  \(persona.name)"
                            )
                        },
                    selection: personaBinding
                )
                .disabled(chat.running)
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
            chip(backend?.label ?? chat.backend)
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
private struct ChatAgentMenu: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool

    var body: some View {
        Menu {
            Menu("Agent") {
                ForEach(agentOptions, id: \.value) { option in
                    Button {
                        Task {
                            if model.backend(for: option.value)?.gateTier == "bypassOnly" {
                                await model.update(backend: option.value, autonomy: "bypass")
                            } else {
                                await model.update(backend: option.value)
                            }
                        }
                    } label: {
                        if option.value == chat.backend {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
            if let backend, !backend.models.isEmpty {
                Menu("Model") {
                    Button {
                        Task { await model.update(model: "") }
                    } label: {
                        if (chat.model ?? "").isEmpty {
                            Label("Default", systemImage: "checkmark")
                        } else {
                            Text("Default")
                        }
                    }
                    ForEach(modelIDs, id: \.self) { id in
                        Button {
                            Task { await model.update(model: id) }
                        } label: {
                            if chat.model == id {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                }
            }
            if let backend, !backend.efforts.isEmpty {
                Menu("Effort") {
                    Button {
                        Task { await model.update(effort: "") }
                    } label: {
                        if (chat.effort ?? "").isEmpty {
                            Label("Default", systemImage: "checkmark")
                        } else {
                            Text("Default")
                        }
                    }
                    ForEach(backend.efforts, id: \.self) { id in
                        Button {
                            Task { await model.update(effort: id) }
                        } label: {
                            if chat.effort == id {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                }
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
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
        .disabled(locked)
        .fixedSize(horizontal: true, vertical: true)
        .help("Agent, model and effort")
        .accessibilityLabel(summary)
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }

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
