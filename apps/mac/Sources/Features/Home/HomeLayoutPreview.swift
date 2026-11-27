// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct HomeLayoutPreview: View {
    let sections: [HomeSection]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(Theme.accent.opacity(0.35))
                .frame(width: 84, height: 8)
                .padding(.bottom, 3)
                .accessibilityHidden(true)
            if sections.isEmpty {
                Text(L10n.text("apple.homelayoutpreview.your_home_is_clear.9ae93db2"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ForEach(sections) { section in
                    HStack(spacing: 6) {
                        Image(systemName: section.symbol)
                            .font(Theme.fixed(8, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 12)
                        Text(section.label)
                            .font(Theme.fixed(9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: section == .activity ? 30 : 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Theme.accentSoft,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                }
            }
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: sections)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sections.isEmpty
            ? L10n.text("apple.homelayoutpreview.preview_home_is_clear.be85742c")
            : L10n.text("apple.homelayoutpreview.preview_0.7a199109", "\(sections.map(\.label).joined(separator: ", "))"))
    }
}
