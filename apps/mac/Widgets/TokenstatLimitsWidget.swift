// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit
import AppIntents

enum EcosystemGaugeStyle: String, AppEnum {
    case rings, bars
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Display" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.rings: "Circles", .bars: "Bars"] }
}

extension EcosystemLimitWindowSelection: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Limit window" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.highest: "Highest usage", .fiveHour: "5-hour", .weekly: "Weekly", .both: "5-hour and weekly", .all: "All windows"]
    }
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
    @Parameter(title: "Limit window", default: .highest) var window: EcosystemLimitWindowSelection
    @Parameter(title: "Full-color style", default: .automatic) var appearance: EcosystemAppearance
    @Parameter(title: "Full-color accent", default: .brand) var tint: EcosystemTint
    static var parameterSummary: some ParameterSummary { Summary { \.$providers; \.$display; \.$window; \.$appearance; \.$tint } }
}

struct TokenstatLimitsEntry: TimelineEntry {
    let date: Date
    var snapshot: EcosystemSnapshot
    var providerIDs: [String] = []
    var display: EcosystemGaugeStyle = .rings
    var appearance: EcosystemAppearance = .automatic
    var tint: EcosystemTint = .brand
    var window: EcosystemLimitWindowSelection = .highest
    var readings: [EcosystemLimitProvider] {
        (snapshot.limits ?? []).filter { reading in
            providerIDs.isEmpty || snapshot.owner.map { providerIDs.contains(TokenstatLimitEntity.identifier(owner: $0, source: reading.source)) } == true
        }
            .sorted { $0.source < $1.source }
    }
    struct Gauge: Identifiable {
        var provider: EcosystemLimitProvider
        var window: EcosystemLimitWindow?
        var id: String { provider.id + ":" + (window?.id ?? "missing") }
    }
    var gauges: [Gauge] {
        readings.flatMap { provider in
            let windows = window.windows(from: provider, at: date)
            return windows.isEmpty ? [Gauge(provider: provider)] : windows.map { Gauge(provider: provider, window: $0) }
        }
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
        } + (1...3).map { current.date.addingTimeInterval(Double($0) * 5 * 60) }
            + [current.snapshot.limitsRefresh?.expiresAt].compactMap { $0 }
        let dates = transitions.filter { $0 > current.date && $0 < current.date.addingTimeInterval(24 * 60 * 60) }
        let entries = [current] + Set(dates).sorted().map { date in
            TokenstatLimitsEntry(date: date, snapshot: current.snapshot, providerIDs: current.providerIDs, display: current.display,
                                appearance: current.appearance, tint: current.tint, window: current.window)
        }
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(15 * 60)))
    }
    private func entry(_ configuration: TokenstatLimitsConfiguration, preview: Bool = false) -> TokenstatLimitsEntry {
        .init(date: .now, snapshot: preview ? .preview : EcosystemSnapshotStore().read(),
              providerIDs: configuration.providers?.map(\.id) ?? [], display: configuration.display, appearance: configuration.appearance, tint: configuration.tint, window: configuration.window)
    }
}

struct TokenstatLimitsView: View {
    let entry: TokenstatLimitsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    var familyOverride: WidgetFamily?
    private var resolvedFamily: WidgetFamily { familyOverride ?? family }
    private var accent: Color { WidgetStyle.accent(entry.tint, dark: scheme == .dark) }
    private func summary(_ provider: EcosystemLimitProvider) -> String {
        if entry.window == .both {
            return [EcosystemLimitWindowSelection.fiveHour, .weekly].map { selection in
                selection.windows(from: provider, at: entry.date).first.flatMap {
                    $0.expired(at: entry.date) ? nil : "\(Int($0.percent.rounded()))%"
                } ?? "—"
            }.joined(separator: " · ")
        }
        let windows = entry.window.windows(from: provider, at: entry.date)
        guard !windows.isEmpty else { return "—" }
        let values = windows.prefix(2).map { $0.expired(at: entry.date) ? "—" : "\(Int($0.percent.rounded()))%" }.joined(separator: " · ")
        return values + (windows.count > 2 ? " +\(windows.count - 2)" : "")
    }
    private func readingDescription(_ provider: EcosystemLimitProvider) -> String {
        let windows = entry.window.windows(from: provider, at: entry.date)
        let details = windows.map { window in
            window.label + ": " + (window.expired(at: entry.date) ? "refresh after reset" : "\(Int(window.percent.rounded())) percent used")
        }.joined(separator: ", ")
        return provider.name + ": " + (details.isEmpty ? "No reading" : details)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: resolvedFamily == .systemSmall ? 7 : 10) {
            HStack {
                Label { if resolvedFamily != .systemSmall || entry.readings.isEmpty { Text("tokenstat").font(.system(.caption, design: .rounded, weight: .bold)) } }
                    icon: { TokenstatWidgetMark(size: 14) }.foregroundStyle(accent).widgetAccentable()
                Spacer(minLength: 12)
                let maximum = resolvedFamily == .systemSmall ? (entry.display == .rings ? 4 : 3) : resolvedFamily == .systemMedium ? (entry.display == .rings ? 4 : 3) : entry.display == .rings ? 9 : 3
                let shown = entry.display == .rings ? maximum : entry.readings.prefix(maximum).reduce(0) {
                    $0 + max(1, min(entry.window == .both || entry.window == .all ? 2 : 1, entry.window.windows(from: $1, at: entry.date).count))
                }
                if entry.gauges.count > shown { Text("+\(entry.gauges.count - shown)").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("\(entry.gauges.count - shown) additional limits") }
                TokenstatWidgetRefreshButton(intent: RefreshTokenstatLimitsIntent(), feedback: entry.snapshot.limitsRefresh,
                                             date: entry.date, accent: accent, title: "Refresh plan limits")
            }
            if entry.readings.isEmpty {
                Spacer(minLength: 0)
                Text("Usage limits").font(.headline)
                Text("Enable Share with my devices in Plan limits on your computer, then refresh.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if entry.display == .rings {
                let maximum = resolvedFamily == .systemSmall ? 4 : resolvedFamily == .systemMedium ? 4 : 9
                let count = min(maximum, entry.gauges.count)
                let columns = resolvedFamily == .systemSmall ? min(2, max(1, count)) : resolvedFamily == .systemMedium ? max(1, count) : 3
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: resolvedFamily == .systemSmall ? 4 : 8) {
                    ForEach(Array(entry.gauges.prefix(maximum))) { gauge in
                        TokenstatLimitRingView(provider: gauge.provider, date: entry.date, accent: accent,
                                               diameter: resolvedFamily == .systemSmall ? (count > 2 ? 28 : count > 1 ? 36 : 52) : resolvedFamily == .systemMedium && count == 4 ? 36 : 44,
                                               selectedWindow: gauge.window, usesSelectedWindow: true)
                    }
                }
                Spacer(minLength: 0)
            } else if resolvedFamily == .systemSmall {
                if entry.readings.count > 1 {
                    ForEach(Array(entry.readings.prefix(3))) { provider in
                        HStack {
                            Text(provider.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(summary(provider))
                                .monospacedDigit().font(entry.window == .both || entry.window == .all ? .caption.weight(.semibold) : .headline).lineLimit(1).minimumScaleFactor(0.7).invalidatableContent()
                        }.privacySensitive().accessibilityElement(children: .ignore)
                            .accessibilityLabel(readingDescription(provider))
                    }
                } else if let provider = entry.readings.first {
                    TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: entry.window == .both || entry.window == .all ? 2 : 1, showsFreshness: false, selectedWindows: entry.window.windows(from: provider, at: entry.date), showsResetDetails: entry.window != .both && entry.window != .all || resolvedFamily == .systemLarge && entry.readings.count <= 2)
                }
                Spacer(minLength: 0)
            } else if resolvedFamily == .systemMedium {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(entry.readings.prefix(3))) { provider in
                        TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: entry.window == .both || entry.window == .all ? 2 : 1, showsFreshness: false, selectedWindows: entry.window.windows(from: provider, at: entry.date), showsResetDetails: entry.window != .both && entry.window != .all || resolvedFamily == .systemLarge && entry.readings.count <= 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            } else {
                ForEach(Array(entry.readings.prefix(3))) { provider in
                    TokenstatLimitReadingView(provider: provider, date: entry.date, accent: accent, maximumWindows: entry.window == .both || entry.window == .all ? 2 : 1, showsFreshness: false, selectedWindows: entry.window.windows(from: provider, at: entry.date), showsResetDetails: entry.window != .both && entry.window != .all || resolvedFamily == .systemLarge && entry.readings.count <= 2)
                }
                Spacer(minLength: 0)
            }
            if let oldest = entry.readings.map(\.observedAt).min() {
                Text((resolvedFamily == .systemSmall && entry.display == .bars && entry.window == .both ? "5h · Week · " : "") + EcosystemWidgetTime.age(oldest, at: entry.date))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel("Oldest shared reading \(oldest.formatted()), \(entry.readings.contains { $0.isStale(at: entry.date) } ? "older readings" : "recent readings")")
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
