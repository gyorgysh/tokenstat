// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The line between a saved copy and the composer, saying what is true.
///
/// Three facts and one action: the machine could not be reached, these rows
/// were kept on this device at this time, and earlier messages may not be in
/// the copy. Checking asks the machine again; while it is being asked the
/// banner says so instead of going quiet. The transcript below stays exactly
/// as readable as a live one: reading, copying and drafting carry on, and
/// only sending, approvals and downloads wait for the machine.
struct ChatSavedCopyBanner: View {
    var info: SavedCopyInfo
    var checking: Bool
    var canCheck = true
    var onCheck: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ActionIcon.archive.label("Saved copy")
                .labelStyle(.iconOnly)
                .font(Theme.font(13))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved on this device")
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
                    Text("Checking for updates…")
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checking for updates")
            } else if canCheck {
                Button("Check for updates", .refresh, action: onCheck)
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
        let accountNote = canCheck ? "" : " Verify your account for live updates."
        if info.hasEarlier {
            return "Updated \(when). Earlier messages were not saved." + accountNote
        }
        return "Updated \(when)." + accountNote
    }
}

/// The quiet control in a banner: a word and a glyph, no filled shape. The
/// banner is already tinted, and a button on top of it would compete with the
/// Send button a row below.
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
