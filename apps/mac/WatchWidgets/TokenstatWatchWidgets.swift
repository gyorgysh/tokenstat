// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit

struct TokenstatWatchEntry: TimelineEntry {
    let date: Date
    let snapshot: EcosystemSnapshot
    var packet: EcosystemWatchPacket? = nil
}
struct TokenstatWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenstatWatchEntry { .init(date: Date(), snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (TokenstatWatchEntry) -> Void) {
        completion(.init(date: Date(), snapshot: context.isPreview ? .preview : (EcosystemWatchPacketStore().read()?.snapshot ?? .empty)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenstatWatchEntry>) -> Void) {
        let now = Date()
        let packet = EcosystemWatchPacketStore().read()
        let snapshot = packet?.snapshot ?? .empty
        let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400))
        let changes = [midnight] + (snapshot.limits ?? []).flatMap { [$0.observedAt.addingTimeInterval(901)] + $0.windows.compactMap(\.resetsAt) } + (packet?.approvals ?? []).map(\.expiresAt)
        let dates = [now] + Set(changes.filter { $0 > now && $0 < now.addingTimeInterval(86_400) }).sorted()
        completion(.init(entries: dates.map { .init(date: $0, snapshot: snapshot, packet: packet) }, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct TokenstatWatchComplicationView: View {
    let entry: TokenstatWatchEntry
    @Environment(\.widgetFamily) private var family
    private var value: UInt64? { entry.snapshot.usage?.today(at: entry.date)?.value }
    private var amount: String { value.map(EcosystemUsage.displayMoney) ?? "—" }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label { Text("tokenstat · \(amount)") } icon: { Image("tokenstat_logo") }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text("tokenstat · Today") } icon: { TokenstatWidgetMark(size: 13) }
                        .font(.caption).foregroundStyle(Color("AccentColor")).widgetAccentable()
                    Text(amount).font(.headline).monospacedDigit()
                    Text(value == nil ? "Open iPhone to sync" : "Value at list rates").font(.caption2)
                }
            case .accessoryCorner:
                TokenstatWidgetMark(size: 22).foregroundStyle(Color("AccentColor")).widgetLabel { Text(amount) }
            default:
                VStack(spacing: 2) {
                    TokenstatWidgetMark(size: 15).foregroundStyle(Color("AccentColor"))
                    Text(value.map(EcosystemUsage.displayMoney) ?? "—")
                        .font(.system(.caption, design: .rounded, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                }.widgetLabel { Text("tokenstat · \(amount) at list rates") }
            }
        }.privacySensitive()
            .containerBackground(.clear, for: .widget)
            .accessibilityLabel("tokenstat today: \(value.map(EcosystemUsage.money) ?? "Unavailable") at list rates")
    }
}

struct TokenstatWatchUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.tokenstat.watch.usage", provider: TokenstatWatchProvider()) { entry in
            TokenstatWatchComplicationView(entry: entry)
        }.configurationDisplayName("tokenstat Usage")
            .description("Today's last synced usage at list rates from your iPhone.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct TokenstatWatchLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.tokenstat.watch.limits", provider: TokenstatWatchProvider()) { entry in
            TokenstatWatchLimitsView(entry: entry)
        }.configurationDisplayName("Plan Limits").description("The highest used allowance in your last shared provider readings.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct TokenstatWatchLimitsView: View {
    let entry: TokenstatWatchEntry
    @Environment(\.widgetFamily) private var family
    private var provider: EcosystemLimitProvider? {
        entry.snapshot.limits?.filter { $0.peak(at: entry.date) != nil }.max { ($0.peak(at: entry.date)?.percent ?? 0) < ($1.peak(at: entry.date)?.percent ?? 0) }
    }
    var body: some View {
        let window = provider?.peak(at: entry.date)
        Group {
            if family == .accessoryCircular {
                Gauge(value: window?.fraction ?? 0) {
                    TokenstatWidgetMark(size: 13)
                } currentValueLabel: {
                    Text(window.map { "\(Int($0.percent.rounded()))%" } ?? "—").font(.caption2).minimumScaleFactor(0.6)
                }.gaugeStyle(.accessoryCircular).tint(Color("AccentColor"))
                    .widgetLabel { Text(provider?.name ?? "Plan limits") }
            } else if family == .accessoryInline {
                Label { Text("\(provider?.name ?? "Limits") · \(window.map { "\(Int($0.percent.rounded()))%" } ?? "—")") } icon: { Image("tokenstat_logo") }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text(provider?.name ?? "Plan limits") } icon: { TokenstatWidgetMark(size: 13) }
                        .font(.caption).foregroundStyle(Color("AccentColor")).widgetAccentable()
                    Text(window.map { "\(Int($0.percent.rounded()))% used · \($0.label)" } ?? "Open iPhone to sync").font(.caption).lineLimit(1)
                    if let provider { Text("\(provider.isStale(at: entry.date) ? "Cached · " : "")\(provider.observedAt, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }.containerBackground(.clear, for: .widget).privacySensitive()
            .widgetURL(URL(string: "tokenstat://watch/limits"))
            .accessibilityLabel("Plan limits, \(provider?.name ?? "no reading"), \(window.map { "\(Int($0.percent.rounded())) percent used" } ?? "refresh to check"). Last shared observation.")
    }
}
struct TokenstatWatchRequestsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.tokenstat.watch.requests", provider: TokenstatWatchProvider()) { entry in
            let count = (entry.packet?.approvals ?? []).filter { $0.expiresAt > entry.date }.count
            let omitted = entry.packet?.omittedApprovals ?? 0
            VStack(spacing: 2) {
                TokenstatWidgetMark(size: 15).foregroundStyle(Color("AccentColor")).widgetAccentable()
                Text("\(count)\(omitted > 0 ? "+" : "")").font(.headline).monospacedDigit()
            }.widgetLabel { Text("Last synced requests") }.containerBackground(.clear, for: .widget).privacySensitive()
                .widgetURL(URL(string: "tokenstat://watch/requests"))
                .accessibilityLabel("\(count) pending requests in the last sync\(omitted > 0 ? ", more on iPhone" : "")")
        }.configurationDisplayName("Requests").description("Pending requests from the last iPhone sync. Open to refresh and review.")
            .supportedFamilies([.accessoryCircular])
    }
}
@main struct TokenstatWatchWidgets: WidgetBundle {
    var body: some Widget { TokenstatWatchUsageWidget(); TokenstatWatchLimitsWidget(); TokenstatWatchRequestsWidget() }
}
