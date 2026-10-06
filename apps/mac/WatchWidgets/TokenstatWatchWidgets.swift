// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit

struct TokenstatWatchEntry: TimelineEntry {
    let date: Date
    let snapshot: EcosystemSnapshot
}
struct TokenstatWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenstatWatchEntry { .init(date: Date(), snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (TokenstatWatchEntry) -> Void) {
        completion(.init(date: Date(), snapshot: context.isPreview ? .preview : EcosystemSnapshotStore().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenstatWatchEntry>) -> Void) {
        let now = Date()
        let snapshot = EcosystemSnapshotStore().read()
        let midnight = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        completion(.init(entries: [.init(date: now, snapshot: snapshot), .init(date: midnight, snapshot: snapshot)],
                         policy: .after(now.addingTimeInterval(30 * 60))))
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

@main
struct TokenstatWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.tokenstat.watch.usage", provider: TokenstatWatchProvider()) { entry in
            TokenstatWatchComplicationView(entry: entry)
        }.configurationDisplayName("tokenstat Usage")
            .description("Today's last synced usage at list rates from your iPhone.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
