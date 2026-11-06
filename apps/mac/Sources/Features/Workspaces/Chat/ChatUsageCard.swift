// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The usage command shares the composer's readings and the chat's inspection
/// lease. It never sends a prompt or starts a second inspection poller.
struct ChatUsageCard: View {
    @Bindable var model: ChatModel
    private var limitsPeer: String? { model.isSharedSource ? nil : model.peer }
    private var readings: PlanLimitsStore { ChatPlanLimits.store(peer: limitsPeer) }
    @Environment(\.scenePhase) private var scenePhase

    private var provider: ProviderLimits? {
        ComposerLimits.pick(backend: model.selected?.backend ?? "", canonical: harnessCanonicalID,
                            providers: readings.visible, source: \.source, hasWindows: \.hasWindows)
    }

    var body: some View {
        ChatUsageContent(provider: provider, providers: readings.visible,
                         refreshing: readings.isRefreshing,
                         refresh: { Task { try? await readings.refresh(force: true) } },
                         inspection: model.currentActivityRead?.inspection,
                         contextIsStale: model.currentActivityRead?.failed == true,
                         totals: model.turnUsage)
            .task(id: "\(scenePhase):\(limitsPeer ?? "local")") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await readings.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}

struct ChatUsageContent: View {
    var provider: ProviderLimits?
    var providers: [ProviderLimits]
    var refreshing: Bool
    var refresh: () -> Void
    var inspection: ChatInspection?
    var contextIsStale: Bool
    var totals: ChatUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let provider {
                ComposerLimitsDetail(source: provider.source, providers: providers,
                                     refreshing: refreshing, refresh: refresh)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text(L10n.text("apple.composerlimitsbadge.no_readings_for_this_agent_yet.1090da6b"))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L10n.text("common.chat.stats.context")).font(Theme.callout.weight(.semibold))
                if let inspection, let used = inspection.contextUsed {
                    if let window = inspection.contextWindow, let fraction = inspection.fraction {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.text("common.chat.stats.capacity", used.formatted(), window.formatted()))
                                .font(Theme.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                .font(Theme.callout.weight(.medium)).monospacedDigit()
                        }
                        ProgressView(value: min(1, max(0, fraction)))
                            .tint(fraction >= 0.95 ? Theme.danger : fraction >= 0.8 ? Theme.warning : Theme.accent)
                        if inspection.windowSource == "catalog" {
                            Text(L10n.text("common.chat.stats.catalog_window")).font(Theme.caption).foregroundStyle(.secondary)
                        } else if inspection.windowSource == "previousAgent" {
                            Text(L10n.text("common.chat.stats.last_window")).font(Theme.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.text("common.chat.stats.in_context", used.formatted())).font(Theme.callout).monospacedDigit()
                        Text(L10n.text("common.chat.stats.window_unknown")).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    if contextIsStale {
                        Text(L10n.text("common.chat.usage.stale")).font(Theme.caption).foregroundStyle(Theme.warning)
                    }
                    if let stamp = inspection.observedAtMs {
                        Text(L10n.text("apple.chatcontext.reported_at", Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)))
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text("apple.chatcontext.context_unknown")).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            ChatCostMeter(totals: totals)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
