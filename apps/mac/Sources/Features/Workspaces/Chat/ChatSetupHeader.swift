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
            HarnessMark(id: chat.backend, size: 22)
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
                HarnessMark(id: chat.backend, size: 28)
                    .padding(.bottom, 1)
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
