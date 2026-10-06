// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit
import AppIntents

enum EcosystemGaugeStyle: String, AppEnum {
    case rings, bars
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Display" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.rings: "Circles", .bars: "Bars"] }
}

struct TokenstatLimitEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Usage provider" }
    static var defaultQuery = TokenstatLimitQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
    static func identifier(owner: String, source: String) -> String { Data((owner + "\n" + source).utf8).base64EncodedString() }
}
struct TokenstatLimitQuery: EntityStringQuery {
    func suggestedEntities() async throws -> [TokenstatLimitEntity] { entities() }
    func entities(for identifiers: [String]) async throws -> [TokenstatLimitEntity] { entities().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [TokenstatLimitEntity] { entities().filter { $0.name.localizedStandardContains(string) } }
    private func entities() -> [TokenstatLimitEntity] {
        let snapshot = EcosystemSnapshotStore().read()
        guard let owner = snapshot.owner else { return [] }
        return (snapshot.limits ?? []).map { .init(id: TokenstatLimitEntity.identifier(owner: owner, source: $0.source), name: $0.name) }
    }
}

struct TokenstatLimitsConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Plan Limits"
    static var description = IntentDescription("Select one or several providers that share usage readings from your computers. Clear and Tinted follow your Home Screen appearance.")
    @Parameter(title: "Providers") var providers: [TokenstatLimitEntity]?
    @Parameter(title: "Display", default: .rings) var display: EcosystemGaugeStyle
    @Parameter(title: "Full-color style", default: .automatic) var appearance: EcosystemAppearance
    @Parameter(title: "Full-color accent", default: .brand) var tint: EcosystemTint
    static var parameterSummary: some ParameterSummary { Summary { \.$providers; \.$display; \.$appearance; \.$tint } }
}

struct TokenstatLimitsEntry: TimelineEntry {
    let date: Date
    var snapshot: EcosystemSnapshot
    var providerIDs: [String] = []
    var display: EcosystemGaugeStyle = .rings
    var appearance: EcosystemAppearance = .automatic
    var tint: EcosystemTint = .brand
    var readings: [EcosystemLimitProvider] {
        (snapshot.limits ?? []).filter { reading in
            providerIDs.isEmpty || snapshot.owner.map { providerIDs.contains(TokenstatLimitEntity.identifier(owner: $0, source: reading.source)) } == true
        }
            .sorted { $0.source < $1.source }
    }
}

struct TokenstatLimitsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TokenstatLimitsEntry { .init(date: .now, snapshot: .preview) }
    func snapshot(for configuration: TokenstatLimitsConfiguration, in context: Context) async -> TokenstatLimitsEntry {
        entry(configuration, preview: context.isPreview)
    }
    func timeline(for configuration: TokenstatLimitsConfiguration, in context: Context) async -> Timeline<TokenstatLimitsEntry> {
        let current = entry(configuration)
        // A quota reset never means zero used without a new provider reading.
        let transitions = current.readings.flatMap { reading in
            [reading.observedAt.addingTimeInterval(15 * 60)] + reading.windows.compactMap(\.resetsAt)
        }.filter { $0 > current.date && $0 < current.date.addingTimeInterval(24 * 60 * 60) }
        let entries = [current] + Set(transitions).sorted().map { date in
            TokenstatLimitsEntry(date: date, snapshot: current.snapshot, providerIDs: current.providerIDs, display: current.display,
                                appearance: current.appearance, tint: current.tint)
        }
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(15 * 60)))
    }
    private func entry(_ configuration: TokenstatLimitsConfiguration, preview: Bool = false) -> TokenstatLimitsEntry {
        .init(date: .now, snapshot: preview ? .preview : EcosystemSnapshotStore().read(),
              providerIDs: configuration.providers?.map(\.id) ?? [], display: configuration.display, appearance: configuration.appearance, tint: configuration.tint)
    }
}

struct TokenstatLimitsView: View {
    let entry: TokenstatLimitsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    var familyOverride: WidgetFamily?
    private var resolvedFamily: WidgetFamily { familyOverride ?? family }
    private var accent: Color { WidgetStyle.accent(entry.tint, dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: resolvedFamily == .systemSmall ? 7 : 10) {
            HStack {
                Label { if resolvedFamily != .systemSmall || entry.readings.isEmpty { Text("tokenstat").font(.system(.caption, design: .rounded, weight: .bold)) } }
                    icon: { TokenstatWidgetMark(size: 14) }.foregroundStyle(accent).widgetAccentable()
                Spacer(minLength: 0)
                let maximum = resolvedFamily == .systemSmall ? (entry.display == .rings ? 4 : 3) : resolvedFamily == .systemMedium ? 3 : entry.display == .rings ? 9 : 3
                if entry.readings.count > maximum { Text("+\(entry.readings.count - maximum)").font(.caption2).foregroundStyle(.secondary) }
                if entry.readings.contains(where: { $0.isStale(at: entry.date) }) {
                    if resolvedFamily == .systemSmall { Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Cached") }
                    else { Text("Cached").font(.caption2).foregroundStyle(.secondary) }
                }
                if let oldest = entry.readings.map(\.observedAt).min() {
                    Text(oldest, style: .relative).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                }
                Button(intent: RefreshTokenstatLimitsIntent()) { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(accent).widgetAccentable().accessibilityLabel("Refresh plan limits")
            }
            if entry.readings.isEmpty {
                Spacer(minLength: 0)
                Text("Usage limits").font(.headline)
                Text("Enable Share with my devices in Plan limits on your computer, then refresh.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if entry.display == .rings {
                let maximum = resolvedFamily == .systemSmall ? 4 : resolvedFamily == .systemMedium ? 3 : 9
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: resolvedFamily == .systemSmall ? (entry.readings.count == 1 ? 1 : 2) : 3), spacing: 8) {
                    ForEach(Array(entry.readings.prefix(maximum))) { reading in
                        TokenstatLimitRingView(provider: reading, date: entry.date, accent: accent,
                                               diameter: resolvedFamily == .systemSmall ? (entry.readings.count > 1 ? 36 : 52) : resolvedFamily == .systemLarge ? 44 : 52)
                    }
                }
                Spacer(minLength: 0)
            } else if resolvedFamily == .systemSmall {
                if entry.readings.count > 1 {
                    ForEach(Array(entry.readings.prefix(3))) { provider in
                        HStack {
                            Text(provider.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 2)
                            let peak = provider.windows.filter { !$0.expired(at: entry.date) }.max { $0.percent < $1.percent }
                            Text(peak.map { "\(Int($0.percent.rounded()))%" } ?? "—").monospacedDigit().font(.headline)
                        }.privacySensitive()
                    }
                    Text("Used · last shared reading").font(.caption2).foregroundStyle(.secondary)
                    if let oldest = entry.readings.map(\.observedAt).min() {
                        Text(oldest, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                } else if let provider = entry.readings.first {
                    TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: 1)
                }
                Spacer(minLength: 0)
            } else if resolvedFamily == .systemMedium {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(entry.readings.prefix(3))) { provider in
                        TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.readings.prefix(3))) { provider in
                    TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: 1)
                }
                Spacer(minLength: 0)
            }
        }.widgetURL(EcosystemRoute(screen: .home).url)
            .containerBackground(for: .widget) { WidgetStyle.background(entry.appearance, dark: scheme == .dark) }
    }
}

struct TokenstatLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ai.tokenstat.limits", intent: TokenstatLimitsConfiguration.self, provider: TokenstatLimitsProvider()) { entry in
            TokenstatWidgetSurface(appearance: entry.appearance) { TokenstatLimitsView(entry: entry) }
        }.configurationDisplayName("Plan Limits")
            .description("Choose one or several providers. Circle or bar gauges show used allowance, reset times and dated shared readings.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
