// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// This device's own connections, kept apart from the account relay allowance.
struct LocalTrafficCard: View {
    let traffic: RemoteTraffic?
    var refresh: () async -> Void
    @State private var isRefreshing = false

    var body: some View {
        #if os(macOS)
        Card(
            title: L10n.text("apple.localtrafficcard.this_device.d052579c"),
            subtitle: L10n.text("apple.localtrafficcard.how_connections_leave_this_machine.a5ac544a"),
            mark: "mark_activity"
        ) {
            content
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.localtrafficcard.this_device.d052579c"), mark: "mark_activity")
            Text(L10n.text("apple.localtrafficcard.how_connections_leave_this_machine.a5ac544a"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            content
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        #endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let traffic {
                counters(traffic)
            } else {
                Text(L10n.text("apple.localtrafficcard.this_computer_does_not_report_local_traffi.c31505cb"))
                    #if os(macOS)
                    .font(Theme.callout)
                    #else
                    .font(ClientType.body)
                    #endif
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            refreshButton
        }
    }

    private func counters(_ traffic: RemoteTraffic) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(spacing: Theme.Space.s) {
                valueRow(L10n.text("apple.localtrafficcard.direct.002c7c68"), traffic.directBytes)
                valueRow(L10n.text("apple.localtrafficcard.relayed.feb39b70"), traffic.relayBytes)
            }
            Text(L10n.text("apple.localtrafficcard.counted_on_this_device_since_tokenstat_sta.0fc360a7"))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if traffic.peers.isEmpty {
                Text(L10n.text("apple.localtrafficcard.no_live_connections_right_now.a7f971c5"))
                    #if os(macOS)
                    .font(Theme.caption)
                    #else
                    .font(ClientType.caption)
                    #endif
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(traffic.peers) { peer in
                        HStack(alignment: .firstTextBaseline) {
                            Text(peer.label.isEmpty ? peer.peer : peer.label)
                            Spacer(minLength: Theme.Space.s)
                            Text(peer.routeLabel)
                                .foregroundStyle(.secondary)
                        }
                        #if os(macOS)
                        .font(Theme.callout)
                        #else
                        .font(ClientType.label)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                        #endif
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        #if os(macOS)
        Button(isRefreshing ? L10n.text("apple.localtrafficcard.refreshing.1c0def7b") : L10n.text("apple.localtrafficcard.refresh_traffic.9e5ac8c2"), .refresh) {
            Task { await runRefresh() }
        }
        .disabled(isRefreshing)
        #else
        Button {
            Task { await runRefresh() }
        } label: {
            ActionIcon.refresh.label(isRefreshing ? L10n.text("apple.localtrafficcard.refreshing.1c0def7b") : L10n.text("apple.localtrafficcard.refresh_traffic.9e5ac8c2"))
                .labelStyle(ActionLabelStyle())
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        #endif
    }

    private func valueRow(_ label: String, _ bytes: UInt64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: Theme.Space.s)
            Text(RelayUsage.bytes(bytes)).monospacedDigit()
        }
        #if os(macOS)
        .font(Theme.callout)
        #else
        .font(ClientType.label)
        .frame(minHeight: 44)
        .contentShape(.rect)
        #endif
    }

    private func runRefresh() async {
        isRefreshing = true
        await refresh()
        isRefreshing = false
    }
}
