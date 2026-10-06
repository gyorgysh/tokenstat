// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import AppIntents
import Foundation
import CoreSpotlight

extension EcosystemScreen: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "tokenstat screen" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.home: "Home", .workspaces: "Workspaces", .insights: "Insights", .machines: "Devices", .ssh: "SSH", .account: "Account", .search: "Search"]
    }
}

struct OpenTokenstatScreenIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open tokenstat Screen"
    static var description = IntentDescription("Open Home, Workspaces, Insights or Devices in tokenstat.")
    @Parameter(title: "Screen", default: .home) var target: EcosystemScreen
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    init() {}
    init(target: EcosystemScreen) { self.target = target }

    @MainActor func perform() async throws -> some IntentResult {
        #if !TOKENSTAT_WIDGET_EXTENSION
        EcosystemNavigation.shared.open(EcosystemRoute(screen: target))
        #endif
        return .result()
    }
}

struct TokenstatProjectEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "tokenstat project"
    static var defaultQuery = TokenstatProjectQuery()
    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Device") var host: String
    var owner: String

    init(project: EcosystemProject, owner: String) {
        // Include the owner so a saved shortcut cannot resolve another account's
        // identically named project after sign-out.
        id = Data((owner + "\n" + project.id).utf8).base64EncodedString()
        self.owner = owner
        name = project.name
        host = project.host
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)", image: .init(systemName: "folder.fill"))
    }
}

struct TokenstatProjectQuery: EntityStringQuery {
    func suggestedEntities() async throws -> [TokenstatProjectEntity] { projects() }
    func entities(for identifiers: [String]) async throws -> [TokenstatProjectEntity] {
        let all = projects()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [TokenstatProjectEntity] {
        projects().filter { $0.name.localizedStandardContains(string) || $0.host.localizedStandardContains(string) }
    }
    private func projects() -> [TokenstatProjectEntity] {
        let snapshot = EcosystemSnapshotStore().read()
        guard let owner = snapshot.owner else { return [] }
        return snapshot.projects.map { TokenstatProjectEntity(project: $0, owner: owner) }
    }
}

struct OpenTokenstatProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Open tokenstat Project"
    static var description = IntentDescription("Open a project you have visited in tokenstat.")
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, macOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    @Parameter(title: "Project") var target: TokenstatProjectEntity
    @Parameter(title: "Section", default: .sessions) var section: EcosystemProjectSection
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$section) in \(\.$target)") }

    @MainActor func perform() async throws -> some IntentResult {
        try openProject(target, section: section)
        return .result()
    }
}

/// The system content-opening schema is new in the 27 SDK. Keep the regular
/// project intent above on older systems rather than raising the app's OS floor.
#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenTokenstatContentIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open tokenstat Content"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Project") var target: TokenstatProjectEntity

    @MainActor func perform() async throws -> some IntentResult {
        try openProject(target)
        return .result()
    }
}

#endif

@MainActor private func openProject(_ entity: TokenstatProjectEntity, section: EcosystemProjectSection = .sessions) throws {
    let snapshot = EcosystemSnapshotStore().read()
    guard snapshot.owner == entity.owner,
          let project = snapshot.projects.first(where: {
              TokenstatProjectEntity(project: $0, owner: entity.owner).id == entity.id
          }) else { throw EcosystemIntentError.projectUnavailable }
    #if !TOKENSTAT_WIDGET_EXTENSION
    EcosystemNavigation.shared.open(EcosystemRoute(screen: .workspaces, projectID: project.id, owner: entity.owner, section: section))
    #endif
}

struct GetTokenstatUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Get tokenstat Usage"
    static var description = IntentDescription("Read daily or weekly usage at list rates in US dollars. Refresh when available, or return cached usage with its last update time.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Period", default: .today) var period: EcosystemPeriod
    @available(iOS 26.0, macOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$period) usage") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        #if !TOKENSTAT_WIDGET_EXTENSION
        try? await EcosystemPublisher.refresh()
        #endif
        guard let usage = EcosystemSnapshotStore().read().usage,
              let value = period == .today ? usage.today()?.value : usage.weekTotal() else { throw EcosystemIntentError.usageUnavailable }
        let money = EcosystemUsage.money(value)
        let time = usage.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let scope = usage.scope
        let periodName = period == .today ? "Today's" : "The last seven days'"
        return .result(value: Double(value) / 1_000_000,
                       dialog: "\(periodName) value at list rates is \(money) for \(scope). Last updated \(time).")
    }
}

enum EcosystemIntentError: Error, CustomLocalizedStringResourceConvertible {
    case usageUnavailable, projectUnavailable, sessionChanged
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .usageUnavailable: "Open tokenstat to load today's usage, then try again."
        case .sessionChanged: "Your account changed. Refresh tokenstat and try again."
        case .projectUnavailable: "This project is no longer available. Open tokenstat and choose a project again."
        }
    }
}

#if !TOKENSTAT_WIDGET_EXTENSION
struct TokenstatAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .grape
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenTokenstatScreenIntent(),
                    phrases: ["Open \(.applicationName) \(\.$target)", "Show \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Screen", systemImageName: "square.grid.2x2")
        AppShortcut(intent: OpenTokenstatProjectIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Project", systemImageName: "folder.fill")
        AppShortcut(intent: GetTokenstatUsageIntent(),
                    phrases: ["Show my usage in \(.applicationName)", "What is my usage today in \(.applicationName)"],
                    shortTitle: "Usage", systemImageName: "dollarsign.circle")
        AppShortcut(intent: RefreshTokenstatIntent(), phrases: ["Refresh \(.applicationName)", "Update my usage in \(.applicationName)"],
                    shortTitle: "Refresh", systemImageName: "arrow.clockwise")
        AppShortcut(intent: SearchTokenstatIntent(), phrases: ["Search \(.applicationName)", "Find my work in \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetTokenstatStreakIntent(), phrases: ["What is my streak in \(.applicationName)"],
                    shortTitle: "Activity Streak", systemImageName: "flame")
    }
}

#endif

enum EcosystemPeriod: String, AppEnum {
    case today, week
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Usage period" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.today: "Today", .week: "Last 7 days"] }
}

enum EcosystemAppearance: String, AppEnum {
    case automatic, light, dark, clean, black
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Appearance" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.automatic: "Automatic", .light: "Light", .dark: "Dark", .clean: "Clean · Glass", .black: "Black"]
    }
}

enum EcosystemTint: String, AppEnum {
    case brand, teal, orange, pink, monochrome
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Accent tint" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.brand: "tokenstat", .teal: "Teal", .orange: "Orange", .pink: "Pink", .monochrome: "Monochrome"]
    }
}

struct TokenstatUsageConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Usage at a Glance"
    static var description = IntentDescription("Choose a period and full-color style. Clear and Tinted follow your Home Screen appearance. Data follows tokenstat Home.")
    @Parameter(title: "Period", default: .today) var period: EcosystemPeriod
    @Parameter(title: "Full-color style", default: .automatic) var appearance: EcosystemAppearance
    @Parameter(title: "Full-color accent", default: .brand) var tint: EcosystemTint
    static var parameterSummary: some ParameterSummary { Summary { \.$period; \.$appearance; \.$tint } }
}

struct TokenstatLauncherConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "tokenstat Quick Access"
    static var description = IntentDescription("Clear and Tinted follow your Home Screen appearance. Style and accent apply to full-color widgets.")
    @Parameter(title: "Screen", default: .workspaces) var screen: EcosystemScreen
    @Parameter(title: "Favorite project") var project: TokenstatProjectEntity?
    @Parameter(title: "Full-color style", default: .automatic) var appearance: EcosystemAppearance
    @Parameter(title: "Full-color accent", default: .brand) var tint: EcosystemTint
    static var parameterSummary: some ParameterSummary { Summary { \.$screen; \.$project; \.$appearance; \.$tint } }
}

struct RefreshTokenstatIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh tokenstat"
    static var description = IntentDescription("Fetch the latest usage and update your widgets without opening a screen.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, macOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    @MainActor func perform() async throws -> some IntentResult {
        #if !TOKENSTAT_WIDGET_EXTENSION
        try await EcosystemPublisher.refresh()
        #else
        // This intent belongs in the containing app; never report a no-op as a refresh.
        try unavailableWidgetRefresh()
        #endif
        return .result()
    }
}

struct RefreshTokenstatLimitsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh tokenstat Plan Limits"
    static var parameterSummary: some ParameterSummary { Summary("Refresh plan limits") }
    static var description = IntentDescription("Fetch shared provider allowances independently of activity-calendar access.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 26.0, macOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #if compiler(>=6.4)
    @available(iOS 27.0, macOS 27.0, *) static var allowedExecutionTargets: IntentExecutionTargets { .main }
    #endif
    @MainActor func perform() async throws -> some IntentResult {
        #if !TOKENSTAT_WIDGET_EXTENSION
        try await EcosystemPublisher.refreshLimitsOnly()
        #else
        // This intent belongs in the containing app; never report a no-op as a refresh.
        try unavailableWidgetRefresh()
        #endif
        return .result()
    }
}

private func unavailableWidgetRefresh() throws { throw EcosystemIntentError.usageUnavailable }

struct SearchTokenstatIntent: AppIntent {
    static var title: LocalizedStringResource = "Search tokenstat"
    static var openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Search term") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Search tokenstat for \(\.$query)") }
    @MainActor func perform() async throws -> some IntentResult {
        #if !TOKENSTAT_WIDGET_EXTENSION
        EcosystemNavigation.shared.open(EcosystemRoute(screen: .search, searchTerm: String(query.prefix(512))))
        #endif
        return .result()
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.search)
struct SearchTokenstatContentIntent: ShowInAppSearchResultsIntent {
    static var title: LocalizedStringResource = "Search tokenstat Content"
    static var searchScopes: [StringSearchScope] = [.general]
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    @Parameter(title: "Search criteria") var criteria: StringSearchCriteria
    @MainActor func perform() async throws -> some IntentResult {
        #if !TOKENSTAT_WIDGET_EXTENSION
        EcosystemNavigation.shared.open(EcosystemRoute(screen: .search, searchTerm: String(criteria.term.prefix(512))))
        #endif
        return .result()
    }
}
#endif

struct GetTokenstatStreakIntent: AppIntent {
    static var title: LocalizedStringResource = "Get tokenstat Activity Streak"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let usage = EcosystemSnapshotStore().read().usage else { throw EcosystemIntentError.usageUnavailable }
        let time = usage.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return .result(value: usage.streak, dialog: "Your last synced activity streak is \(usage.streak) days. Updated \(time).")
    }
}

#if !TOKENSTAT_WIDGET_EXTENSION
extension RefreshTokenstatIntent: ForegroundContinuableIntent {}
extension RefreshTokenstatLimitsIntent: ForegroundContinuableIntent {}
extension GetTokenstatUsageIntent: ForegroundContinuableIntent {}
#endif

extension EcosystemProjectSection: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Project section" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.sessions: "Terminals", .chat: "Chats", .changes: "Changes", .history: "History", .pulls: "Pull Requests",
         .todo: "Tasks", .notes: "Notes", .workflows: "Workflows", .automations: "Automations", .files: "Files", .browser: "Browser"]
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension TokenstatProjectEntity: IndexedEntity, URLRepresentableEntity {
    static var urlRepresentation: EntityURLRepresentation<Self> { "tokenstat://open/workspaces?entity=\(.id)" }
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = name
        attributes.contentDescription = "tokenstat project on \(host)"
        attributes.keywords = [name, host, "tokenstat", "project"]
        return attributes
    }
}
