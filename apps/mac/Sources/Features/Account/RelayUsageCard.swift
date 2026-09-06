// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The same allowance and day buckets on Mac, iPhone and iPad.
struct RelayUsageCard: View {
    let usage: RelayUsage?
    var refresh: () async -> Void
    @State private var isRefreshing = false

    var body: some View {
        #if os(macOS)
        Card(
            title: "Relay usage",
            subtitle: "One allowance across your devices",
            mark: "mark_activity"
        ) {
            content
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "Relay usage", mark: "mark_activity")
            Text("One allowance across your devices")
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
            if let usage, usage.isSupported {
                counters(usage)
            } else {
                Text("Relay usage details are not available from this server yet.")
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

    private func counters(_ usage: RelayUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("\(RelayUsage.bytes(usage.usedBytes)) of \(RelayUsage.bytes(usage.limitBytes)) used")
                #if os(macOS)
                .font(Theme.callout.weight(.semibold))
                #else
                .font(ClientType.label.weight(.semibold))
                #endif
            ProgressView(value: usage.fraction)
                .tint(Theme.accent)
                .accessibilityLabel("Relay allowance used")
            Text("\(RelayUsage.bytes(usage.remainingBytes)) remaining")
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.caption)
                #endif
                .foregroundStyle(.secondary)

            VStack(spacing: Theme.Space.s) {
                valueRow("Today (UTC)", usage.todayBytes)
                valueRow("This calendar month (UTC)", usage.monthBytes)
                valueRow("Rolling 30 days, used for your limit", usage.usedBytes)
            }
            Text("All relayed traffic shares this allowance. Direct connections do not count. The limit includes today and the previous 29 UTC days. Each day, older usage leaves the window. This is not a daily refill or a calendar-month reset.")
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let unlock = usage.nextUnlockAt {
                Text("Next usage to expire: \(RelayUsage.bytes(usage.nextUnlockBytes)) on \(utcDay(unlock)) at 00:00 UTC.")
                    #if os(macOS)
                    .font(Theme.caption)
                    #else
                    .font(ClientType.caption)
                    #endif
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Daily usage (UTC)") {
                VStack(spacing: Theme.Space.s) {
                    if usage.usedDays.isEmpty {
                        Text("No relayed traffic in this window.")
                            #if os(macOS)
                            .font(Theme.caption)
                            #else
                            .font(ClientType.caption)
                            #endif
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(usage.usedDays.reversed()) { day in
                            valueRow(day.day, day.bytes)
                        }
                    }
                }
                .padding(.top, Theme.Space.s)
            }
            #if os(macOS)
            .font(Theme.callout)
            #else
            .font(ClientType.label)
            .tint(Theme.accent)
            #endif
            Text(asOfCaption(usage))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.caption)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        #if os(macOS)
        Button(isRefreshing ? "Refreshing…" : "Refresh usage", .refresh) {
            Task { await runRefresh() }
        }
        .disabled(isRefreshing)
        #else
        Button {
            Task { await runRefresh() }
        } label: {
            ActionIcon.refresh.label(isRefreshing ? "Refreshing…" : "Refresh usage")
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

    private func utcDay(_ raw: String) -> String {
        String(raw.prefix(10))
    }

    private func asOfCaption(_ usage: RelayUsage) -> String {
        let stamp = formatServerDate(usage.asOf) ?? utcDay(usage.asOf)
        return "As of \(stamp). Relay reporting can lag by about \(usage.reportingDelaySeconds) seconds."
    }
}
