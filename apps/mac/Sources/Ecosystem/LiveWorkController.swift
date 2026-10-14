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
    private var overviewRefresh: Task<Void, Never>?
    private var overviewObservedAt = Date.distantPast
    private var overviewCache: [String: (value: LiveWorkHostOverview, observedAt: Date)] = [:]
    private var overviewNames: [String: String] = [:]
    private var overviewCandidates: [String] = []
    private var overviewServer: (available: Bool, checkedAt: Date)?
    private let logger = Logger(subsystem: "ai.tokenstat.tokenstat", category: "LiveActivities")

    func verify(owner: String?) {
        if self.owner != owner {
            generation = UUID()
            overviewRefresh?.cancel(); overviewRefresh = nil
            overviewCache.removeAll(); overviewObservedAt = .distantPast
            overviewNames.removeAll()
            overviewCandidates.removeAll(); overviewServer = nil
        }
        self.owner = owner
        for activity in Activity<LiveWorkAttributes>.activities {
            let peers = activity.attributes.overviewPeers ?? [activity.attributes.peer]
            if activity.attributes.owner != owner || !peers.allSatisfy(EcosystemPublisher.isAuthorizedPeer) {
                if activity.attributes.owner == owner, activity.attributes.overviewPeers != nil,
                   activity.activityState == .active || activity.activityState == .stale, let owner {
                    seen.removeAll { $0.hasPrefix("\(owner):overview:") }
                    UserDefaults.standard.set(seen, forKey: "liveWork.seen.v1")
                }
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                release(activity.id)
            } else { observe(activity) }
        }
        if owner == nil {
            overviewRefresh?.cancel(); overviewRefresh = nil
            overviewCache.removeAll(); overviewObservedAt = .distantPast
            for id in Set(registeredTokens.keys).union(tokenTasks.keys).union(registrationTasks.keys) { release(id) }
            seen.removeAll(); UserDefaults.standard.removeObject(forKey: "liveWork.seen.v1")
        }
    }

    /// One foreground-created activity across every reachable authorized
    /// computer. Each host continues publishing when this app is suspended.
    func refreshOverview(peers: [String], names: [String: String] = [:], force: Bool = false) async {
        guard owner != nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active,
              overviewRefresh == nil, force || Date().timeIntervalSince(overviewObservedAt) >= 15 else { return }
        let candidates = Array(Set(peers.filter(EcosystemPublisher.isAuthorizedPeer)).sorted().prefix(16))
        guard !candidates.isEmpty else { return }
        overviewCandidates = candidates
        overviewObservedAt = .now
        if !names.isEmpty { overviewNames = names }
        overviewNames = overviewNames.filter { candidates.contains($0.key) }
        let observed = generation
        let task = Task { [self] in
            let available = await serverSupportsOverview(generation: observed)
            guard generation == observed, !Task.isCancelled else { return }
            if !available {
                // An older website still supports the individual-activity
                // endpoints. Do not trade that background path for a card
                // the server cannot update.
                let current = Activity<LiveWorkAttributes>.activities.filter {
                    $0.attributes.owner == owner && $0.attributes.overviewPeers != nil
                        && ($0.activityState == .active || $0.activityState == .stale)
                }
                for activity in current {
                    await activity.end(nil, dismissalPolicy: .immediate); release(activity.id)
                }
                guard generation == observed, !Task.isCancelled else { return }
                if !current.isEmpty, let owner {
                    seen.removeAll { $0.hasPrefix("\(owner):overview:") }
                    UserDefaults.standard.set(seen, forKey: "liveWork.seen.v1")
                }
                overviewCache.removeAll()
                return
            }
            let answers = await withTaskGroup(of: (String, LiveWorkHostOverview?).self) { group in
                for peer in candidates {
                    group.addTask {
                        guard await RemoteHostFeature.workOverview.isSupported(peer: peer) else { return (peer, nil) }
                        return (peer, try? await Bridge.workOverview(peer: peer))
                    }
                }
                var result: [(String, LiveWorkHostOverview?)] = []
                for await answer in group { result.append(answer) }
                return result
            }
            guard generation == observed, !Task.isCancelled else { return }
            overviewCache = overviewCache.filter { candidates.contains($0.key) }
            for (peer, value) in answers {
                if let value { overviewCache[peer] = (value, .now) }
            }
            overviewObservedAt = .now
            await updateOverview(generation: observed)
        }
        overviewRefresh = task
        await task.value
        if generation == observed { overviewRefresh = nil }
    }

    private func serverSupportsOverview(generation observed: UUID) async -> Bool {
        if let cached = overviewServer, Date().timeIntervalSince(cached.checkedAt) < 60 { return cached.available }
        if let available = try? await Bridge.liveOverviewSupported(), generation == observed, !Task.isCancelled {
            overviewServer = (available, .now)
            return available
        }
        return overviewServer?.available ?? false
    }

    private func updateOverview(generation observed: UUID) async {
        guard let owner, owner == EcosystemPublisher.ownerKey(WorkSessionContext.shared.scope),
              generation == observed, !Task.isCancelled else { return }
        let activities = Activity<LiveWorkAttributes>.activities.filter {
            $0.attributes.owner == owner && $0.attributes.overviewPeers != nil
                && ($0.activityState == .active || $0.activityState == .stale)
        }
        // Restore the subscription set after relaunch. An unreachable computer
        // must remain offline rather than disappear from the totals.
        let restored = activities.flatMap { $0.attributes.overviewPeers ?? [] }.filter { overviewCandidates.contains($0) }
        let peers = Set(overviewCache.keys).union(restored).filter(EcosystemPublisher.isAuthorizedPeer).sorted()
        guard let first = peers.first else { return }
        let fresh = peers.compactMap { peer -> LiveWorkHostOverview? in
            guard let cached = overviewCache[peer], Date().timeIntervalSince(cached.observedAt) <= 180 else { return nil }
            return cached.value
        }
        let summary = LiveWorkOverview.merged(fresh.map(\.summary), offline: peers.count - fresh.count)
        let state = LiveWorkAttributes.ContentState(phase: summary.phase, updatedAt: Date().timeIntervalSince1970, overview: summary)
        if let current = activities.first(where: { $0.attributes.overviewPeers == peers && ($0.activityState == .active || $0.activityState == .stale) }) {
            await current.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)))
            return
        }
        // Dismissal applies to the overview, including changes to its host
        // set. ActivityKit limits a Live Activity to eight hours.
        let revision = String(Int(Date().timeIntervalSince1970 / (8 * 3600)))
        let identity = "\(owner):overview:\(revision)"
        guard summary.total > 0, !seen.contains(identity) || !activities.isEmpty,
              UIApplication.shared.applicationState == .active else { return }
        for old in activities {
            await old.end(nil, dismissalPolicy: .immediate); release(old.id)
        }
        guard generation == observed, !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
        var hints: [String: LiveWorkAttributes.Hint] = [:]
        for peer in peers {
            for hint in overviewCache[peer]?.value.hints ?? [] where summary.items.contains(where: { $0.key == hint.key }) {
                let computer = overviewNames[peer] ?? "Computer"
                hints[hint.key] = .init(name: String(hint.name.prefix(30)) + " · " + String(computer.prefix(16)),
                    route: LiveWorkAttributes.destination(kind: hint.kind, id: hint.id, peer: peer, workspaceID: hint.workspaceID, owner: owner).url.absoluteString)
            }
        }
        let attributes = LiveWorkAttributes(startedAt: state.updatedAt, owner: owner, peer: first,
            key: LiveWorkAttributes.overviewKey, revision: "0", projectName: "All your work",
            route: EcosystemRoute(screen: .workspaces, owner: owner).url.absoluteString,
            overviewPeers: peers, overviewHints: hints)
        // Keep attributes and state comfortably inside Apple's combined 4 KB
        // budget. Long routes can still use the card's workspace overview.
        var bounded = attributes
        while let data = try? JSONEncoder().encode(bounded), let content = try? JSONEncoder().encode(state),
              data.count + content.count > 3800, let key = bounded.overviewHints?.keys.sorted().last {
            bounded.overviewHints?.removeValue(forKey: key)
        }
        do {
            let activity = try Activity.request(attributes: bounded,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(180)), pushType: .token)
            for old in Activity<LiveWorkAttributes>.activities where old.id != activity.id && old.attributes.owner == owner
                && old.attributes.overviewPeers == nil && peers.contains(old.attributes.peer) {
                await old.end(nil, dismissalPolicy: .immediate); release(old.id)
            }
            guard generation == observed, owner == self.owner, !Task.isCancelled else {
                await activity.end(nil, dismissalPolicy: .immediate); release(activity.id); return
            }
            seen.append(identity); seen = Array(seen.suffix(100))
            UserDefaults.standard.set(seen, forKey: "liveWork.seen.v1")
            observe(activity)
        } catch {
            logger.error("Could not start work overview: \(String(describing: error), privacy: .public)")
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
        // A turn can start from a chat or terminal while the workspace list is
        // off-screen. Seed the same overview rather than starting a second card.
        let hasOverview = Activity<LiveWorkAttributes>.activities.contains(where: {
            $0.attributes.owner == owner && $0.attributes.overviewPeers?.contains(peer) == true
                && ($0.activityState == .active || $0.activityState == .stale)
        })
        if running, !hasOverview || Date().timeIntervalSince(overviewServer?.checkedAt ?? .distantPast) >= 60 {
            let restored = Activity<LiveWorkAttributes>.activities.filter { $0.attributes.owner == owner }
                .flatMap { $0.attributes.overviewPeers ?? [] }
            await refreshOverview(peers: Array(Set(overviewCache.keys).union(restored).union([peer])),
                force: overviewCache[peer] != nil)
            guard owner == self.owner, owner == EcosystemPublisher.ownerKey(WorkSessionContext.shared.scope),
                  EcosystemPublisher.isAuthorizedPeer(peer), !Task.isCancelled else { return }
        }
        if Activity<LiveWorkAttributes>.activities.contains(where: {
            $0.attributes.owner == owner && $0.attributes.overviewPeers?.contains(peer) == true
                && ($0.activityState == .active || $0.activityState == .stale)
        }) { return }
        // A modern host uses the overview even when the person dismissed it.
        // Falling back here would recreate the same work as a single-run card.
        if overviewServer?.available == true && overviewCache[peer] != nil { return }
        let overviewIdentity = "\(owner):overview:\(Int(Date().timeIntervalSince1970 / (8 * 3600)))"
        if overviewServer?.available == true, seen.contains(overviewIdentity) {
            let observed = generation
            // Dismissing the overview does not dismiss work on older hosts,
            // which still need the individual-activity integration.
            if await RemoteHostFeature.workOverview.isSupported(peer: peer) { return }
            guard generation == observed, owner == self.owner, !Task.isCancelled,
                  EcosystemPublisher.isAuthorizedPeer(peer) else { return }
        }
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
                    if let peers = activity.attributes.overviewPeers {
                        try await Bridge.liveOverviewRegister(token: hex, peers: peers, environment: PushRegistrar.environment)
                    } else {
                        try await Bridge.liveActivityRegister(token: hex, peer: activity.attributes.peer,
                            key: activity.attributes.key, revision: activity.attributes.revision, environment: PushRegistrar.environment)
                    }
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
