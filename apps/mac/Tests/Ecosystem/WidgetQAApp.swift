// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Isolated simulator fixture. This file is excluded from the shipping targets.
import SwiftUI
import WidgetKit
#if os(iOS)
import WatchConnectivity
import ActivityKit
#endif

#if os(macOS)
@MainActor final class EcosystemWatchSync {
    static let shared = EcosystemWatchSync()
    func publish(_ snapshot: EcosystemSnapshot) {}
    func activate() {}
}
#endif

@MainActor enum EcosystemApprovalService {
    private static var cached: [EcosystemApproval] = []
    static func clear() { cached = [] }
    static func requests(for owner: String?) -> [EcosystemApproval] { owner == "preview" ? cached : [] }
    static func seed() {
        cached = [.init(requestID: UUID().uuidString, conversationID: "qa-chat", peer: "qa-host", host: "MacBook",
                        verb: "shell", preview: "git status --short", fingerprint: String(repeating: "a", count: 64),
                        expiresAt: Date().addingTimeInterval(300), alwaysAllowScope: "git status")]
    }
    static func load(owner: String?) async throws -> [EcosystemApproval] { requests(for: owner) }
    static func resolve(_ approval: EcosystemApproval, owner: String, choice: String) async throws {
        guard approval.allows(choice), owner == "preview", cached.contains(approval) else { throw EcosystemIntentError.projectUnavailable }
        cached.removeAll { $0.id == approval.id }
    }
}

@MainActor enum EcosystemPublisher {
    static var lease: EcosystemPublicationLease? { .init(owner: "preview", generation: UUID()) }
    static func refreshLimitsOnly() async throws {
        try await refresh()
    }
    static func refresh() async throws {
        try await Task.sleep(for: .milliseconds(200))
        var snapshot = EcosystemSnapshotStore().read()
        if snapshot.owner == nil { snapshot = .preview }
        snapshot.usage?.updatedAt = Date()
        if let index = snapshot.usage?.days.indices.last { snapshot.usage?.days[index].value += 1_000_000 }
        snapshot.refreshFailed = nil
        _ = EcosystemSnapshotStore().write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        EcosystemWatchSync.shared.publish(snapshot)
    }
}

@main struct WidgetQAApp: App {
    @State private var navigation = EcosystemNavigation.shared
    @State private var status = "Widget QA"
    init() {
        _ = EcosystemSnapshotStore().write(.preview)
        EcosystemWatchSync.shared.publish(.preview)
        Task.detached(priority: .utility) { TokenstatAppShortcuts.updateAppShortcutParameters() }
        WidgetCenter.shared.reloadAllTimelines()
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Text(status).accessibilityIdentifier("qa.destination")
                    Button("Seed activity") { seed(.preview) }
                    Button("Seed approval request") { EcosystemApprovalService.seed(); seed(.preview) }
                    Button("Empty account") { seed(.empty) }
                    Button("Large value and long project") {
                        var snapshot = EcosystemSnapshot.preview
                        let index = snapshot.usage!.days.count - 1
                        snapshot.usage?.days[index].value = 1_234_567_890_000
                        snapshot.projects[0].name = "A project with a very long descriptive name"
                        seed(snapshot)
                    }
                    Button("Offline snapshot") { var snapshot = EcosystemSnapshot.preview; snapshot.refreshFailed = true; seed(snapshot) }
                    Button("Refresh") { Task { try? await EcosystemPublisher.refresh(); status = "Refreshed" } }
                    Button("Run voice navigation") { Task {
                        let intent = OpenTokenstatScreenIntent(target: .ssh)
                        _ = try? await intent.perform()
                    } }
                    Button("Run voice search") { Task {
                        let intent = SearchTokenstatIntent(); intent.query = "tokenstat"; _ = try? await intent.perform()
                    } }
                    Button("Run voice usage") { Task {
                        let intent = GetTokenstatUsageIntent(); intent.period = .week
                        do { let result = try await intent.perform(); status = "Week USD \(result.value ?? 0)" }
                        catch { status = "Usage failed: \(error.localizedDescription)" }
                    } }
                    #if os(iOS)
                    Button("Watch sync status") {
                        EcosystemWatchSync.shared.activate()
                        let session = WCSession.default
                        status = "Watch supported \(WCSession.isSupported()), paired \(session.isPaired), installed \(session.isWatchAppInstalled), reachable \(session.isReachable), activated \(session.activationState.rawValue)"
                    }
                    #endif
                }.navigationTitle("tokenstat Widget QA")
            }
            .task {
                EcosystemWatchSync.shared.activate()
                #if os(iOS)
                if ProcessInfo.processInfo.arguments.contains("--live-work-preview") {
                    try? await Task.sleep(for: .seconds(2))
                    let attrs = LiveWorkAttributes(startedAt: Date().addingTimeInterval(-147).timeIntervalSince1970,
                        owner: "preview", peer: "preview", key: "preview", revision: "1", projectName: "Studio", route: "tokenstat://open/workspaces")
                    do {
                        let activity = try Activity.request(attributes: attrs,
                            content: ActivityContent(state: LiveWorkAttributes.ContentState(phase: .working, updatedAt: Date().timeIntervalSince1970), staleDate: Date().addingTimeInterval(180)), pushType: nil)
                        status = "Live Activity \(activity.activityState)"
                    } catch { status = "Live Activity failed: \(error.localizedDescription)" }
                }
                #endif
                if ProcessInfo.processInfo.arguments.contains("--render-widget-gallery") {
                    WidgetQARenderer.export()
                    await Task.yield()
                    WidgetQARenderer.export()
                }
            }
            .onOpenURL { url in navigation.receive(url) }
            .onContinueUserActivity("ai.tokenstat.open") { activity in
                if let value = activity.userInfo?["url"] as? String, let url = URL(string: value) { navigation.receive(url) }
            }
            .onChange(of: navigation.pending) { _, route in
                if let route { status = "Opened \(route.screen.title) \(route.projectID ?? route.searchTerm ?? "")"; navigation.pending = nil }
            }
        }
    }
    private func seed(_ snapshot: EcosystemSnapshot) {
        _ = EcosystemSnapshotStore().write(snapshot)
        EcosystemWatchSync.shared.publish(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        status = snapshot.owner == nil ? "Account cleared" : "Seeded activity"
    }
}
