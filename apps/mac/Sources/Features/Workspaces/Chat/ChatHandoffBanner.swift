// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct ChatHandoffBanner: View {
    let agent: String
    let brief: String
    var titleFont: Font = Theme.font(14, weight: .semibold)
    var captionFont: Font = Theme.caption
    var briefFont: Font = Theme.monoText(11)
    @State private var expanded = false

    private var gradient: LinearGradient {
        LinearGradient(colors: [Theme.accent, Theme.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(gradient, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("apple.chateventrow.handed_to_0.902d7234", "\(agent)"))
                        .font(titleFont)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !brief.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(expanded ? L10n.text("apple.chateventrow.hide_summary.4cf94a81") : L10n.text("apple.chateventrow.what_it_was_told.4b2128b2"))
                                Image(systemName: "chevron.right")
                                    .font(Theme.font(9, weight: .semibold))
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                            .font(captionFont.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .contentShape(.rect)
                        }
                        .buttonStyle(QuietLinkStyle())
                    }
                }
                Spacer(minLength: 0)
            }
            if expanded {
                Text(brief)
                    .font(briefFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.s)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.secondary.opacity(0.10)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(gradient.opacity(0.7), lineWidth: 1.5)
        }
        .padding(.vertical, Theme.Space.s)
        .accessibilityElement(children: .contain)
    }
}
