// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// A compact shelf with separate open and unpin targets. Unavailable folders
/// remain visible so removing a workspace never silently removes its pin.
struct DesktopPinnedWorkSection: View {
    let pins: [PinnedWorkStore.Pin]
    var availability: (PinnedWorkStore.Pin) -> String?
    var subtitle: (PinnedWorkStore.Pin) -> String
    var onOpen: (PinnedWorkStore.Pin) -> Void

    var body: some View {
        if !pins.isEmpty {
            Card(title: L10n.text("apple.desktoppinnedworksection.pinned_work.23dd8f45"), subtitle: L10n.text("apple.desktoppinnedworksection.folders_and_conversations_you_kept_close.e3603d3c"), mark: "mark_pin") {
                VStack(spacing: 0) {
                    ForEach(pins, id: \.key) { pin in
                        let unavailable = availability(pin)
                        HStack(spacing: Theme.Space.s) {
                            Button { onOpen(pin) } label: {
                                HStack(spacing: Theme.Space.m) {
                                    Image(systemName: pin.reference.kind == .workspace
                                          ? "folder" : "bubble.left.and.bubble.right")
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                        Text(pin.label)
                                            .font(Theme.callout.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(unavailable ?? subtitle(pin))
                                            .font(Theme.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, Theme.Space.s)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(unavailable != nil)
                            .accessibilityLabel(L10n.text("apple.desktoppinnedworksection.open_0.e71b4013", "\(pin.label)"))
                            .help(unavailable ?? L10n.text("apple.desktoppinnedworksection.open_0.e71b4013", "\(pin.label)"))
                            ToolbarIconButton(
                                systemImage: ActionIcon.pinned.symbol,
                                help: L10n.text("apple.desktoppinnedworksection.unpin_0.450ccf9f", "\(pin.label)"), isAccent: true
                            ) {
                                Task { await PinnedWorkActions.unpin(pin.reference) }
                            }
                        }
                        if pin.key != pins.last?.key { ThemeRule() }
                    }
                }
            }
            .accessibilityIdentifier("home.pinned")
        }
    }
}
