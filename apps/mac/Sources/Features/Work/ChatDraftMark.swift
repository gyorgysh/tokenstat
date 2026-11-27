// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatDraftMark: View {
    let reference: WorkReference?
    var size: CGFloat = 9
    var scalesWithText = false

    var body: some View {
        if let reference, ChatDraftStore.shared.hasDraft(for: reference) {
            Image(systemName: "pencil")
                .font(scalesWithText
                    ? Theme.font(size, weight: .semibold, relativeTo: .caption2)
                    : Theme.fit(size, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityLabel(L10n.text("apple.chatdraftmark.unsent_draft.13256c6b"))
        }
    }
}
