#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production activity selection with old/new hosts and servers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "apps/mac/Sources/Ecosystem/LiveWorkController.swift").read_text()
start = source.index("    private func track(kind:")
end = source.index("    private func observe(", start)
track = source[start:end].replace("private func track", "func track")

fixture = r'''
import Foundation
import OSLog

enum ApplicationState { case active }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var applicationState = ApplicationState.active
}
struct ActivityAuthorizationInfo { var areActivitiesEnabled = true }
enum ActivityState { case active, stale, ended, dismissed }
enum PushType { case token }
enum DismissalPolicy { case immediate; case after(Date) }
struct ActivityContent<State> { var state: State; var staleDate: Date? }
@MainActor var storedActivities: [Any] = []
@MainActor final class Activity<Attributes> {
    var attributes: Attributes
    var content: ActivityContent<LiveWorkAttributes.ContentState>
    var activityState = ActivityState.active
    let id = UUID().uuidString
    init(attributes: Attributes, content: ActivityContent<LiveWorkAttributes.ContentState>) {
        self.attributes = attributes; self.content = content
    }
    static var activities: [Activity<Attributes>] { storedActivities.compactMap { $0 as? Activity<Attributes> } }
    static func request(attributes: Attributes, content: ActivityContent<LiveWorkAttributes.ContentState>, pushType: PushType) throws -> Activity<Attributes> {
        let activity = Activity(attributes: attributes, content: content)
        storedActivities.append(activity)
        return activity
    }
    func update(_ content: ActivityContent<LiveWorkAttributes.ContentState>) async { self.content = content }
    func end(_ content: ActivityContent<LiveWorkAttributes.ContentState>?, dismissalPolicy: DismissalPolicy) async { activityState = .ended }
}
enum UserDefaults {
    struct Store { func set(_ value: Any, forKey: String) {} }
    static let standard = Store()
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope = "owner"
}
@MainActor enum EcosystemPublisher {
    static func ownerKey(_ scope: String) -> String { scope }
    static func isAuthorizedPeer(_ peer: String) -> Bool { true }
}
@MainActor enum RemoteHostFeature {
    case workOverview, liveActivities, terminalLiveActivities
    static var protocolVersion = 35
    static var duringOverviewCheck: (() -> Void)?
    func isSupported(peer: String) async -> Bool {
        if self == .workOverview { Self.duringOverviewCheck?(); return Self.protocolVersion >= 35 }
        return true
    }
}
@MainActor final class Controller {
    var owner: String? = "owner"
    var overviewServer: (available: Bool, checkedAt: Date)?
    var overviewCache: [String: Bool] = [:]
    var generation = UUID()
    var seen: [String] = []
    var starting: Set<String> = []
    let logger = Logger(subsystem: "test", category: "test")
    func refreshOverview(peers: [String], force: Bool) async {}
    func release(_ id: String) {}
    func observe(_ activity: Activity<LiveWorkAttributes>) {}
TRACK
}
@main struct Test {
    @MainActor static func main() async {
        func controller(server: Bool?, version: Int) -> Controller {
            storedActivities = []
            RemoteHostFeature.protocolVersion = version
            RemoteHostFeature.duringOverviewCheck = nil
            let controller = Controller()
            if let server { controller.overviewServer = (server, .now) }
            controller.seen = ["owner:overview:\(Int(Date().timeIntervalSince1970 / (8 * 3600)))"]
            return controller
        }
        func track(_ controller: Controller) async {
            await controller.track(kind: .terminal, id: "terminal", revision: "0", running: true,
                peer: "peer", projectID: "project", projectName: "Project", startedAt: .now,
                phase: .working, feature: .terminalLiveActivities, mayStart: { true })
        }
        let oldHost = controller(server: true, version: 32)
        await track(oldHost)
        assert(storedActivities.count == 1, "an overview dismissal must not suppress an older host's activity")
        let oldServer = controller(server: false, version: 35)
        await track(oldServer)
        assert(storedActivities.count == 1, "an older website must retain the existing integration")
        let offlineServer = controller(server: nil, version: 35)
        await track(offlineServer)
        assert(storedActivities.count == 1, "an unknown server must not discard the fallback")
        let modern = controller(server: true, version: 35)
        await track(modern)
        assert(storedActivities.isEmpty, "a modern host must respect the overview dismissal")
        let cached = controller(server: true, version: 35)
        cached.overviewCache["peer"] = true
        await track(cached)
        assert(storedActivities.isEmpty, "a combined overview must not create duplicate individual cards")
        let switched = controller(server: true, version: 32)
        RemoteHostFeature.duringOverviewCheck = { switched.owner = "other"; switched.generation = UUID() }
        await track(switched)
        assert(storedActivities.isEmpty, "an account switch during capability checks must not create old-account work")
        print("Live Activity host/server compatibility passed")
    }
}
'''.replace("TRACK", track)

with tempfile.TemporaryDirectory(prefix="tokenstat-live-work-") as directory:
    work = Path(directory)
    (work / "Fixture.swift").write_text(fixture)
    sources = root / "apps/mac/Sources/Ecosystem"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(work / "Fixture.swift"),
                    str(sources / "LiveWorkActivity.swift"), str(sources / "EcosystemSnapshot.swift"),
                    "-o", str(work / "test")], check=True)
    subprocess.run([str(work / "test")], check=True)
