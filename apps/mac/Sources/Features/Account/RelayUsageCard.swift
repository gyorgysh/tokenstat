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
            title: L10n.text("apple.relayusagecard.relay_usage.1addb713"),
            subtitle: L10n.text("apple.relayusagecard.one_allowance_across_your_devices.608bfc41"),
            mark: "mark_activity"
        ) {
            content
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.relayusagecard.relay_usage.1addb713"), mark: "mark_activity")
            Text(L10n.text("apple.relayusagecard.one_allowance_across_your_devices.608bfc41"))
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
                Text(L10n.text("apple.relayusagecard.relay_usage_details_are_not_available_from.84fc7e91"))
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
            Text(L10n.text("apple.relayusagecard.0_of_1_used.2226de62", "\(RelayUsage.bytes(usage.usedBytes))", "\(RelayUsage.bytes(usage.limitBytes))"))
                #if os(macOS)
                .font(Theme.callout.weight(.semibold))
                #else
                .font(ClientType.label.weight(.semibold))
                #endif
            ProgressView(value: usage.fraction)
                .tint(Theme.accent)
                .accessibilityLabel(L10n.text("apple.relayusagecard.relay_allowance_used.92f1add8"))
            Text(L10n.text("apple.relayusagecard.0_remaining.dc8d32fc", "\(RelayUsage.bytes(usage.remainingBytes))"))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.caption)
                #endif
                .foregroundStyle(.secondary)

            VStack(spacing: Theme.Space.s) {
                valueRow(L10n.text("apple.relayusagecard.today_utc.7a33b067"), usage.todayBytes)
                valueRow(L10n.text("apple.relayusagecard.this_calendar_month_utc.379dc97f"), usage.monthBytes)
                valueRow(L10n.text("apple.relayusagecard.rolling_30_days_used_for_your_limit.290548eb"), usage.usedBytes)
            }
            Text(L10n.text("apple.relayusagecard.all_relayed_traffic_shares_this_allowance.a652388b"))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.body)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let unlock = usage.nextUnlockAt {
                Text(L10n.text("apple.relayusagecard.next_usage_to_expire_0_on_1_at_00_00_utc.1b64d175", "\(RelayUsage.bytes(usage.nextUnlockBytes))", "\(utcDay(unlock))"))
                    #if os(macOS)
                    .font(Theme.caption)
                    #else
                    .font(ClientType.caption)
                    #endif
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(L10n.text("apple.relayusagecard.daily_usage_utc.520a8261")) {
                VStack(spacing: Theme.Space.s) {
                    if usage.usedDays.isEmpty {
                        Text(L10n.text("apple.relayusagecard.no_relayed_traffic_in_this_window.a3f245c1"))
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
        Button(isRefreshing ? L10n.text("apple.relayusagecard.refreshing.1c0def7b") : L10n.text("apple.relayusagecard.refresh_usage.8d3a136d"), .refresh) {
            Task { await runRefresh() }
        }
        .disabled(isRefreshing)
        #else
        Button {
            Task { await runRefresh() }
        } label: {
            ActionIcon.refresh.label(isRefreshing ? L10n.text("apple.relayusagecard.refreshing.1c0def7b") : L10n.text("apple.relayusagecard.refresh_usage.8d3a136d"))
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
        return L10n.text("apple.relayusagecard.as_of_0_relay_reporting_can_lag_by_about_1.f028d9ec", "\(stamp)", "\(usage.reportingDelaySeconds)")
    }
}
