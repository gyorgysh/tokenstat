// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Host-stored conversation presets. Editing one never rewrites a chat that
/// is already running: fields copy onto a conversation at create or apply.
struct PersonaEditor: View {
    @Bindable var model: ChatModel
    var onClose: () -> Void
    @State private var draft = ChatPersona.blank()
    @State private var isNew = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Text("Personas")
                    .font(Theme.font(13, weight: .semibold))
                Spacer(minLength: 0)
                Button("Done", .done) { onClose() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: DetailChromeBarHeight)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    list
                    Rectangle().fill(Theme.border).frame(width: 1)
                    form
                }
                VStack(spacing: 0) {
                    list.frame(maxHeight: 180)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    form
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
        .background(Theme.background)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button("New persona", .persona) { startNew() }
                .buttonStyle(AccentButtonStyle(small: true))
            if model.personas.isEmpty {
                Text("A persona is a starting point: agent, mode, and a short brief. It is not an agent of its own.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.s)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.personas) { persona in
                            Button {
                                draft = persona
                                isNew = false
                            } label: {
                                HStack(spacing: Theme.Space.s) {
                                    ActionSeat(icon: .persona, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(persona.name)
                                            .font(Theme.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(persona.backend)
                                            .font(Theme.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.vertical, 6)
                                .background(
                                    (!isNew && draft.id == persona.id)
                                        ? Theme.accentSoft
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(width: 220, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(isNew ? "New persona" : "Edit persona")
                    .font(Theme.title3.weight(.semibold))
                HStack(spacing: Theme.Space.s) {
                    TextField("Mark", text: $draft.mark)
                        .themedFieldBox()
                        .frame(width: 72)
                    TextField("Name", text: $draft.name)
                        .themedFieldBox()
                }
                AppMenuPicker(
                    title: "Agent",
                    options: model.backends
                        .filter { $0.id != "sh" }
                        .map { (value: $0.id, label: $0.label) },
                    selection: $draft.backend
                )
                if let backend = model.backend(for: draft.backend) {
                    if !backend.models.isEmpty {
                        FavoriteModelPicker(
                            backendID: backend.id,
                            models: backend.models,
                            extra: draft.model ?? "",
                            selection: modelBinding
                        )
                    }
                    if !backend.efforts.isEmpty {
                        AppMenuPicker(
                            title: "Effort",
                            options: [(value: "", label: "Default")]
                                + backend.efforts.map { (value: $0, label: $0) },
                            selection: effortBinding
                        )
                    }
                }
                SegmentedCapsulePicker(
                    options: [
                        (value: "plan", label: "Plan", symbol: ActionIcon.plan.symbol),
                        (value: "execute", label: "Execute", symbol: "hammer"),
                    ],
                    selection: $draft.defaultMode
                )
                Toggle("Work without asking", isOn: bypassBinding)
                    .toggleStyle(.brandCheckbox)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Brief")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                    ThemedEditor(text: $draft.systemPrompt, font: Theme.callout, minHeight: 120)
                }
                HStack {
                    if !isNew {
                        Button("Delete", .delete, role: .destructive) {
                            let persona = draft
                            Task {
                                await model.removePersona(persona)
                                startNew()
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                    Button("Save persona", .save) {
                        Task {
                            if let saved = await model.savePersona(draft) {
                                draft = saved
                                isNew = false
                            }
                        }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    private func startNew() {
        draft = ChatPersona.blank(backend: model.backends.first(where: { $0.id != "sh" })?.id ?? "claude")
        isNew = true
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { draft.model ?? "" },
            set: { draft.model = $0.isEmpty ? nil : $0 }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { draft.effort ?? "" },
            set: { draft.effort = $0.isEmpty ? nil : $0 }
        )
    }

    private var bypassBinding: Binding<Bool> {
        Binding(
            get: { draft.defaultAutonomy == "bypass" },
            set: { draft.defaultAutonomy = $0 ? "bypass" : "standard" }
        )
    }
}
