// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

struct ClientLimitsCard: View {
    let providers: [ProviderLimits]
    let isLoading: Bool
    var errorMessage: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientlimitscard.plan_limits.925788cd"), mark: "mark_plan")

            if errorMessage != nil {
                Text(L10n.text("apple.clientlimitscard.plan_readings_could_not_be_refreshed_pull.e771bffd"))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.controlGlyph)
            }
            if isLoading && readable.isEmpty {
                ClientWireframe.Rows(count: 2)
            } else if readable.isEmpty && errorMessage == nil {
                Text(L10n.text("apple.clientlimitscard.no_readings_yet_on_a_mac_open_plan_limits.467d1c76"))
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                WidthReader { width in
                    VStack(spacing: Theme.Space.m) {
                        ForEach(Array(rows(for: width).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: Theme.Space.m) {
                                ForEach(row) { provider in
                                    ProviderRow(provider: provider)
                                        .padding(Theme.Space.m)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .cardSurface()
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func rows(for width: CGFloat) -> [[ProviderLimits]] {
        let all = sorted
        let count = columnCount(for: width)
        guard count > 0 else { return [all] }
        return stride(from: 0, to: all.count, by: count).map {
            Array(all[$0..<min($0 + count, all.count)])
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        let available = width > 0 ? width : 320
        let minimum = min(available, typeSize.isAccessibilitySize ? 600 : 320)
        let fits = Int((available + Theme.Space.m) / (minimum + Theme.Space.m))
        return max(1, fits)
    }

    private var readable: [ProviderLimits] {
        providers.filter(\.hasWindows)
    }

    private var sorted: [ProviderLimits] {
        PlanLimitsOrder.ordered(readable, source: \.source)
    }
}

private struct ProviderRow: View {
    let provider: ProviderLimits

    private var title: String {
        let name = harnessName(provider.source)
        guard let id = provider.profileId else { return name }
        let profile = AgentProfileCatalog.shared.name(id) ?? L10n.text("common.profiles.named_limits")
        return "\(name) · \(profile)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                HarnessMark(id: provider.source, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(ClientType.label.weight(.medium))
                    if let plan = provider.plan {
                        Text(plan)
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Text(observed)
                    .font(ClientType.caption)
                    .foregroundStyle(provider.isStale ? Theme.warning : .secondary)
            }

            if provider.hasWindows {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    WindowGauge(window: window)
                }
            } else if let note = provider.note {
                Text(note)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .contain)
    }

    private var observed: String {
        guard let at = provider.observedAt else { return L10n.text("apple.clientlimitscard.no_date.89be6303") }
        let ago = at.formatted(.relative(presentation: .numeric))
        return provider.isStale ? L10n.text("apple.clientlimitscard.stale_0.23070062", "\(ago)") : ago
    }
}

private struct WindowGauge: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.displayLabel)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.percent.formatted(.number.precision(.fractionLength(0))))%")
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(colour)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule()
                        .fill(colour)
                        .frame(width: max(3, geo.size.width * window.fraction))
                }
            }
            .frame(height: 6)
            if let resets = window.resetsAt {
                Text(L10n.text("apple.clientlimitscard.resets_0.5eb38742", "\(resets.formatted(.relative(presentation: .numeric)))"))
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("apple.clientlimitscard.0_1_percent_used.bae57146", "\(window.displayLabel)", "\(window.percent.formatted(.number.precision(.fractionLength(0))))"))
    }

    private var colour: Color {
        switch window.severity {
        case .critical: return Theme.danger
        case .warning: return Theme.warning
        case .normal: return Theme.accent
        }
    }
}

#endif
