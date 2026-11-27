// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

struct ClientConnectionChip: View {
    var compact = false

    @Environment(ConnectionModel.self) private var connection
    @Environment(ConnectivityModel.self) private var connectivity
    @State private var showDetail = false

    var body: some View {
        if connection.severity != .ok {
            Button {
                showDetail = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                    if !compact {
                        Text(connection.title)
                            .font(ClientType.caption.weight(.medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 6 : Theme.Space.s)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("apple.clientconnectionchip.connection_0.12c0e720", "\(connection.title)"))
            .popover(isPresented: $showDetail) {
                detail
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var symbol: String {
        if connection.isOffline { return "wifi.slash" }
        if connection.serviceFailing { return "exclamationmark.icloud" }
        return "laptopcomputer.slash"
    }

    private var tint: Color {
        connection.severity == .down ? Theme.danger : Theme.warning
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(connection.title)
                    .font(ClientType.label.weight(.semibold))
                Spacer(minLength: 0)
                NoticeDismissButton { showDetail = false }
            }
            Text(connection.detail)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let seen = lastGood {
                Text(L10n.text("apple.clientconnectionchip.last_answered_0.7941647f", "\(seen)"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            Button(L10n.text("apple.clientconnectionchip.try_now.549f5e23"), .refresh) {
                connectivity.checkNow()
                connection.reset()
                showDetail = false
            }
            .clientProminentStyle()
            .controlSize(.regular)
            .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var lastGood: String? {
        let dates = [connection.lastServiceSuccess, connection.lastPeerSuccess].compactMap { $0 }
        guard let newest = dates.max() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: newest, relativeTo: Date())
    }
}

#endif
