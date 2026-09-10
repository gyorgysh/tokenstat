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
    @State private var saving = false
    @State private var editorOwner: ChatModel.PersonaContext?
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
            if saving {
                Text("Saving changes…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            if let failure {
                Text(failure)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            improveAgentRow
            ThemeRule()
            workspaceDefaultRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(saving || editableContext == nil)
        .onAppear(perform: openDefault)
        .onDisappear { draftGeneration &+= 1 }
        .onChange(of: model.personaContext) { _, current in
            if let current {
                if let editorOwner,
                   (editorOwner.scope != current.scope
                    || editorOwner.workspaceID != current.workspaceID
                    || editorOwner.peer != current.peer) {
                    close()
                } else if editorOwner == nil {
                    editorOwner = current
                    openDefault()
                }
            } else if !model.isLoading {
                close()
            }
        }
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
                .disabled(improving || saving)
        }
    }

    /// Which persona new chats in this folder inherit, including none.
    ///
    /// A row rather than a "Make default" button on whichever persona happens
    /// to be open. A button can only ever say yes to the persona in front of
    /// it, so there was no way to say "none of them", and choosing no persona
    /// in a conversation lasted exactly that conversation.
    private var workspaceDefaultRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New chats here")
                    .font(Theme.callout.weight(.medium))
                Text("Existing conversations keep whatever they already have.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            AppMenuPicker(
                title: "",
                options: defaultOptions,
                selection: defaultBinding
            )
            .frame(maxWidth: 200)
            .disabled(improving || saving)
        }
    }

    private var defaultOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [(value: "", label: "No persona")]
        for persona in model.personas {
            options.append((value: persona.id, label: persona.name))
        }
        return options
    }

    private var defaultBinding: Binding<String> {
        Binding(
            get: { model.defaultPersonaID ?? "" },
            set: { id in
                let persona = model.personas.first { $0.id == id }
                mutate({ owner in
                    try await model.setDefaultPersona(persona, owner: owner)
                }, completion: { _ in })
            }
        )
    }

    /// Whether this persona belongs to this folder or to all of them.
    ///
    /// A persona with no folder of its own is visible in every one, which the
    /// host has always supported and nothing ever surfaced. Starters made for
    /// a folder belong to it; one written by hand is usually a way of working
    /// rather than a fact about a project, so a new one starts shared.
    private var sharedBinding: Binding<Bool> {
        Binding(
            get: { draft.workspaceID == nil },
            set: { shared in draft.workspaceID = shared ? nil : model.workspaceID }
        )
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            // Pokeable here and nowhere else. This is the one screen where the
            // character is the subject rather than a label on a row, so a
            // click that shoves it is a click on the thing being edited.
            PersonaMark(
                seed: faceSeed,
                size: 36,
                state: improving ? .thinking : .idle,
                pokeable: true
            )
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("Name", text: $draft.name)
                    .themedFieldBox()
                    .disabled(improving || saving)
                HStack(spacing: Theme.Space.s) {
                    Button("Reroll", .refresh) { rerollFace() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(improving || saving)
                    if isDefault {
                        Text("Default")
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Toggle("Every folder", isOn: sharedBinding)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.controlGlyph)
                        .disabled(improving || saving)
                        .help("Off, this persona belongs to this folder. On, every folder can pick it.")
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
            .disabled(improving || saving)
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
                        .disabled(improving || saving)
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
                .disabled(improving || saving)
        }
        Spacer()
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
                        .disabled(improving || saving)
                }
                Spacer(minLength: 0)
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

    private var editableContext: ChatModel.PersonaContext? {
        guard let current = model.personaContext, let editorOwner,
              current.scope == editorOwner.scope,
              current.workspaceID == editorOwner.workspaceID,
              current.peer == editorOwner.peer else { return nil }
        return current
    }

    private var isDefault: Bool {
        !isNew && !draft.id.isEmpty && draft.id == model.defaultPersonaID
    }

    private var canDelete: Bool {
        !isNew && !draft.id.isEmpty && !isDefault
    }

    private var canSave: Bool {
        !improving && !saving && editableContext != nil
            && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canImprove: Bool {
        !improving && !saving && editableContext != nil
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
        if editorOwner == nil { editorOwner = model.personaContext }
        if drafter.isEmpty || !draftBackends.contains(where: { $0.id == drafter }) {
            drafter = draftBackends.first?.id ?? ""
        }
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard !improving, !saving else { return }
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
        // A generated draft belongs to the editor selection that requested it.
        // The picker remains available while the agent is working.
        draftGeneration &+= 1
        improving = false
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
        mutate({ owner in
            try await model.savePersona(persona, owner: owner)
        }, completion: { saved in select(saved) })
    }

    private func deleteCurrent() {
        guard canDelete else { return }
        let persona = draft
        mutate({ owner in
            try await model.removePersona(persona, owner: owner)
        }, completion: { _ in reconcileSelection() })
    }

    /// Capture ownership before scheduling, serialize writes, and keep errors
    /// local to this sheet rather than consuming another chat operation's error.
    private func mutate<Value>(
        _ operation: @escaping (ChatModel.PersonaContext) async throws -> Value,
        completion: @escaping (Value) -> Void
    ) {
        guard !saving, !improving, let owner = editableContext else { return }
        let generation = draftGeneration
        failure = nil
        saving = true
        Task {
            defer {
                if generation == draftGeneration { saving = false }
            }
            guard generation == draftGeneration, model.personaContext == owner else { return }
            do {
                let value = try await operation(owner)
                guard generation == draftGeneration, model.personaContext == owner else { return }
                saving = false
                completion(value)
            } catch {
                guard generation == draftGeneration, model.personaContext == owner,
                      !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func improve() {
        let brief = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canImprove, !brief.isEmpty, let owner = editableContext else { return }
        failure = nil
        let snapshotName = draft.name
        let backend = drafter
        let suppliedName = snapshotName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftGeneration &+= 1
        let generation = draftGeneration
        improving = true
        Task {
            defer {
                if generation == draftGeneration { improving = false }
            }
            guard generation == draftGeneration, model.personaContext == owner else { return }
            do {
                let result = try await model.draftPersona(
                    brief: brief, backend: backend,
                    name: suppliedName.isEmpty ? nil : suppliedName, owner: owner
                )
                guard generation == draftGeneration, model.personaContext == owner else { return }
                improving = false
                if suppliedName.isEmpty { draft.name = result.name }
                draft.systemPrompt = result.systemPrompt
            } catch {
                guard generation == draftGeneration, model.personaContext == owner else { return }
                improving = false
                if !(error is CancellationError) { failure = error.localizedDescription }
            }
        }
    }

    private func close() {
        draftGeneration &+= 1
        onClose()
    }
}
