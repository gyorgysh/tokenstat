// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The mark on a conversation that is holding words nobody has sent.
///
/// A view of its own, and that is the whole point. It reads the draft store,
/// so a draft appearing or going invalidates one mark rather than the screen
/// listing the conversations. A sidebar that observed the store had to be
/// laid out again every time somebody paused typing, and the transcript in
/// the same window with it.
struct ChatDraftMark: View {
    /// The conversation, or nil when its owner is not known yet. Nil draws
    /// nothing rather than guessing.
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
                .accessibilityLabel("Unsent draft")
        }
    }
}
