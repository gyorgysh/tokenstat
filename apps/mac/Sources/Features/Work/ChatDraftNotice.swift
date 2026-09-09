// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The line above the composer, when there is something true to say about the
/// words in it that the words themselves cannot say.
///
/// Two situations, both about where a message is rather than what it says. A
/// composer that claimed "Saved" after a failed write, or went quiet after a
/// send nobody answered, would be worse than one that says nothing at all.
struct ChatDraftNotice: View {
    /// The save failed and the composer is the only copy.
    var retrySave: (() -> Void)?
    /// The machine had the message and did not answer for it.
    var unconfirmed: ChatModel.UnconfirmedSend?
    var checkAgain: (() -> Void)?

    var body: some View {
        if let retrySave {
            row(
                symbol: "exclamationmark.triangle.fill",
                tint: Theme.warning,
                text: "Not saved on this device. Your words are here until you close the app."
            ) {
                Button("Try again", .refresh, action: retrySave)
                    .modifier(NoticeAction())
            }
        } else if let unconfirmed {
            row(
                symbol: unconfirmed.checking ? "clock.arrow.circlepath" : "questionmark.circle.fill",
                tint: unconfirmed.checking ? Theme.accent : Theme.warning,
                text: unconfirmed.checking
                    ? "Checking whether the machine took this message…"
                    : "The machine did not answer. Sending again is safe: it will not run twice."
            ) {
                if !unconfirmed.checking, let checkAgain {
                    Button("Check again", .refresh, action: checkAgain)
                        .modifier(NoticeAction())
                }
            }
        }
    }

    private func row(
        symbol: String, tint: Color, text: String, @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.font(11))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            action()
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The quiet control in a notice: a word and a glyph, no filled shape. The
/// notice is already tinted, and a button on top of it would compete with the
/// Send button a row below.
private struct NoticeAction: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .environment(\.compactActions, true)
            .font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 28)
    }
}
