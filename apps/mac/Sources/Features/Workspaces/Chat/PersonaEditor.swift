// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Personas: a name, a brief, and a face, on one form.
///
/// There is no rail and no describe/draft/review wizard. The sheet opens on
/// the workspace default. New persona, Improve with agent, and Save as written
/// all edit the same two fields. Generated text is a draft until Save.
struct PersonaEditor: View {
    @Bindable var model: ChatModel
    var onClose: () -> Void

    @State private var draft = ChatPersona.blank()
    @State private var isNew = true
    @State private var drafter = ""
    @State private var improving = false
    @State private var failure: String?
    @State private var draftGeneration: UInt64 = 0

    var body: some View {
        #if os(macOS)
        ThemedSheet(
            title: "Personas",
            subtitle: "Choose how new chats in this workspace should behave.",
            icon: .persona,
            onClose: close
        ) {
            form
        } actions: {
            macFooter
        }
        .modalFrame(width: 620, height: 700)
        #else
        NavigationStack {
            ScrollView {
                form
                    .padding(Theme.Modal.bodyPadding)
            }
            .background(Theme.background)
            .navigationTitle("Personas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                phoneFooter
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.background)
        #endif
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            pickerRow
            identityRow
            briefBlock
            if improving {
                improvingRow
            }
            if let failure {
                Text(failure)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            improveAgentRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: openDefault)
        .onChange(of: model.personas.map(\.id)) { _, _ in
            reconcileSelection()
        }
    }

    private var pickerRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            AppMenuPicker(
                title: "",
                options: personaOptions,
                selection: selectedID
            )
            Button("New persona", .create) { startNew() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(improving)
        }
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            PersonaMark(
                seed: faceSeed,
                size: 36,
                state: improving ? .thinking : .idle
            )
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Name", text: $draft.name)
                    .themedFieldBox()
                    .disabled(improving)
                HStack(spacing: Theme.Space.s) {
                    Button("Reroll", .refresh) { rerollFace() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(improving)
                    if isDefault {
                        Text("Default")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                }
            }
        }
    }

    private var briefBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("What should it be good at, and how should it work?")
                .font(Theme.callout.weight(.semibold))
                .foregroundStyle(.primary)
            ThemedEditor(
                text: $draft.systemPrompt,
                font: Theme.callout,
                minHeight: 88,
                maxHeight: 96
            )
            .disabled(improving)
            .overlay(alignment: .topLeading) {
                if draft.systemPrompt.isEmpty {
                    Text("Someone who explains Rust errors patiently and never rewrites more than I asked for")
                        .font(Theme.callout)
                        .foregroundStyle(Theme.controlGlyph.opacity(0.7))
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
            Text("Sent to whichever agent the chat is on. It is never part of your message.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(Self.startingPoints, id: \.0) { point in
                    Button(point.0) { draft.systemPrompt = point.1 }
                        .buttonStyle(.plain)
                        .font(Theme.caption.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                        .disabled(improving)
                }
            }
        }
    }

    private var improvingRow: some View {
        HStack(spacing: Theme.Space.s) {
            PersonaMark(seed: faceSeed, size: 30, state: .thinking)
            Text("Improving...")
                .font(Theme.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text("One turn on \(model.backend(for: drafter)?.label ?? drafter).")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
        }
        .accessibilityElement(children: .combine)
    }

    private var improveAgentRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            AppMenuPicker(
                title: "Improve with",
                options: draftBackends.map { (value: $0.id, label: $0.label) },
                selection: $drafter
            )
            .disabled(improving || draftBackends.isEmpty)
            Text("One short turn on that agent, in a temporary folder. It never touches your project.")
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footers

    #if os(macOS)
    @ViewBuilder
    private var macFooter: some View {
        if canDelete {
            Button("Delete", .delete, role: .destructive) { deleteCurrent() }
                .buttonStyle(DestructiveButtonStyle(small: true))
                .disabled(improving)
        }
        Spacer()
        if canMakeDefault {
            Button("Make default", .claim) { makeDefault() }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(improving)
        }
        Button("Improve with agent", .persona) { improve() }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(!canImprove)
        Button("Save as written", .save) { save() }
            .buttonStyle(AccentButtonStyle(small: true))
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
    }
    #else
    private var phoneFooter: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                if canDelete {
                    Button("Delete", .delete, role: .destructive) { deleteCurrent() }
                        .buttonStyle(DestructiveButtonStyle())
                        .disabled(improving)
                }
                Spacer(minLength: 0)
                if canMakeDefault {
                    Button("Make default", .claim) { makeDefault() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(improving)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Button("Improve with agent", .persona) { improve() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canImprove)
                Spacer(minLength: 0)
                Button("Save as written", .save) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canSave)
            }
        }
        .padding(Theme.Modal.bodyPadding)
        .frame(maxWidth: .infinity)
        .background {
            Theme.sidebar.ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { ThemeRule() }
    }
    #endif

    // MARK: - State

    private var isDefault: Bool {
        !isNew && !draft.id.isEmpty && draft.id == model.defaultPersonaID
    }

    private var canDelete: Bool {
        !isNew && !draft.id.isEmpty && !isDefault
    }

    private var canMakeDefault: Bool {
        !isNew && !draft.id.isEmpty && !isDefault
    }

    private var canSave: Bool {
        !improving && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canImprove: Bool {
        !improving
            && !drafter.isEmpty
            && !draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var faceSeed: UInt64 {
        draft.seed != 0 ? draft.seed : personaSeed(for: draft.name.isEmpty ? draft.systemPrompt : draft.name)
    }

    private var draftBackends: [ChatBackend] {
        model.backends.filter { $0.id != "sh" }
    }

    private var personaOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = []
        if isNew {
            options.append((value: "", label: "New persona"))
        }
        for persona in model.personas {
            let suffix = persona.id == model.defaultPersonaID ? " · Default" : ""
            options.append((value: persona.id, label: persona.name + suffix))
        }
        return options
    }

    private var selectedID: Binding<String> {
        Binding(
            get: { isNew ? "" : draft.id },
            set: { id in
                if id.isEmpty {
                    startNew()
                    return
                }
                if let persona = model.personas.first(where: { $0.id == id }) {
                    select(persona)
                }
            }
        )
    }

    private static let startingPoints: [(String, String)] = [
        ("Reviewer", "Reviews changes carefully, says what is wrong before what is fine, and never rewrites more than was asked."),
        ("Explainer", "Explains what code does in plain language, with a short example, and checks understanding before moving on."),
        ("Refactorer", "Finds duplication and unclear naming, proposes the smallest change that fixes it, and never mixes a refactor with a behaviour change."),
        ("Rubber duck", "Asks questions rather than answering them, and helps me find the problem myself."),
    ]

    // MARK: - Behaviour

    private func openDefault() {
        if drafter.isEmpty || !draftBackends.contains(where: { $0.id == drafter }) {
            drafter = draftBackends.first?.id ?? ""
        }
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard !improving else { return }
        if !isNew, !draft.id.isEmpty, model.personas.contains(where: { $0.id == draft.id }) {
            return
        }
        if let id = model.defaultPersonaID,
           let persona = model.personas.first(where: { $0.id == id }) {
            select(persona)
        } else if let persona = model.personas.first {
            select(persona)
        } else if !isNew {
            startNew()
        }
    }

    private func select(_ persona: ChatPersona) {
        draft = persona
        isNew = false
        failure = nil
    }

    private func startNew() {
        draftGeneration &+= 1
        draft = ChatPersona.blank()
        isNew = true
        improving = false
        failure = nil
        if drafter.isEmpty || !draftBackends.contains(where: { $0.id == drafter }) {
            drafter = draftBackends.first?.id ?? ""
        }
    }

    private func rerollFace() {
        draft.seed = personaSeed(for: "\(draft.id)-\(UUID().uuidString)")
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var persona = draft
        persona.name = name
        failure = nil
        Task {
            if let saved = await model.savePersona(persona) {
                select(saved)
            } else {
                consumeError()
            }
        }
    }

    private func makeDefault() {
        guard !draft.id.isEmpty else { return }
        let persona = draft
        failure = nil
        Task {
            await model.setDefaultPersona(persona)
            consumeError()
        }
    }

    private func deleteCurrent() {
        let persona = draft
        failure = nil
        Task {
            await model.removePersona(persona)
            if model.error == nil {
                reconcileSelection()
            } else {
                consumeError()
            }
        }
    }

    private func consumeError() {
        if let error = model.error {
            failure = error
            model.error = nil
        }
    }

    private func improve() {
        let brief = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, !drafter.isEmpty else { return }
        failure = nil
        let snapshotName = draft.name
        let snapshotBrief = draft.systemPrompt
        let backend = drafter
        let suppliedName = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftGeneration &+= 1
        let generation = draftGeneration
        improving = true
        Task {
            let result = await model.draftPersona(
                brief: brief,
                backend: backend,
                name: suppliedName.isEmpty ? nil : suppliedName
            )
            guard generation == draftGeneration else { return }
            improving = false
            if let result {
                if suppliedName.isEmpty {
                    draft.name = result.name
                }
                draft.systemPrompt = result.systemPrompt
            } else {
                draft.name = snapshotName
                draft.systemPrompt = snapshotBrief
                failure = model.error ?? "That agent did not return a persona. Try another, or write it yourself."
                model.error = nil
            }
        }
    }

    private func close() {
        draftGeneration &+= 1
        onClose()
    }
}
