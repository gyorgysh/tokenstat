// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A question the agent asked, drawn where it asked it.
///
/// Shared by the Mac and the phone. The choices answer in one tap; a
/// multiple-choice question collects its picks first. The field below takes
/// an answer of the person's own. Once answered, the card says what was sent
/// and how it travels, and offers nothing more: the host keeps the record, so
/// a second device sees the same answer rather than a second chance at it.
struct ChatQuestionCard: View {
    let question: ChatQuestion
    /// Whether the person can answer from here: false for a saved copy.
    var canAnswer = true
    var isSending = false
    let answer: (String) -> Void
    @State private var written = ""
    @State private var picked: [String] = []

    #if os(macOS)
    private static let questionFont = Theme.callout.weight(.semibold)
    private static let noteFont = Theme.caption
    #else
    private static let questionFont = ClientType.label.weight(.semibold)
    private static let noteFont = ClientType.caption
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(L10n.text("apple.chatquestion.title"), systemImage: "questionmark.bubble")
                .font(Theme.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
            Text(question.question)
                .font(Self.questionFont)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let answered = question.answer {
                Text(L10n.text("apple.chatquestion.answered", answered))
                    .font(Self.noteFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let delivery = deliveryWords {
                    Text(delivery).font(Self.noteFont).foregroundStyle(.secondary)
                }
            } else {
                Text(waitingWords)
                    .font(Self.noteFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canAnswer { controls }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(question.isAnswered ? 0.2 : 0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controls: some View {
        if !question.options.isEmpty {
            FlowLayout(spacing: Theme.Space.s, rowSpacing: Theme.Space.s) {
                ForEach(question.options, id: \.self) { option in
                    Button { choose(option) } label: {
                        Text(option)
                            .font(Self.noteFont.weight(.medium))
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 5)
                            .background(chipFill(option), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                            .foregroundStyle(picked.contains(option) ? Color.white : Theme.accent)
                            #if !os(macOS)
                            .frame(minHeight: 44)
                            #endif
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked.contains(option) ? .isSelected : [])
                }
            }
            if question.multiple {
                Button(L10n.text("apple.chatquestion.send_choices"), .send) {
                    // Quoted, so a comma inside a choice cannot read as two.
                    answer(picked.map { "“\($0)”" }.joined(separator: ", "))
                }
                .buttonStyle(AccentButtonStyle(small: true))
                .disabled(picked.isEmpty || isSending)
            }
        }
        HStack(spacing: Theme.Space.s) {
            TextField(L10n.text("apple.chatquestion.own_answer"), text: $written)
                .textFieldStyle(.themedSmall)
                .onSubmit(sendWritten)
            Button(L10n.text("apple.chatquestion.send"), .send, action: sendWritten)
                .buttonStyle(SecondaryButtonStyle(small: true))
                .disabled(written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .disabled(isSending)
    }

    private func choose(_ option: String) {
        guard !isSending else { return }
        if question.multiple {
            if let at = picked.firstIndex(of: option) { picked.remove(at: at) } else { picked.append(option) }
        } else {
            answer(option)
        }
    }

    private func sendWritten() {
        let text = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        answer(text)
    }

    private func chipFill(_ option: String) -> Color {
        picked.contains(option) ? Theme.accent : Theme.panel
    }

    /// What the agent is doing about the question right now.
    private var waitingWords: String {
        if !question.blocking, let fallback = question.defaultAnswer {
            return L10n.text("apple.chatquestion.going_with", fallback)
        }
        return L10n.text("apple.chatquestion.waiting")
    }

    private var deliveryWords: String? {
        switch question.delivery {
        case "note": L10n.text("apple.chatquestion.delivery_note")
        case "queued": L10n.text("apple.chatquestion.delivery_queued")
        case "sent": L10n.text("apple.chatquestion.delivery_sent")
        default: nil
        }
    }
}
