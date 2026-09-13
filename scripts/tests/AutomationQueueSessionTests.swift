// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationQueueDraft.swift AutomationQueueSession.swift HostScheduleClock.swift.
import Foundation

struct AutomationQueue: Codable, Sendable {
    var defaultBudgetSeconds: UInt64
    var maxConcurrent: UInt32 = 2
    var timezone: String? = nil
}

enum FixtureError: LocalizedError {
    case disconnected, refused, invalid(String)
    var errorDescription: String? {
        switch self {
        case .disconnected: "disconnected"
        case .refused: "refused"
        case let .invalid(message): message
        }
    }
}

actor FixtureQueue: AutomationQueueService {
    var queue = AutomationQueue(defaultBudgetSeconds: 10_800, maxConcurrent: 2, timezone: "America/New_York")
    var running = 1
    var sets = 0
    var loseReply = false
    var failBefore = false

    func automationQueue() async throws -> AutomationQueue { queue }

    func setAutomationQueue(
        defaultBudgetSeconds: UInt64,
        maxConcurrent: UInt32
    ) async throws -> AutomationQueue {
        if failBefore { throw FixtureError.refused }
        sets += 1
        queue = AutomationQueue(
            defaultBudgetSeconds: defaultBudgetSeconds,
            maxConcurrent: maxConcurrent,
            timezone: queue.timezone
        )
        if loseReply { throw FixtureError.disconnected }
        return queue
    }

    func runningJobCount() async throws -> Int { running }

    func setLoseReply(_ value: Bool) { loseReply = value }
    func setFailBefore(_ value: Bool) { failBefore = value }
    func seed(_ queue: AutomationQueue) { self.queue = queue }
}

@main struct AutomationQueueSessionTests {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }

        do {
            var draft = AutomationQueueDraft()
            check(draft.validation == nil, "defaults are valid")
            check(draft.budgetSeconds == 10_800, "default 180 minutes")
            check(draft.concurrent == 2, "default two at once")
            draft.noLimit = true
            check(draft.budgetSeconds == 0, "no limit is zero seconds")
            draft.noLimit = false
            draft.budgetMinutes = "0"
            check(draft.validation == "Enter a positive time limit, or choose No limit.", "zero minutes")
            draft.budgetMinutes = "abc"
            check(draft.validation != nil, "minutes must be a number")
            draft.budgetMinutes = "30"
            draft.maxConcurrent = ""
            check(draft.validation == "Jobs at once must be a whole number, or No cap.", "empty concurrent")
            draft.maxConcurrent = "33"
            check(draft.validation == "At most 32 jobs can run at once.", "host cap")
            draft.maxConcurrent = "0"
            check(draft.validation == nil, "zero concurrent is no cap")
            check(draft.concurrent == 0, "no cap value")
            let loaded = AutomationQueueDraft(
                AutomationQueue(defaultBudgetSeconds: 1800, maxConcurrent: 4)
            )
            check(loaded.budgetMinutes == "30", "minutes from seconds")
            check(loaded.maxConcurrent == "4", "concurrent from queue")
            check(
                AutomationQueueDraft.summary(budgetSeconds: 10_800, maxConcurrent: 2) == "3h per job · 2 at once",
                "preset summary"
            )
            check(
                AutomationQueueDraft.summary(budgetSeconds: 0, maxConcurrent: 0) == "No time limit · No cap",
                "uncapped summary"
            )
            check(
                AutomationQueueDraft.summary(budgetSeconds: 900, maxConcurrent: 3) == "15m per job · 3 at once",
                "fifteen minute summary"
            )
            check(
                AutomationQueueDraft.summary(budgetSeconds: 1200, maxConcurrent: 3) == "20 min per job · 3 at once",
                "custom summary"
            )
        }

        let service = FixtureQueue()
        let session = AutomationQueueSession(hostName: "Development computer", service: service)
        await session.load()
        check(session.loaded, "load finished")
        check(session.draft.budgetMinutes == "180", "loaded minutes")
        check(session.draft.maxConcurrent == "2", "loaded concurrent")
        check(session.timezone == "America/New_York", "host zone")
        check(session.runningCount == 1, "host-wide running count")
        check(session.dirty == false, "fresh load is clean")
        check(session.canSave == false, "clean cannot save")

        session.draft.maxConcurrent = "4"
        check(session.dirty, "edit is dirty")
        check(session.canSave, "valid dirty can save")
        await session.save()
        check(await service.sets == 1, "one save")
        check(session.draft.maxConcurrent == "4", "saved concurrent")
        check(session.dirty == false, "save clears dirty")
        check(session.noticeMessage == "Scheduler saved.", "saved notice")
        check(session.queue?.maxConcurrent == 4, "host queue updated")

        session.draft.budgetMinutes = "0"
        session.draft.noLimit = false
        check(session.canSave == false, "invalid cannot save")
        await session.save()
        check(await service.sets == 1, "invalid save does not reach the host")

        session.draft.noLimit = true
        session.draft.maxConcurrent = "0"
        await session.save()
        check(await service.sets == 2, "no limit save")
        check(session.queue?.defaultBudgetSeconds == 0, "no limit stored")
        check(session.queue?.maxConcurrent == 0, "no cap stored")

        session.draft.maxConcurrent = "8"
        await service.setLoseReply(true)
        await session.save()
        check(await service.sets == 3, "lost reply still reached the host")
        check(session.dirty == false, "matching re-read is a save")
        check(session.errorMessage == nil, "lost reply recovered")
        check(session.queue?.maxConcurrent == 8, "recovered concurrent")

        session.draft.maxConcurrent = "1"
        await service.setLoseReply(false)
        await service.setFailBefore(true)
        await session.save()
        check(await service.sets == 3, "refusal does not write")
        check(session.dirty, "refusal keeps the draft")
        check(session.errorMessage == "refused", "refusal is visible")
        check(session.queue?.maxConcurrent == 8, "host value unchanged")

        await service.setFailBefore(false)
        await service.seed(AutomationQueue(
            defaultBudgetSeconds: 600,
            maxConcurrent: 3,
            timezone: "America/New_York"
        ))
        check(session.dirty, "unsaved draft still dirty")
        await session.load()
        check(session.draft.maxConcurrent == "1", "dirty load keeps the draft")
        check(session.queue?.maxConcurrent == 8, "dirty load does not take a newer host value")

        session.draft = session.saved
        await session.load()
        check(session.draft.maxConcurrent == "3", "clean load takes the host")
        check(session.draft.budgetMinutes == "10", "clean load minutes")
        check(session.dirty == false, "clean load is clean")

        print("AutomationQueueSessionTests passed")
    }
}
