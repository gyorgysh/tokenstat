// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatSavedCopyBanner: View {
    var info: SavedCopyInfo
    var checking: Bool
    var canCheck = true
    var onCheck: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ActionIcon.archive.label(L10n.text("apple.chatsavedcopybanner.saved_copy.9a53ca9a"))
                .labelStyle(.iconOnly)
                .font(Theme.font(13))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("apple.chatsavedcopybanner.saved_on_this_device.ade5400f"))
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(Theme.font(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            if checking {
                HStack(spacing: Theme.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.chatsavedcopybanner.checking_for_updates.497a1998"))
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.text("apple.chatsavedcopybanner.checking_for_updates.53b276ad"))
            } else if canCheck {
                Button(L10n.text("apple.chatsavedcopybanner.check_for_updates.f26f3275"), .refresh, action: onCheck)
                    .buttonStyle(NoticeActionButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        let when = RelativeClock.phrase(for: info.savedAt, style: .full)
        let accountNote = canCheck ? "" : L10n.text("apple.chatsavedcopybanner.verify_your_account_for_live_updates.ba22a709")
        if info.hasEarlier {
            return L10n.text("apple.chatsavedcopybanner.updated_0_earlier_messages_were_not_saved.fd965da3", "\(when)", "\(accountNote)")
        }
        return L10n.text("apple.chatsavedcopybanner.updated_0_1.ac599c45", "\(when)", "\(accountNote)")
    }
}

struct NoticeActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.compactActions, true)
            .font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.accent)
            #if os(macOS)
            .frame(minWidth: 44, minHeight: 28)
            #else
            .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
