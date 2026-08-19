// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// The one place the client says the network is unwell.
///
/// Hidden while everything answers, so it never becomes furniture. Present, it
/// is four words and a glyph, and tapping it explains which of the three
/// things is wrong and offers the one control that can help.
///
/// It does not replace what a screen says about its own empty state. It is the
/// global answer, the screen gives the local one, and they cannot contradict
/// each other because both read `ConnectionModel`.
struct ClientConnectionChip: View {
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
                    Text(connection.title)
                        .font(ClientType.caption.weight(.medium))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection: \(connection.title)")
            .popover(isPresented: $showDetail) {
                detail
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// A glyph per cause. A wall of identical warning triangles teaches people
    /// to stop reading them, which `FriendlyError` argues at more length.
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
            }
            Text(connection.detail)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let seen = lastGood {
                Text("Last answered \(seen)")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Try now", .refresh) {
                connectivity.checkNow()
                connection.reset()
                showDetail = false
            }
            .clientProminentStyle()
            .controlSize(.regular)
            .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: 320, alignment: .leading)
    }

    /// The most recent answer from either plane. "Nothing since you opened the
    /// app" is said by leaving this out rather than by inventing a date.
    private var lastGood: String? {
        let dates = [connection.lastServiceSuccess, connection.lastPeerSuccess].compactMap { $0 }
        guard let newest = dates.max() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: newest, relativeTo: Date())
    }
}

#endif
