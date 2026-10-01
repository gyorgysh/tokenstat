// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// What a conversation tells its agent before it hears the person.
///
/// This exists because of a bug that was really a design failure. Every turn
/// used to carry three machine-written paragraphs glued to the person's
/// sentence, so an opening "Hey" came back describing a temporary folder
/// nobody had mentioned, and there was nowhere in the app to see that text or
/// change it. Both halves are now here: the brief belongs to the person and is
/// editable, and the one rule tokenstat adds is readable rather than described.
///
/// Shared by the Mac inspector and the client's setup sheet, because the
/// promise it makes ("nothing is sent that you cannot read") has to hold on
/// whichever screen somebody opens.
struct ChatInstructionsCard: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation

    @State private var draft = ""
    @State private var showingAdded = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.chatinstructionscard.instructions.934652dc"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            ThemedEditor(text: $draft, font: Theme.callout, minHeight: 76, maxHeight: 220)
                .disabled(model.savedCopy != nil)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(L10n.text("apple.chatinstructionscard.how_should_this_agent_behave.6cee0aaf"))
                            .font(Theme.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(channelNote)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if changed {
                    Button(L10n.text("common.save"), .save) { commit() }
                        .disabled(model.savedCopy != nil)
                        .buttonStyle(AccentButtonStyle(small: true))
                }
            }

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { showingAdded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font(10, weight: .semibold))
                        .rotationEffect(.degrees(showingAdded ? 90 : 0))
                    Text(L10n.text("apple.chatinstructionscard.what_tokenstat_adds.358d9a68"))
                }
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingAdded ? L10n.text("apple.chatinstructionscard.hide_what_tokenstat_adds.fa10e5bb") : L10n.text("apple.chatinstructionscard.show_what_tokenstat_adds.8288a2b7"))

            if showingAdded {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(addedInstructions)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.s)
                        .background(
                            Theme.background,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    if let instructions = model.instructions, !instructions.added.isEmpty {
                        Text(L10n.text("apple.chatinstructionscard.every_conversation_gets_this_so_an_agent_c.a8858c75"))
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .onAppear { draft = chat.systemPrompt }
        .onChange(of: chat.id) { _, _ in draft = chat.systemPrompt }
        .onChange(of: chat.systemPrompt) { _, next in
            // Do not yank the field out from under somebody mid-sentence. A
            // persona applied from another screen lands as soon as they leave.
            if !focused, draft != next { draft = next }
        }
    }

    private var changed: Bool { draft != chat.systemPrompt }

    /// The rule to show, or the state of looking for it. A finished read that
    /// came back empty is not still loading: say the text is not available
    /// rather than leave a spinner that never resolves.
    private var addedInstructions: String {
        if let added = model.instructions?.added, !added.isEmpty { return added }
        return model.instructionsLoaded ? L10n.text("apple.chatinstructionscard.not_available_on_this_computer.ffcbd9b9") : L10n.text("apple.chatinstructionscard.loading.ba3bbbe1")
    }

    /// Name the channel for the agent actually selected.
    ///
    /// Claiming every backend takes a system prompt would be the same quiet
    /// overclaim the gate tiers already refuse to make. Two of the seven have a
    /// flag for this. The rest are told once, ahead of a message, and the
    /// sentence says so.
    private var channelNote: String {
        let agent = model.backend(for: chat.backend)?.label ?? L10n.text("apple.chatinstructionscard.this_agent.15af7e1b")
        guard let instructions = model.instructions else {
            return L10n.text("apple.chatinstructionscard.sent_as_an_instruction_never_as_part_of_yo.48abdbf3")
        }
        return instructions.travelsAsSystemPrompt
            ? L10n.text("apple.chatinstructionscard.0_takes_this_as_a_system_prompt_so_it_is_n.dc332cd6", "\(agent)")
            : L10n.text("apple.chatinstructionscard.0_has_no_system_prompt_flag_so_this_is_sen.01aa66c2", "\(agent)")
    }

    private func commit() {
        let brief = draft
        let owner = model.currentReference
        Task {
            guard let owner, model.currentReference == owner,
                  model.selected?.id == chat.id, model.savedCopy == nil else { return }
            await model.update(systemPrompt: brief)
        }
    }
}
