// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

protocol AutomationQueueService: Sendable {
    func automationQueue() async throws -> AutomationQueue
    func setAutomationQueue(defaultBudgetSeconds: UInt64, maxConcurrent: UInt32) async throws -> AutomationQueue
    func runningJobCount() async throws -> Int
}

/// Host-wide scheduler defaults for one connected computer.
///
/// The library is often one folder. These fields are not. A dirty draft stays
/// on this computer until Save, and a lost reply is checked by reading the
/// queue back rather than sending the same change twice on a guess.
@MainActor
@Observable
final class AutomationQueueSession {
    static let didChange = Notification.Name("AutomationQueueSession.didChange")

    let hostName: String
    var draft: AutomationQueueDraft
    private(set) var saved: AutomationQueueDraft
    private(set) var queue: AutomationQueue?
    private(set) var timezone: String = ""
    private(set) var runningCount = 0
    private(set) var loaded = false
    private(set) var working = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private let service: any AutomationQueueService
    private var submitted: (budget: UInt64, concurrent: UInt32)?

    init(hostName: String, service: any AutomationQueueService) {
        self.hostName = hostName
        self.service = service
        let initial = AutomationQueueDraft()
        draft = initial
        saved = initial
    }

    var dirty: Bool { draft != saved }
    var canSave: Bool { loaded && queue != nil && !working && draft.validation == nil && dirty }

    func load() async {
        if loaded && dirty { return }
        do {
            async let fresh = service.automationQueue()
            async let running = service.runningJobCount()
            let queue = try await fresh
            runningCount = (try? await running) ?? runningCount
            apply(queue, asSaved: true)
            errorMessage = nil
            noticeMessage = nil
            loaded = true
        } catch {
            loaded = true
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        guard canSave, let budget = draft.budgetSeconds, let count = draft.concurrent else { return }
        working = true
        defer { working = false }
        errorMessage = nil
        noticeMessage = nil
        submitted = (budget, count)
        do {
            apply(try await service.setAutomationQueue(defaultBudgetSeconds: budget, maxConcurrent: count), asSaved: true)
            errorMessage = nil
            noticeMessage = "Scheduler saved."
            submitted = nil
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        } catch {
            if await recoveredSubmitted() {
                errorMessage = nil
                noticeMessage = "Scheduler saved."
                submitted = nil
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recoveredSubmitted() async -> Bool {
        guard let submitted else { return false }
        guard let current = try? await service.automationQueue() else { return false }
        guard current.defaultBudgetSeconds == submitted.budget,
              current.maxConcurrent == submitted.concurrent
        else { return false }
        runningCount = (try? await service.runningJobCount()) ?? runningCount
        apply(current, asSaved: true)
        return true
    }

    private func apply(_ queue: AutomationQueue, asSaved: Bool) {
        self.queue = queue
        let next = AutomationQueueDraft(queue)
        draft = next
        if asSaved { saved = next }
        if let timezone = HostScheduleClock.resolved(queue.timezone) {
            self.timezone = timezone
        }
    }
}

@MainActor
enum AutomationQueueSessions {
    private static var sessions: [String: AutomationQueueSession] = [:]

    static func session(
        peer: String,
        hostName: String,
        service: any AutomationQueueService
    ) -> AutomationQueueSession {
        if let existing = sessions[peer] { return existing }
        let created = AutomationQueueSession(hostName: hostName, service: service)
        sessions[peer] = created
        return created
    }

    static func reset() {
        sessions.removeAll()
    }
}
