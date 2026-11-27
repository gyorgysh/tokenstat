// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct CommitTagPills: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: Theme.Space.xs) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Image(systemName: "tag")
                            .font(Theme.font(8, weight: .semibold, relativeTo: .caption2))
                        Text(tag)
                            .font(Theme.monoText(10, weight: .medium, relativeTo: .caption2))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
                    .accessibilityLabel(L10n.text("apple.committagpills.tagged_0.17a3d03e", "\(tag)"))
                }
            }
        }
    }
}
