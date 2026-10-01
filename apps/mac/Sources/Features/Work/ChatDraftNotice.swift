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
                text: L10n.text("apple.chatdraftnotice.not_saved_on_this_device_your_words_are_he.e5e95b26")
            ) {
                Button(L10n.text("apple.chatdraftnotice.try_again.d8b8392e"), .refresh, action: retrySave)
                    .buttonStyle(NoticeActionButtonStyle())
            }
        } else if let unconfirmed {
            row(
                symbol: unconfirmed.checking ? "clock.arrow.circlepath" : "questionmark.circle.fill",
                tint: unconfirmed.checking ? Theme.accent : Theme.warning,
                text: unconfirmed.checking
                    ? L10n.text("apple.chatdraftnotice.checking_whether_the_machine_took_this_mes.16f576a1")
                    : L10n.text("apple.chatdraftnotice.delivery_is_not_confirmed_check_again_befo.29ad199b")
            ) {
                if !unconfirmed.checking, let checkAgain {
                    Button(L10n.text("apple.chatdraftnotice.check_again.fb7099ad"), .refresh, action: checkAgain)
                        .buttonStyle(NoticeActionButtonStyle())
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
