// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Personas: a name, a brief, and a face.
///
/// This used to be a form asking for an agent, a model, an effort, a mode, an
/// autonomy and a two-character "mark": a launch preset wearing the word
/// persona. Every one of those already lives on the conversation, so the
/// preset was a duplicate that went stale, and it tied a persona to one agent.
///
/// What is here now is the thing people actually wanted: describe what it
/// should be good at, let an agent draft it, edit what comes back, save. The
/// character on the left is generated from the persona's own id, so it exists
/// the moment the persona does and follows it everywhere.
struct PersonaEditor: View {
    @Bindable var model: ChatModel
    var onClose: () -> Void

    private enum Step: Equatable {
        case describe
        case drafting
        case review
    }

    @State private var step: Step = .describe
    @State private var wish = ""
    @State private var draft = ChatPersona.blank()
    @State private var isNew = true
    @State private var drafter = ""
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    list
                    Rectangle().fill(Theme.border).frame(width: 1)
                    detail
                }
                VStack(spacing: 0) {
                    list.frame(maxHeight: 180)
                    Rectangle().fill(Theme.border).frame(height: 1)
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 460)
        #endif
        .background(Theme.background)
        .onAppear(perform: startNew)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Personas")
                .font(Theme.font(13, weight: .semibold))
            Spacer(minLength: 0)
            Button("Done", .done) { onClose() }
                .buttonStyle(SecondaryButtonStyle(small: true))
        }
        .padding(.horizontal, Theme.Space.m)
        .chromeBarMetrics()
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: - The saved ones

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button("New persona", .persona) { startNew() }
                .buttonStyle(AccentButtonStyle(small: true))
            if model.personas.isEmpty {
                Text("A persona is how an agent talks and what it is good at. It works with whichever agent the chat is on.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.s)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.personas) { persona in
                            row(persona)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(width: 240, alignment: .topLeading)
        .background(Theme.sidebar)
    }

    private func row(_ persona: ChatPersona) -> some View {
        let selected = !isNew && draft.id == persona.id
        return Button {
            draft = persona
            isNew = false
            step = .review
            failure = nil
        } label: {
            HStack(spacing: Theme.Space.s) {
                PersonaMark(seed: persona.seed, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(persona.name)
                        .font(Theme.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(persona.systemPrompt.isEmpty ? "No brief yet" : persona.systemPrompt)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(
                selected ? Theme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - The one being made

    @ViewBuilder
    private var detail: some View {
        switch step {
        case .describe: describeStep
        case .drafting: draftingStep
        case .review: reviewStep
        }
    }

    private var describeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("What should this persona be good at?")
                    .font(Theme.title3.weight(.semibold))
                Text("A sentence is enough. An agent turns it into a name and a brief, and you edit both before anything is saved.")
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ThemedEditor(text: $wish, font: Theme.callout, minHeight: 96)
                    .overlay(alignment: .topLeading) {
                        if wish.isEmpty {
                            Text("Someone who explains Rust errors patiently and never rewrites more than I asked for")
                                .font(Theme.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                    }

                // Starting points fill the field rather than being modes of
                // their own. A preset you can edit beats a preset you cannot.
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(Self.startingPoints, id: \.0) { point in
                        Button(point.0) { wish = point.1 }
                            .buttonStyle(.plain)
                            .font(Theme.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                }

                if let failure {
                    Text(failure)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ThemeRule()

                HStack(spacing: Theme.Space.s) {
                    AppMenuPicker(
                        title: "Written by",
                        options: draftBackends.map { (value: $0.id, label: $0.label) },
                        selection: $drafter
                    )
                    Spacer(minLength: 0)
                    Button("Write it myself", .edit) {
                        draft.name = ""
                        draft.systemPrompt = wish
                        step = .review
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    Button("Draft it", .persona) { generate() }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(wish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || drafter.isEmpty)
                }
                // Say whose tokens this spends. A wizard that quietly runs an
                // agent is a wizard that surprises somebody's bill.
                Text("One short turn on the agent you pick, in a temporary folder. It never touches your project.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    /// The wait is where the character earns its place: this is the first time
    /// most people see one move, and it is the persona's own face doing it.
    private var draftingStep: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            PersonaMark(seed: draft.seed == 0 ? personaSeed(for: wish) : draft.seed,
                        size: 96,
                        state: .thinking)
            Text("Writing your persona")
                .font(Theme.title3.weight(.medium))
            Text("One turn on \(model.backend(for: drafter)?.label ?? drafter). This takes a few seconds.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(spacing: Theme.Space.xs) {
                        PersonaMark(seed: faceSeed, size: 76)
                        Button("Reroll face", .refresh) { rerollFace() }
                            .buttonStyle(.plain)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(isNew ? "New persona" : "Edit persona")
                            .font(Theme.title3.weight(.semibold))
                        TextField("Name", text: $draft.name)
                            .themedFieldBox()
                        Text("A role rather than a person's name reads better in a chip: Reviewer, Rust explainer, Rubber duck.")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Brief")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                    ThemedEditor(text: $draft.systemPrompt, font: Theme.callout, minHeight: 140)
                    Text("Sent to whichever agent the chat is on, as a system instruction. It is never part of your message.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    } else {
                        Button("Back", .back) { step = .describe }
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

    // MARK: - Behaviour

    /// A saved persona shows its own face. One being written has none yet, so
    /// it borrows a face from what it is about, which keeps the wizard's
    /// character stable from the drafting screen through to review.
    private var faceSeed: UInt64 {
        draft.seed != 0 ? draft.seed : personaSeed(for: draft.name.isEmpty ? wish : draft.name)
    }

    private var draftBackends: [ChatBackend] {
        model.backends.filter { $0.id != "sh" }
    }

    private static let startingPoints: [(String, String)] = [
        ("Reviewer", "Reviews changes carefully, says what is wrong before what is fine, and never rewrites more than was asked."),
        ("Explainer", "Explains what code does in plain language, with a short example, and checks understanding before moving on."),
        ("Refactorer", "Finds duplication and unclear naming, proposes the smallest change that fixes it, and never mixes a refactor with a behaviour change."),
        ("Rubber duck", "Asks questions rather than answering them, and helps me find the problem myself."),
    ]

    private func generate() {
        failure = nil
        step = .drafting
        let brief = wish
        let backend = drafter
        Task {
            if let result = await model.draftPersona(brief: brief, backend: backend) {
                draft.name = result.name
                draft.systemPrompt = result.systemPrompt
                step = .review
            } else {
                // Their own words stay in the field. A failed draft must not
                // cost somebody the sentence they wrote.
                failure = model.error ?? "That agent did not return a persona. Try another, or write it yourself."
                model.error = nil
                step = .describe
            }
        }
    }

    /// Ask for a different character. A saved persona keeps its face through
    /// renames and edits, so this is the only way to change it, and it is
    /// deliberately explicit.
    private func rerollFace() {
        draft.seed = personaSeed(for: "\(draft.id)-\(UUID().uuidString)")
    }

    private func startNew() {
        draft = ChatPersona.blank()
        wish = ""
        failure = nil
        isNew = true
        step = .describe
        if drafter.isEmpty || !draftBackends.contains(where: { $0.id == drafter }) {
            drafter = draftBackends.first?.id ?? ""
        }
    }
}
