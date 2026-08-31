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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Instructions")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)

            ThemedEditor(text: $draft, font: Theme.callout, minHeight: 76, maxHeight: 220)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("How should this agent behave?")
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
                    Button("Save", .save) { commit() }
                        .buttonStyle(AccentButtonStyle(small: true))
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.14)) { showingAdded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font(10, weight: .semibold))
                        .rotationEffect(.degrees(showingAdded ? 90 : 0))
                    Text("What tokenstat adds")
                }
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingAdded ? "Hide what tokenstat adds" : "Show what tokenstat adds")

            if showingAdded {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(model.instructions?.added ?? "Loading…")
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
                    Text("Every conversation gets this so an agent can hand a file back to you. It is sent once, and it tells the agent not to talk about it.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// Name the channel for the agent actually selected.
    ///
    /// Claiming every backend takes a system prompt would be the same quiet
    /// overclaim the gate tiers already refuse to make. Two of the seven have a
    /// flag for this. The rest are told once, ahead of a message, and the
    /// sentence says so.
    private var channelNote: String {
        let agent = model.backend(for: chat.backend)?.label ?? "This agent"
        guard let instructions = model.instructions else {
            return "Sent as an instruction, never as part of your message."
        }
        return instructions.travelsAsSystemPrompt
            ? "\(agent) takes this as a system prompt, so it is never part of your message."
            : "\(agent) has no system-prompt flag, so this is sent once, ahead of your message."
    }

    private func commit() {
        let brief = draft
        Task { await model.update(systemPrompt: brief) }
    }
}
