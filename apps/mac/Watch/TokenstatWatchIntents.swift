// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import AppIntents
import Foundation

enum WatchScreen: String, AppEnum {
    case usage, projects, requests
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "tokenstat Watch screen" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.usage: "Usage", .projects: "Projects", .requests: "Requests"] }
}

struct OpenTokenstatWatchIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open tokenstat on Watch"
    @Parameter(title: "Screen", default: .usage) var target: WatchScreen
    @MainActor func perform() async throws -> some IntentResult {
        TokenstatWatchModel.shared.destination = target
        return .result()
    }
}

struct GetTokenstatWatchUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Get tokenstat Watch Usage"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let usage = EcosystemSnapshotStore().read().usage, let today = usage.today() else {
            throw WatchIntentError.syncRequired
        }
        let amount = EcosystemUsage.money(today.value)
        let time = usage.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return .result(value: Double(today.value) / 1_000_000,
                       dialog: "Today's value at list rates is \(amount). Last synced from your iPhone \(time).")
    }
}

struct TokenstatWatchProject: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "tokenstat Watch project" }
    static var defaultQuery = TokenstatWatchProjectQuery()
    var id: String
    var name: String
    var host: String
    var owner: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(host)") }
}

struct TokenstatWatchProjectQuery: EntityStringQuery {
    func suggestedEntities() async throws -> [TokenstatWatchProject] { projects() }
    func entities(for identifiers: [String]) async throws -> [TokenstatWatchProject] {
        let all = projects()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [TokenstatWatchProject] {
        projects().filter { $0.name.localizedStandardContains(string) || $0.host.localizedStandardContains(string) }
    }
    private func projects() -> [TokenstatWatchProject] {
        let snapshot = EcosystemSnapshotStore().read()
        guard let owner = snapshot.owner else { return [] }
        return snapshot.projects.map { .init(id: Data((owner + "\n" + $0.id).utf8).base64EncodedString(), name: $0.name, host: $0.host, owner: owner) }
    }
}

struct OpenTokenstatWatchProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Open tokenstat Watch Project"
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(watchOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Project") var project: TokenstatWatchProject
    @MainActor func perform() async throws -> some IntentResult {
        let model = TokenstatWatchModel.shared
        guard let owner = model.snapshot.owner, owner == project.owner,
              let resolved = model.snapshot.projects.first(where: {
                  Data((owner + "\n" + $0.id).utf8).base64EncodedString() == project.id
              }) else { throw WatchIntentError.syncRequired }
        model.destination = .projects
        model.projectID = resolved.id
        return .result()
    }
}

enum WatchIntentError: Error, CustomLocalizedStringResourceConvertible {
    case syncRequired
    var localizedStringResource: LocalizedStringResource { "Open tokenstat on your iPhone to sync, then try again." }
}

struct TokenstatWatchShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .grape }
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenTokenstatWatchIntent(), phrases: ["Open \(.applicationName) \(\.$target) on my watch"],
                    shortTitle: "Open Screen", systemImageName: "chart.bar.xaxis")
        AppShortcut(intent: GetTokenstatWatchUsageIntent(), phrases: ["Show my usage in \(.applicationName) on my watch"],
                    shortTitle: "Today's Usage", systemImageName: "chart.bar")
        AppShortcut(intent: OpenTokenstatWatchProjectIntent(), phrases: ["Open \(\.$project) in \(.applicationName) on my watch"],
                    shortTitle: "Open Project", systemImageName: "folder")
    }
}
