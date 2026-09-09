// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// Said only when a draft failed to reach the disk.
///
/// The words are still in the composer, so nothing has been lost yet, and the
/// honest thing to say is that they are not kept anywhere else. A composer
/// that claimed "Saved" after a failed write would be worse than one that
/// says nothing at all.
struct ChatDraftNotice: View {
    var retry: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.font(11))
                .foregroundStyle(Theme.warning)
            Text("Not saved on this device. Your words are here until you close the app.")
                .font(Theme.font(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button("Try again", .refresh, action: retry)
                .buttonStyle(.plain)
                .environment(\.compactActions, true)
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 44, minHeight: 28)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
