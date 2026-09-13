// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutoCommitJob.swift AutoCommitSession.swift WorkbenchDraftFile.swift
// OriginalFileCoordination.swift WorkReference.swift.
import Foundation

enum ScheduleKind: String, Codable, Sendable, Hashable {
    case once, interval, daily, weekdays, weekly, custom
}

struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    var everySeconds: UInt64 = 0
    var hour: Int = 9
    var minute: Int = 0
    var weekday: Int = 0
    var weekdays: Int = 0
}

struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var backend: String
    var model: String? = nil
    var effort: String? = nil
    var workspaceID: String
    var prompt: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
    var enabled: Bool
    var lastRunAtMs: Int64? = nil
    var nextRunAtMs: Int64? = nil
    var lastRunID: String? = nil
    var revision: UInt64 = 0
}

struct AgentBackend: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var command: String = ""
    var models: [String] = []
    var efforts: [String] = []
}

struct RunRecord: Codable, Sendable, Identifiable {
    var id: String
    var jobId: String
    var name: String = "Auto commit"
    var backend: String = "codex"
    var workspaceID: String = "project"
    var startedAtMs: Int64 = 1
    var status: String
    var isRunning: Bool { ["starting", "queued", "running", "stopping"].contains(status) }
}

struct AutomationRunSubmission: Codable, Equatable, Sendable {
    let operationID: String
    let jobID: String
}

struct AutomationRunOutcome: Codable, Sendable {
    var operationID: String
    var jobID: String
    var runID: String
    var createdAtMs: Int64 = 1
    var job: Automation?
    var run: RunRecord?
}

enum FixtureError: LocalizedError {
    case conflict
    case disconnected
    var errorDescription: String? {
        switch self {
        case .conflict: "This job changed since you opened it. Compare the saved job before replacing it."
        case .disconnected: "The computer did not answer."
        }
    }
}

extension Array where Element == AgentBackend {
    func visibleForPicker(keeping id: String? = nil, scope: String = "local") -> [AgentBackend] { self }
}

actor FixtureAutoCommit: AutoCommitService {
    var storedJobs: [Automation] = []
    var storedRuns: [RunRecord] = []
    var backends: [AgentBackend] = [
        AgentBackend(id: "sh", label: "Shell", models: ["default"]),
        AgentBackend(id: "codex", label: "Codex", models: ["gpt-5.4", "haiku"]),
        AgentBackend(id: "claude", label: "Claude", models: ["sonnet"]),
    ]
    var receipts = true
    var creates = 0
    var updates = 0
    var edits = 0
    var runsStarted = 0
    var lastRunOperation: String?
    var createFailure = false
    var createFailureAfter = false
    var runFailure = false
    var editFailure = false
    var runReceipts: [String: AutomationRunOutcome] = [:]

    func jobs() async throws -> [Automation] { storedJobs }
    func runs() async throws -> [RunRecord] { storedRuns }
    func backends() async throws -> [AgentBackend] { backends }
    func supportsReceipts() async -> Bool { receipts }
    func create(_ job: Automation) async throws -> Automation {
        creates += 1
        if createFailure { throw FixtureError.disconnected }
        var created = job
        created.id = created.id.isEmpty ? "auto-1" : created.id
        created.revision = 1
        storedJobs.removeAll { $0.workspaceID == created.workspaceID && AutoCommitJob.isName($0.name) }
        storedJobs.append(created)
        if createFailureAfter { throw FixtureError.disconnected }
        return created
    }
    func update(_ job: Automation) async throws -> Automation {
        updates += 1
        return try await store(job, revision: job.revision + 1)
    }
    func edit(_ job: Automation, revision: UInt64) async throws -> Automation {
        edits += 1
        if editFailure { throw FixtureError.conflict }
        guard let current = storedJobs.first(where: { $0.id == job.id }), current.revision == revision else {
            throw FixtureError.conflict
        }
        return try await store(job, revision: revision + 1)
    }
    func run(_ id: String) async throws -> Automation {
        runsStarted += 1
        return try await startRun(id, operationID: "legacy")
    }
    func runOnce(id: String, operationID: String) async throws -> AutomationRunOutcome {
        lastRunOperation = operationID
        if runFailure { throw FixtureError.disconnected }
        runsStarted += 1
        let job = try await startRun(id, operationID: operationID)
        let run = storedRuns.first { $0.jobId == id }!
        let outcome = AutomationRunOutcome(
            operationID: operationID, jobID: id, runID: run.id, job: job, run: run
        )
        runReceipts[operationID] = outcome
        return outcome
    }
    func runReceipt(operationID: String) async throws -> AutomationRunOutcome? {
        runReceipts[operationID]
    }

    func seed(_ job: Automation) {
        storedJobs.removeAll { $0.id == job.id }
        storedJobs.append(job)
    }
    func seedRun(_ run: RunRecord) {
        storedRuns.removeAll { $0.id == run.id }
        storedRuns.append(run)
    }

    private func store(_ job: Automation, revision: UInt64) async throws -> Automation {
        var saved = job
        saved.revision = revision
        if let index = storedJobs.firstIndex(where: { $0.id == job.id }) {
            storedJobs[index] = saved
        } else {
            storedJobs.append(saved)
        }
        return saved
    }

    private func startRun(_ id: String, operationID: String) async throws -> Automation {
        guard var job = storedJobs.first(where: { $0.id == id }) else { throw FixtureError.disconnected }
        let run = RunRecord(id: "run-\(operationID.suffix(6))", jobId: id, status: "running")
        storedRuns.append(run)
        job.lastRunID = run.id
        storedJobs.removeAll { $0.id == id }
        storedJobs.append(job)
        return job
    }
}

@main struct AutoCommitSessionTests {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) {
            if !condition { fputs("FAIL \(message)\n", stderr); exit(1) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = WorkReference.Scope.local(installationID: "fixture")

        check(AutoCommitJob.isName("auto commit"), "name match is case insensitive")
        check(!AutoCommitJob.commitBackends([
            AgentBackend(id: "sh", label: "Shell", models: ["default"]),
            AgentBackend(id: "codex", label: "Codex", models: ["gpt-5.4"]),
        ]).contains(where: { $0.id == "sh" }), "shell is not a commit agent")
        check(AutoCommitJob.prompt(workspaceName: "Website").contains("Website"), "prompt names the folder")
        check(AutoCommitJob.prompt(workspaceName: "Website").contains("Do not push"), "prompt forbids push")

        let service = FixtureAutoCommit()
        func session(_ name: String) -> AutoCommitSession {
            AutoCommitSession(
                peer: "computer",
                workspaceID: "project",
                folderName: "Website",
                hostName: "Development computer",
                scope: scope,
                hostIdentity: name,
                service: service,
                draftDirectory: root.appendingPathComponent(name)
            )
        }

        let first = session("create")
        await first.load()
        check(first.selectedBackend?.id == "codex", "first agent is not the shell")
        check(first.draft.model == "haiku", "haiku is the default model when listed")
        check(first.canStart, "a loaded idle session can start")
        await first.start()
        check(await service.creates == 1, "first start creates the folder job")
        check(await service.runsStarted == 1, "first start runs immediately")
        check(first.job?.name == "Auto commit", "created job uses the reserved name")
        check(first.job?.prompt.contains("Website") == true, "created job uses the shared prompt")
        check(first.lastRun?.isRunning == true, "the new run is live")
        check(first.route?.jobID == first.job?.id, "start offers the run route")
        check(!first.canStart, "a live run cannot start another")

        await service.seedRun(RunRecord(id: first.lastRun!.id, jobId: first.job!.id, status: "ok"))
        var finished = try await service.jobs()
        check(!finished.isEmpty, "created job is listed")
        finished[0].lastRunID = first.lastRun!.id
        await service.seed(finished[0])
        let again = session("create-again")
        await again.load()
        again.setBackend("claude")
        await again.start()
        check(await service.creates == 1, "a later start reuses the folder job")
        check(await service.edits == 1, "a later start edits the existing job")
        check(again.job?.backend == "claude", "the reused job takes the chosen agent")
        check(await service.runsStarted == 2, "a later start runs the edited job")

        let conflictService = FixtureAutoCommit()
        await conflictService.seed(Automation(
            id: "stale", name: "Auto commit", backend: "codex", workspaceID: "project",
            prompt: "old", schedule: AutomationSchedule(kind: .once), budgetSeconds: 900,
            enabled: true, revision: 4
        ))
        await conflictService.seedRun(RunRecord(id: "done", jobId: "stale", status: "ok"))
        let conflict = AutoCommitSession(
            peer: "computer", workspaceID: "project", folderName: "Website",
            hostName: "Development computer", scope: scope, hostIdentity: "conflict",
            service: conflictService, draftDirectory: root.appendingPathComponent("conflict")
        )
        await conflict.load()
        await conflictService.seed(Automation(
            id: "stale", name: "Auto commit", backend: "codex", workspaceID: "project",
            prompt: "computer", schedule: AutomationSchedule(kind: .once), budgetSeconds: 900,
            enabled: true, revision: 5
        ))
        await conflict.start()
        check(conflict.errorMessage?.contains("changed since you opened it") == true, "stale edit is a conflict")
        check(await conflictService.runsStarted == 0, "a refused edit does not start a run")

        let liveService = FixtureAutoCommit()
        await liveService.seed(Automation(
            id: "live", name: "Auto commit", backend: "codex", workspaceID: "project",
            prompt: "live", schedule: AutomationSchedule(kind: .once), budgetSeconds: 900,
            enabled: true, lastRunID: "live-run", revision: 1
        ))
        await liveService.seedRun(RunRecord(id: "live-run", jobId: "live", status: "running"))
        let running = AutoCommitSession(
            peer: "computer", workspaceID: "project", folderName: "Website",
            hostName: "Development computer", scope: scope, hostIdentity: "running",
            service: liveService, draftDirectory: root.appendingPathComponent("running")
        )
        await running.load()
        check(running.isRunning, "an existing live run is visible")
        check(!running.canStart, "a live Auto commit cannot start another")
        await running.start()
        check(await liveService.runsStarted == 0, "start is a no-op while the job is live")

        let lost = FixtureAutoCommit()
        let lostSession = AutoCommitSession(
            peer: "computer", workspaceID: "project", folderName: "Website",
            hostName: "Development computer", scope: scope, hostIdentity: "lost",
            service: lost, draftDirectory: root.appendingPathComponent("lost")
        )
        await lostSession.load()
        await lost.set(createFailureAfter: true)
        await lostSession.start()
        check(await lost.creates == 1, "a lost create still reached the host")
        check(lostSession.job?.id == "auto-1", "refresh recovers the created job")
        check(await lost.runsStarted == 1, "recovered create still runs once")

        let pending = FixtureAutoCommit()
        let pendingSession = AutoCommitSession(
            peer: "computer", workspaceID: "project", folderName: "Website",
            hostName: "Development computer", scope: scope, hostIdentity: "pending",
            service: pending, draftDirectory: root.appendingPathComponent("pending")
        )
        await pendingSession.load()
        await pending.set(runFailure: true)
        await pendingSession.start()
        check(pendingSession.hasPendingLaunch, "a lost runOnce stays pending")
        check(pendingSession.canRetryLaunch, "a lost runOnce can retry")
        check(!pendingSession.canStart, "pending launch blocks another start")
        let operation = await pending.lastRunOperation
        await pending.set(runFailure: false)
        await pendingSession.retryLaunch()
        check(await pending.lastRunOperation == operation, "retry uses the same run identity")
        check(await pending.runsStarted == 1, "retry is the first recorded run")
        check(!pendingSession.hasPendingLaunch, "a confirmed retry clears pending")

        let legacy = FixtureAutoCommit()
        await legacy.set(receipts: false)
        let oldHost = AutoCommitSession(
            peer: "computer", workspaceID: "project", folderName: "Website",
            hostName: "Development computer", scope: scope, hostIdentity: "legacy",
            service: legacy, draftDirectory: root.appendingPathComponent("legacy")
        )
        await oldHost.load()
        check(oldHost.limitation?.contains("cannot confirm a lost start") == true, "an older host names the lost-start limit")
        await oldHost.start()
        check(await legacy.creates == 1, "an older host still creates the folder job")
        check(await legacy.edits == 0, "an older host does not use revision-checked edit")
        check(await legacy.runsStarted == 1, "an older host runs through the legacy path")
        check(await legacy.lastRunOperation == nil, "an older host has no run receipt identity")

        print("AutoCommitSessionTests passed")
    }
}

extension FixtureAutoCommit {
    func set(
        createFailure: Bool = false,
        createFailureAfter: Bool = false,
        runFailure: Bool = false,
        editFailure: Bool = false,
        receipts: Bool? = nil
    ) {
        self.createFailure = createFailure
        self.createFailureAfter = createFailureAfter
        self.runFailure = runFailure
        self.editFailure = editFailure
        if let receipts { self.receipts = receipts }
    }
}
