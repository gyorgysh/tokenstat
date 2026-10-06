// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WidgetKit
import AppIntents

struct TokenstatWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: EcosystemSnapshot
    var period: EcosystemPeriod = .today
    var appearance: EcosystemAppearance = .automatic
    var tint: EcosystemTint = .brand
    var screen: EcosystemScreen = .workspaces
    var favoriteID: String?

    var favorite: EcosystemProject? {
        guard let owner = snapshot.owner, let favoriteID else { return nil }
        return snapshot.projects.first { TokenstatProjectEntity(project: $0, owner: owner).id == favoriteID }
    }
    var destination: EcosystemRoute {
        if let favorite { return .init(screen: .workspaces, projectID: favorite.id, owner: snapshot.owner) }
        return .init(screen: screen)
    }
}

private func widgetTimeline(_ entry: TokenstatWidgetEntry) -> Timeline<TokenstatWidgetEntry> {
    let calendar = Calendar.current
    let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: entry.date)!)
    var tomorrow = entry
    tomorrow = .init(date: midnight, snapshot: entry.snapshot, period: entry.period, appearance: entry.appearance,
                     tint: entry.tint, screen: entry.screen, favoriteID: entry.favoriteID)
    // Midnight is evaluated locally; the system controls the requested reload budget.
    return Timeline(entries: [entry, tomorrow], policy: .after(entry.date.addingTimeInterval(30 * 60)))
}

struct TokenstatUsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TokenstatWidgetEntry { .init(date: Date(), snapshot: .preview) }
    func snapshot(for configuration: TokenstatUsageConfiguration, in context: Context) async -> TokenstatWidgetEntry {
        entry(configuration, preview: context.isPreview)
    }
    func timeline(for configuration: TokenstatUsageConfiguration, in context: Context) async -> Timeline<TokenstatWidgetEntry> {
        widgetTimeline(entry(configuration))
    }
    private func entry(_ configuration: TokenstatUsageConfiguration, preview: Bool = false) -> TokenstatWidgetEntry {
        .init(date: Date(), snapshot: preview ? .preview : EcosystemSnapshotStore().read(),
              period: configuration.period, appearance: configuration.appearance, tint: configuration.tint)
    }
}

struct TokenstatLauncherProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TokenstatWidgetEntry { .init(date: Date(), snapshot: .preview) }
    func snapshot(for configuration: TokenstatLauncherConfiguration, in context: Context) async -> TokenstatWidgetEntry {
        entry(configuration, preview: context.isPreview)
    }
    func timeline(for configuration: TokenstatLauncherConfiguration, in context: Context) async -> Timeline<TokenstatWidgetEntry> {
        widgetTimeline(entry(configuration))
    }
    private func entry(_ configuration: TokenstatLauncherConfiguration, preview: Bool = false) -> TokenstatWidgetEntry {
        .init(date: Date(), snapshot: preview ? .preview : EcosystemSnapshotStore().read(),
              appearance: configuration.appearance, tint: configuration.tint, screen: configuration.screen, favoriteID: configuration.project?.id)
    }
}

/// Resolve appearance outside the content so semantic primary/secondary colors
/// and the background always use the same scheme. Tinted widgets remain system styled.
struct TokenstatWidgetSurface<Content: View>: View {
    let appearance: EcosystemAppearance
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    var body: some View {
        content().environment(\.colorScheme, resolvedScheme)
    }
    private var resolvedScheme: ColorScheme {
        guard renderingMode == .fullColor else { return scheme }
        switch appearance {
        case .automatic, .clean: return scheme
        case .light: return .light
        case .dark, .black: return .dark
        }
    }
}

enum WidgetStyle {
    static func icon(for screen: EcosystemScreen) -> Image {
        screen == .insights ? Image("tokenstat_logo") : Image(systemName: screen.symbol)
    }
    static func accent(_ tint: EcosystemTint, dark: Bool) -> Color {
        switch tint {
        case .brand: return accent(dark)
        case .teal: return dark ? Color(red: 0.18, green: 0.83, blue: 0.75) : Color(red: 0.0, green: 0.44, blue: 0.40)
        case .orange: return dark ? Color(red: 1, green: 0.68, blue: 0.35) : Color(red: 0.69, green: 0.30, blue: 0.0)
        case .pink: return dark ? Color(red: 1, green: 0.48, blue: 0.70) : Color(red: 0.75, green: 0.15, blue: 0.43)
        case .monochrome: return .primary
        }
    }
    @ViewBuilder static func background(_ appearance: EcosystemAppearance, dark: Bool) -> some View {
        switch appearance {
        case .black: Color.black
        case .clean:
            Rectangle().fill(.ultraThinMaterial)
                .overlay((dark ? Color.black : Color.white).opacity(dark ? 0.20 : 0.75))
                .overlay(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.35), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(dark ? 0.12 : 0.5)))
        default: background(dark)
        }
    }
    static func accent(_ dark: Bool) -> Color {
        dark ? Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)
             : Color(red: 0x6A / 255, green: 0x3D / 255, blue: 1)
    }
    static func secondary(_ dark: Bool) -> Color {
        dark ? Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0xF9 / 255)
             : Color(red: 0xC0 / 255, green: 0x26 / 255, blue: 0xD3 / 255)
    }

    static func background(_ dark: Bool) -> LinearGradient {
        LinearGradient(colors: dark
            ? [Color(red: 0x10 / 255, green: 0x0E / 255, blue: 0x1A / 255), Color(red: 0x08 / 255, green: 0x07 / 255, blue: 0x0D / 255)]
            : [Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFD / 255), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct TokenstatUsageWidget: Widget {
    let kind = "ai.tokenstat.usage"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TokenstatUsageConfiguration.self, provider: TokenstatUsageProvider()) { entry in
            TokenstatWidgetSurface(appearance: entry.appearance) { TokenstatUsageView(entry: entry) }
        }
        .configurationDisplayName("Usage at a Glance")
        .description("Today's value at list rates, your week and your activity. Choose Today or Week and refresh without leaving your widget.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
         .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct TokenstatUsageView: View {
    let entry: TokenstatWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { WidgetStyle.accent(entry.tint, dark: colorScheme == .dark) }
    private var muted: Color { entry.appearance == .clean ? .primary.opacity(0.72) : .secondary }
    private var usage: EcosystemUsage? { entry.snapshot.usage }
    private var today: EcosystemDay? { usage?.today(at: entry.date) }
    private var week: [EcosystemDay] { usage?.weekWindow(at: entry.date) ?? [] }
    private var selectedValue: UInt64? { entry.period == .today ? today?.value : usage?.weekTotal(at: entry.date) }
    private var periodTitle: String { entry.period == .today ? "TODAY" : "7 DAYS" }
    private var weekValue: String { usage?.weekTotal(at: entry.date).map(EcosystemUsage.displayMoney) ?? "—" }

    var body: some View {
        Group {
            #if os(iOS)
            switch family {
            case .accessoryInline:
                Label { Text(selectedValue.map { "tokenstat · \(EcosystemUsage.displayMoney($0))" } ?? "tokenstat · Open to update") }
                    icon: { Image("tokenstat_logo") }
                    .privacySensitive()
            case .accessoryCircular:
                VStack(spacing: 2) {
                    TokenstatWidgetMark(size: 18)
                    Text(selectedValue.map(EcosystemUsage.displayMoney) ?? "—")
                        .font(.system(.headline, design: .rounded)).lineLimit(1).minimumScaleFactor(0.4)
                }
                .privacySensitive()
                .accessibilityLabel(selectedValue.map { "\(periodTitle) value at list rates: \(EcosystemUsage.money($0))" } ?? "Open tokenstat to update usage")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text(entry.period == .today ? "tokenstat · Today" : "tokenstat · Week") }
                        icon: { TokenstatWidgetMark(size: 13) }.font(.caption)
                    Text(selectedValue.map { EcosystemUsage.displayMoney($0) } ?? "Open to update").font(.headline).lineLimit(1).minimumScaleFactor(0.6)
                    Text(usage?.scope ?? "Value at list rates").font(.caption2)
                }.privacySensitive()
            default: card
            }
            #else
            card
            #endif
        }
        .widgetURL(EcosystemRoute(screen: .home).url)
        .containerBackground(for: .widget) {
            #if os(iOS)
            if [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family) {
                AccessoryWidgetBackground()
            } else {
                WidgetStyle.background(entry.appearance, dark: colorScheme == .dark)
            }
            #else
            WidgetStyle.background(entry.appearance, dark: colorScheme == .dark)
            #endif
        }
    }

    @ViewBuilder private var card: some View {
        if usage == nil {
            VStack(alignment: .leading, spacing: 10) {
                header
                Spacer(minLength: 0)
                if family != .systemSmall {
                    TokenstatWidgetMark(size: 26).foregroundStyle(accent)
                }
                Text("Your work, at a glance").font(.headline)
                Text("Open tokenstat to load your activity.").font(.caption).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
    }

    private var header: some View {
        HStack {
            Label { Text("tokenstat") } icon: { TokenstatWidgetMark(size: 14) }
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(accent)
                .widgetAccentable()
            Spacer(minLength: 2)
            if family != .systemSmall {
                Text(usage?.scope ?? "ACTIVITY").font(.caption2).foregroundStyle(muted).lineLimit(1)
            }
            refreshButton
        }
    }

    private var value: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(periodTitle).font(.system(.caption2, design: .rounded, weight: .semibold)).foregroundStyle(muted)
            Text(selectedValue.map { EcosystemUsage.displayMoney($0) } ?? "—")
                .font(.system(size: family == .systemSmall ? 28 : 36, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                .contentTransition(.numericText()).invalidatableContent()
                .accessibilityLabel(selectedValue.map(EcosystemUsage.money) ?? "Value unavailable")
            Text(selectedValue == nil ? "Refresh to update" : "Value at list rates").font(.caption2).foregroundStyle(muted)
        }.privacySensitive()
    }

    private var refreshButton: some View {
        Button(intent: RefreshTokenstatIntent()) {
            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24).contentShape(Circle())
        }.buttonStyle(.plain).foregroundStyle(accent)
            .widgetAccentable()
            .accessibilityLabel("Refresh tokenstat usage")
    }

    private var freshness: some View {
        HStack(spacing: 4) {
            Image(systemName: entry.snapshot.refreshFailed == true ? "wifi.exclamationmark" : "clock").font(.system(size: 9))
            if entry.snapshot.refreshFailed == true { Text("Update unavailable").lineLimit(1) }
            else if let date = usage?.updatedAt { Text(date, style: .relative).lineLimit(1) }
            else { Text("Not yet synced") }
            Spacer(minLength: 0)
        }
        .font(.caption2).foregroundStyle(muted)
        .accessibilityLabel("Last updated \(usage?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "unknown")")
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            value
            Spacer(minLength: 0)
            weekBars.frame(height: 18)
            freshness
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .bottom, spacing: 20) {
                value.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(entry.period == .today ? "7 DAYS" : "TODAY").font(.caption2).foregroundStyle(muted)
                        Spacer()
                        Text(entry.period == .today ? weekValue : today.map { EcosystemUsage.displayMoney($0.value) } ?? "—")
                            .font(.caption).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.55)
                    }
                    weekBars.frame(height: 42)
                }.frame(maxWidth: .infinity).privacySensitive()
            }
            Spacer(minLength: 0)
            freshness
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
            header
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    summary.frame(width: 240)
                    activity.frame(minWidth: 270)
                }
                VStack(alignment: .leading, spacing: 12) { summary; activity }
            }
            Spacer(minLength: 0)
            HStack {
                freshness
                Link(destination: EcosystemRoute(screen: .insights).url) {
                    Label("Insights", systemImage: "arrow.up.right").font(.caption).fontWeight(.semibold)
                }.foregroundStyle(accent)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            value
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.period == .today ? "7 DAYS" : "TODAY").font(.caption2).foregroundStyle(muted)
                    Text(entry.period == .today ? weekValue : today.map { EcosystemUsage.displayMoney($0.value) } ?? "—")
                        .font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                }
                Spacer()
                Label("\(usage?.streak ?? 0) day streak", systemImage: "flame.fill")
                    .font(.caption).foregroundStyle(accent)
            }.privacySensitive()
            if family == .systemExtraLarge {
                weekBars.frame(height: 76).padding(.top, 8)
            }
        }
    }

    private var weekBars: some View {
        GeometryReader { geometry in
            let maxValue = max(week.filter { !$0.locked }.map(\.value).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(week) { day in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [entry.tint == .brand ? WidgetStyle.secondary(colorScheme == .dark) : accent, accent], startPoint: .top, endPoint: .bottom))
                        .opacity(day.locked ? 0.12 : day.day == today?.day ? 1 : 0.5)
                        .widgetAccentable()
                        .frame(height: max(3, geometry.size.height * CGFloat(day.locked ? 0 : day.value) / CGFloat(maxValue)))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weekValue == "—" ? "Seven-day value unavailable. Open tokenstat to update." : "Last seven days: \(weekValue) at list rates")
        .privacySensitive()
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT ACTIVITY").font(.system(.caption2, design: .rounded, weight: .semibold)).foregroundStyle(muted)
            // Include quiet and locked days rather than packing active days.
            let days = usage?.days ?? []
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(days) { day in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(accent.opacity(day.locked ? 0.07 : day.level == 0 ? 0.10 : Double(min(4, max(0, day.level))) * 0.2 + 0.15))
                        .frame(height: family == .systemExtraLarge ? 28 : 15)
                        .widgetAccentable()
                }
            }
            HStack {
                Text("Last \(days.count) days").font(.caption2).foregroundStyle(muted)
                Spacer()
                Text("Less").font(.caption2).foregroundStyle(muted)
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(Double(i + 1) / 4))
                        .frame(width: 7, height: 7)
                }
                Text("More").font(.caption2).foregroundStyle(muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent activity, \(usage?.days.filter { $0.level > 0 && !$0.locked }.count ?? 0) active days")
        .privacySensitive()
    }
}

struct TokenstatLauncherWidget: Widget {
    let kind = "ai.tokenstat.launcher"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TokenstatLauncherConfiguration.self, provider: TokenstatLauncherProvider()) { entry in
            TokenstatWidgetSurface(appearance: entry.appearance) { TokenstatLauncherView(entry: entry) }
        }
        .configurationDisplayName("Open tokenstat")
        .description("Your projects and favorite screens, one tap away.")
        .supportedFamilies(Self.families)
    }
    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct TokenstatLauncherView: View {
    let entry: TokenstatWidgetEntry
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { WidgetStyle.accent(entry.tint, dark: colorScheme == .dark) }
    private var muted: Color { entry.appearance == .clean ? .primary.opacity(0.72) : .secondary }
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            #if os(iOS)
            switch family {
            case .accessoryCircular:
                TokenstatWidgetMark(size: 28, decorative: false).foregroundStyle(accent)
                    .accessibilityLabel("Open tokenstat")
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    TokenstatWidgetMark(size: 24).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("tokenstat").font(.caption)
                        Text(entry.favorite?.name ?? entry.screen.title).font(.headline).lineLimit(1).privacySensitive()
                    }
                }.accessibilityLabel("Open \(entry.favorite?.name ?? entry.screen.title) in tokenstat").privacySensitive()
            default: card
            }
            #else
            card
            #endif
        }
        .tint(accent)
        .widgetURL(entry.destination.url)
        .containerBackground(for: .widget) {
            #if os(iOS)
            if [.accessoryCircular, .accessoryRectangular].contains(family) { AccessoryWidgetBackground() }
            else { WidgetStyle.background(entry.appearance, dark: colorScheme == .dark) }
            #else
            WidgetStyle.background(entry.appearance, dark: colorScheme == .dark)
            #endif
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
            HStack {
                Label { Text("tokenstat") } icon: { TokenstatWidgetMark(size: 14) }
                    .font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(accent).widgetAccentable()
                Spacer()
                Button(intent: RefreshTokenstatIntent()) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                }.buttonStyle(.plain).foregroundStyle(accent).widgetAccentable().accessibilityLabel("Refresh tokenstat")
            }
            if family == .systemSmall {
                // Small widgets have one system tap target. A single launcher
                // makes that behavior clear instead of drawing four buttons.
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
                    (entry.favorite == nil ? WidgetStyle.icon(for: entry.screen) : Image(systemName: "folder.fill"))
                        .font(.system(size: 30)).foregroundStyle(accent).widgetAccentable()
                    Text(entry.favorite?.name ?? entry.screen.title).font(.headline).lineLimit(2).privacySensitive()
                    Text(entry.favorite?.host ?? "Pick up your work").font(.caption).lineLimit(1).privacySensitive().foregroundStyle(muted)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    screenGrid.frame(maxWidth: .infinity)
                    if family == .systemMedium { projects.frame(maxWidth: .infinity) }
                }
                if family == .systemLarge { Divider(); projects }
                if family == .systemLarge {
                    Spacer(minLength: 0)
                    Link(destination: EcosystemRoute(screen: .workspaces).url) {
                        Label("All projects", systemImage: "arrow.up.right").font(.caption).fontWeight(.semibold)
                    }.buttonStyle(.plain).foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var screenGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(Array(([entry.screen] + EcosystemScreen.allCases.filter { $0 != entry.screen }).prefix(4)), id: \.self) { screen in
                Link(destination: EcosystemRoute(screen: screen).url) {
                    VStack(spacing: 4) {
                        WidgetStyle.icon(for: screen).font(.system(size: 16, weight: .medium))
                        Text(screen.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity).padding(.vertical, 4)
                        .foregroundStyle(accent)
                        .background(accent.opacity(renderingMode == .fullColor ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 12))
                        .widgetAccentable()
                }.buttonStyle(.plain).accessibilityLabel("Open \(screen.title) in tokenstat")
            }
        }
    }

    private var orderedProjects: [EcosystemProject] {
        guard let favorite = entry.favorite else { return entry.snapshot.projects }
        return [favorite] + entry.snapshot.projects.filter { $0.id != favorite.id }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROJECTS").font(.caption2).foregroundStyle(muted)
            if entry.snapshot.projects.isEmpty {
                Text("Open a project in tokenstat to keep it within reach.").font(.caption).foregroundStyle(muted)
            } else {
                ForEach(Array(orderedProjects.prefix(family == .systemLarge ? 4 : 2))) { project in
                    Link(destination: EcosystemRoute(screen: .workspaces, projectID: project.id, owner: entry.snapshot.owner).url) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.caption).fontWeight(.semibold).foregroundStyle(.primary)
                                Text(project.host).font(.caption2).foregroundStyle(muted)
                            }.lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain).privacySensitive()
                }
            }
        }
    }
}

@available(iOS 18.0, macOS 26.0, *)
struct TokenstatControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "tokenstat Quick Access"
    @Parameter(title: "Screen", default: .workspaces) var screen: EcosystemScreen
}

@available(iOS 18.0, macOS 26.0, *)
struct TokenstatQuickAccessControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "ai.tokenstat.quick-access", intent: TokenstatControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenTokenstatScreenIntent(target: configuration.screen)) {
                Label { Text(configuration.screen.title) } icon: { Image("tokenstat_logo") }
            }
        }
        .displayName("tokenstat Quick Access")
        #if os(macOS)
        .description("Open a tokenstat screen from Control Center.")
        #else
        .description("Open a tokenstat screen from Control Center, the Lock Screen or the Action button.")
        #endif
    }
}

#if !ECOSYSTEM_QA
@main
struct TokenstatWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenstatUsageWidget()
        TokenstatLauncherWidget()
        #if os(iOS)
        TokenstatLiveWorkWidget()
        #endif
        if #available(iOS 18.0, macOS 26.0, *) { TokenstatQuickAccessControl() }
    }
}
#endif

#Preview("Usage · Small", as: .systemSmall) { TokenstatUsageWidget() } timeline: {
    TokenstatWidgetEntry(date: Date(), snapshot: .preview)
    TokenstatWidgetEntry(date: Date(), snapshot: .empty)
}
#Preview("Usage · Medium", as: .systemMedium) { TokenstatUsageWidget() } timeline: {
    TokenstatWidgetEntry(date: Date(), snapshot: .preview)
}
#Preview("Usage · Large", as: .systemLarge) { TokenstatUsageWidget() } timeline: {
    TokenstatWidgetEntry(date: Date(), snapshot: .preview)
}
#Preview("Quick Access", as: .systemMedium) { TokenstatLauncherWidget() } timeline: {
    TokenstatWidgetEntry(date: Date(), snapshot: .preview)
}
