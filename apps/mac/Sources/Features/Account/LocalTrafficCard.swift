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
            title: "This device",
            subtitle: "How connections leave this machine",
            mark: "mark_activity"
        ) {
            content
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "This device", mark: "mark_activity")
            Text("How connections leave this machine")
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
                Text("This host does not report local traffic yet.")
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
                valueRow("Direct", traffic.directBytes)
                valueRow("Relayed", traffic.relayBytes)
            }
            Text("Counted on this device since tokenstat started. Direct traffic does not use the account relay allowance. The relayed figure is this machine only, not the account total.")
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if traffic.peers.isEmpty {
                Text("No live connections right now.")
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
        Button(isRefreshing ? "Refreshing…" : "Refresh traffic", .refresh) {
            Task { await runRefresh() }
        }
        .disabled(isRefreshing)
        #else
        Button {
            Task { await runRefresh() }
        } label: {
            ActionIcon.refresh.label(isRefreshing ? "Refreshing…" : "Refresh traffic")
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
