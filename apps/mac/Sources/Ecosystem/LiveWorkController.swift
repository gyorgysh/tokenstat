// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(iOS)
import ActivityKit
import Foundation
import OSLog
import UIKit

@MainActor
final class LiveWorkController {
    static let shared = LiveWorkController()
    private var owner: String?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var stateTasks: [String: Task<Void, Never>] = [:]
    private var registrationTasks: [String: Task<Void, Never>] = [:]
    private var registrationTokens: [String: String] = [:]
    private var registrationJobs: [String: UUID] = [:]
    private var starting = Set<String>()
    private var registeredTokens: [String: String] = [:]
    private var seen = UserDefaults.standard.stringArray(forKey: "liveWork.seen.v1") ?? []
    private var generation = UUID()
    private let logger = Logger(subsystem: "ai.tokenstat.tokenstat", category: "LiveActivities")

    func verify(owner: String?) {
        if self.owner != owner { generation = UUID() }
        self.owner = owner
        for activity in Activity<LiveWorkAttributes>.activities {
            if activity.attributes.owner != owner || !EcosystemPublisher.isAuthorizedPeer(activity.attributes.peer) {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                release(activity.id)
            } else { observe(activity) }
        }
        if owner == nil {
            for id in Set(registeredTokens.keys).union(tokenTasks.keys).union(registrationTasks.keys) { release(id) }
            seen.removeAll(); UserDefaults.standard.removeObject(forKey: "liveWork.seen.v1")
        }
    }

    func track(chat: ChatConversation, peer: String, projectID: String, projectName: String,
               startedAt: Date, phase: LiveWorkPhase, mayStart: () -> Bool) async {
        guard let revision = chat.runRevision ?? chat.sendRevision else { return }
        await track(kind: .chat, id: chat.id, revision: String(revision), running: chat.running,
                    peer: peer, projectID: projectID, projectName: projectName,
                    startedAt: startedAt, phase: phase, feature: .liveActivities, mayStart: mayStart)
    }

    func track(terminal: PtySessionInfo, peer: String, projectName: String, observedAt: Date, stopped: Bool = false,
               mayStart: () -> Bool) async {
        guard let workspaceID = terminal.workspaceID, !workspaceID.isEmpty, terminal.hidden != true else { return }
        // The process can die just before its wait thread publishes the exit
        // code. Do not end a successful run as Stopped during that gap.
        guard terminal.alive || terminal.exitCode != nil || stopped else { return }
        let startedAt = terminal.startedAtMs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil } ?? observedAt
        await track(kind: .terminal, id: terminal.id, revision: "0", running: terminal.alive,
                    peer: peer, projectID: workspaceID, projectName: projectName, startedAt: startedAt,
                    phase: stopped ? .stopped : .terminal(alive: terminal.alive, exitCode: terminal.exitCode,
                                     activity: terminal.activity, attention: terminal.attention), feature: .terminalLiveActivities, mayStart: mayStart)
    }

    private func track(kind: LiveWorkKind, id: String, revision: String, running: Bool,
                       peer: String, projectID: String, projectName: String, startedAt: Date,
                       phase: LiveWorkPhase, feature: RemoteHostFeature, mayStart: () -> Bool) async {
        guard let owner, owner == EcosystemPublisher.ownerKey(WorkSessionContext.shared.scope),
              EcosystemPublisher.isAuthorizedPeer(peer),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let key = LiveWorkAttributes.key(kind: kind, id: id)
        let identity = "\(owner):\(peer):\(key):\(revision)"
        let current = Activity<LiveWorkAttributes>.activities.first {
            $0.attributes.owner == owner && $0.attributes.peer == peer && $0.attributes.key == key && $0.attributes.revision == revision
        }
        let state = LiveWorkAttributes.ContentState(phase: phase, updatedAt: Date().timeIntervalSince1970)
        if let current {
            guard current.activityState == .active || current.activityState == .stale else { return }
            if phase.finished {
                await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60)))
                release(current.id)
            } else if current.content.state.phase != phase || current.activityState == .stale || state.updatedAt - current.content.state.updatedAt >= 60 {
                await current.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)))
            }
            return
        }
        guard running, mayStart(), !phase.finished, !seen.contains(identity), UIApplication.shared.applicationState == .active else { return }
        guard starting.insert(identity).inserted else { return }
        defer { starting.remove(identity) }
        let observed = generation
        guard await feature.isSupported(peer: peer), generation == observed,
              owner == self.owner, !Task.isCancelled, mayStart(), !seen.contains(identity),
              UIApplication.shared.applicationState == .active,
              EcosystemPublisher.isAuthorizedPeer(peer) else { return }
        // One foreground-observed run per activity; a user's dismissal is respected.
        for old in Activity<LiveWorkAttributes>.activities where old.attributes.owner == owner && old.attributes.peer == peer && old.attributes.key == key {
            await old.end(nil, dismissalPolicy: .immediate); release(old.id)
        }
        guard generation == observed, !Task.isCancelled, owner == self.owner,
              mayStart(), EcosystemPublisher.isAuthorizedPeer(peer), UIApplication.shared.applicationState == .active else { return }
        // A computer's clock can be ahead of the phone; elapsed time must never start in the future.
        let start = min(Date().timeIntervalSince1970, max(0, startedAt.timeIntervalSince1970))
        let attributes = LiveWorkAttributes(startedAt: start, owner: owner, peer: peer, key: key, revision: revision,
            projectName: String(projectName.prefix(100)),
            route: LiveWorkAttributes.destination(kind: kind, id: id, peer: peer, workspaceID: projectID, owner: owner).url.absoluteString)
        do {
            let activity = try Activity.request(attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)), pushType: .token)
            seen.append(identity)
            seen = Array(seen.suffix(100))
            UserDefaults.standard.set(seen, forKey: "liveWork.seen.v1")
            observe(activity)
        } catch {
            // Preserve the work while making device-only ActivityKit failures diagnosable.
            logger.error("Could not start Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func observe(_ activity: Activity<LiveWorkAttributes>) {
        guard tokenTasks[activity.id] == nil, activity.activityState == .active || activity.activityState == .stale else { return }
        let observed = generation
        tokenTasks[activity.id] = Task {
            if let token = activity.pushToken { scheduleRegistration(token, for: activity, generation: observed) }
            for await token in activity.pushTokenUpdates {
                guard generation == observed, !Task.isCancelled else { return }
                scheduleRegistration(token, for: activity, generation: observed)
            }
        }
        stateTasks[activity.id] = Task {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed { release(activity.id); return }
            }
        }
    }
    private func scheduleRegistration(_ token: Data, for activity: Activity<LiveWorkAttributes>, generation observed: UUID) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard registeredTokens[activity.id] != hex, registrationTokens[activity.id] != hex else { return }
        registrationTasks.removeValue(forKey: activity.id)?.cancel()
        let job = UUID()
        registrationJobs[activity.id] = job
        registrationTokens[activity.id] = hex
        registrationTasks[activity.id] = Task {
            defer {
                if registrationJobs[activity.id] == job {
                    registrationTokens.removeValue(forKey: activity.id)
                    registrationJobs.removeValue(forKey: activity.id)
                    registrationTasks.removeValue(forKey: activity.id)
                }
            }
            var attempt = 0
            while generation == observed, owner == activity.attributes.owner,
                  EcosystemPublisher.isAuthorizedPeer(activity.attributes.peer), !Task.isCancelled,
                  activity.activityState == .active || activity.activityState == .stale {
                do {
                    try await Bridge.liveActivityRegister(token: hex, peer: activity.attributes.peer,
                        key: activity.attributes.key, revision: activity.attributes.revision, environment: PushRegistrar.environment)
                    guard generation == observed, !Task.isCancelled,
                          registrationJobs[activity.id] == job,
                          activity.activityState == .active || activity.activityState == .stale else {
                        try? await Bridge.liveActivityUnregister(token: hex); return
                    }
                    let previous = registeredTokens.updateValue(hex, forKey: activity.id)
                    if let previous, previous != hex { try? await Bridge.liveActivityUnregister(token: previous) }
                    return
                } catch {
                    if Task.isCancelled { return }
                    // Registration must recover after an offline launch without waiting for token rotation.
                    let delays = [1, 2, 5, 15, 30, 60]
                    let delay = delays[min(attempt, delays.count - 1)]
                    attempt = min(attempt + 1, delays.count - 1)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }
    private func release(_ id: String) {
        registrationTokens.removeValue(forKey: id)
        registrationJobs.removeValue(forKey: id)
        registrationTasks.removeValue(forKey: id)?.cancel()
        tokenTasks.removeValue(forKey: id)?.cancel()
        stateTasks.removeValue(forKey: id)?.cancel()
        if let token = registeredTokens.removeValue(forKey: id) {
            Task { try? await Bridge.liveActivityUnregister(token: token) }
        }
    }
}
#endif
