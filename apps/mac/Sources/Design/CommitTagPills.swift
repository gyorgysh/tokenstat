// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The tags pointing at a commit, as small pills under its subject.
///
/// Usually zero or one: a release tag marks the commit it went out on, which
/// is what makes a history list answer "where was 0.9.2". Empty draws nothing,
/// so untagged rows read exactly as before.
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
                    .accessibilityLabel("Tagged \(tag)")
                }
            }
        }
    }
}
