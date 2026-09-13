// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AutomationEditorDraft.swift AutomationEditorService.swift AutomationEditorSession.swift
// HostScheduleClock.swift WorkbenchDraftFile.swift OriginalFileCoordination.swift WorkReference.swift.
import Foundation

enum ScheduleKind: String, Codable, Sendable, Hashable, CaseIterable {
    case once, interval, daily, weekdays, weekly, custom
    var label: String { rawValue }
}

struct AutomationSchedule: Codable, Sendable, Hashable {
    var kind: ScheduleKind
    var everySeconds: UInt64 = 0
    var hour: Int = 9
    var minute: Int = 0
    var weekday: Int = 0
    var weekdays: Int = 0
    static let weekdaysMask = 0b0001_1111
    var summary: String { kind.rawValue }
    var repeats: Bool { kind != .once }
}

struct Automation: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var backend: String
    var model: String?
    var effort: String?
    var workspaceID: String
    var prompt: String
    var schedule: AutomationSchedule
    var budgetSeconds: UInt64
    var enabled: Bool
    var lastRunAtMs: Int64?
    var nextRunAtMs: Int64?
    var lastRunID: String?
    var revision: UInt64 = 0
    init(
        id: String, name: String, backend: String, model: String? = nil, effort: String? = nil,
        workspaceID: String, prompt: String, schedule: AutomationSchedule, budgetSeconds: UInt64,
        enabled: Bool, lastRunAtMs: Int64? = nil, nextRunAtMs: Int64? = nil, lastRunID: String? = nil,
        revision: UInt64 = 0
    ) {
        self.id = id; self.name = name; self.backend = backend; self.model = model; self.effort = effort
        self.workspaceID = workspaceID; self.prompt = prompt; self.schedule = schedule
        self.budgetSeconds = budgetSeconds; self.enabled = enabled
        self.lastRunAtMs = lastRunAtMs; self.nextRunAtMs = nextRunAtMs; self.lastRunID = lastRunID
        self.revision = revision
    }
    var payload: [String: Any] { [:] }
}
struct AutomationCreationOutcome: Codable, Equatable, Sendable {
    var operationID: String
    var jobID: String
    var createdAtMs: Int64
    var job: Automation?
}
struct RunRecord: Codable, Sendable {
    var id = ""
    var jobId = ""
    var isRunning = false
}

struct AgentBackend: Codable, Sendable {
    var id: String
    var label: String
    var command: String
    var models: [String] = []
    var efforts: [String] = []
    init(id: String, label: String, command: String, models: [String] = [], efforts: [String] = []) {
        self.id = id; self.label = label; self.command = command; self.models = models; self.efforts = efforts
    }
}

struct AutomationQueue: Codable, Sendable {
    var defaultBudgetSeconds: UInt64
    var maxConcurrent: UInt32 = 2
    var timezone: String? = nil
}
enum TodoCard {
    static func cleanModelID(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
}
enum FixtureError: LocalizedError {
    case disconnected, conflict, unexpectedTransport, invalid(String)
    var errorDescription: String? {
        switch self {
        case .disconnected: "disconnected"
        case .conflict: "conflict"
        case .unexpectedTransport: "unexpected transport"
        case let .invalid(message): message
        }
    }
}
enum Bridge {
    static func onPeer<T: Decodable & Sendable>(_ peer: String, _ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
    static func localTaskEditor<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
}
enum RemoteHostFeature {
    case automationReceipts
    func isSupported(peer: String?) async -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}

actor FixtureAutomations: AutomationEditorService {
    var jobs: [Automation] = []
    var backends: [AgentBackend] = [AgentBackend(id: "codex", label: "Codex", command: "codex")]
    var queue = AutomationQueue(defaultBudgetSeconds: 121, timezone: "America/New_York")
    var creates = 0
    var updates = 0
    var edits = 0
    var createOnceCalls = 0
    var loseCreateReply = false
    var loseCreateBefore = false
    var failCreateBeforeAcceptance = false
    var receiptsEnabled = false
    var running: [String] = []
    var creations: [String: AutomationCreationOutcome] = [:]
    func supportsReceipts() async -> Bool { receiptsEnabled }
    func createAutomation(_ job: Automation) async throws -> Automation {
        if failCreateBeforeAcceptance { throw FixtureError.invalid("an automation needs a name") }
        creates += 1
        var created = job
        if created.id.isEmpty { created.id = "job-\(creates)" }
        if created.revision == 0 { created.revision = 1 }
        if let index = jobs.firstIndex(where: { $0.id == created.id }) {
            jobs[index] = created
        } else {
            jobs.append(created)
        }
        if loseCreateReply { throw FixtureError.disconnected }
        return created
    }
    func createAutomationOnce(_ job: Automation, operationID: String) async throws -> AutomationCreationOutcome {
        if failCreateBeforeAcceptance { throw FixtureError.invalid("an automation needs a name") }
        if loseCreateBefore { throw FixtureError.disconnected }
        if let existing = creations[operationID] {
            if loseCreateReply { throw FixtureError.disconnected }
            return existing
        }
        createOnceCalls += 1
        var created = job
        if created.id.isEmpty { created.id = "job-once-\(createOnceCalls)" }
        if created.revision == 0 { created.revision = 1 }
        if let index = jobs.firstIndex(where: { $0.id == created.id }) {
            jobs[index] = created
        } else {
            jobs.append(created)
        }
        let outcome = AutomationCreationOutcome(
            operationID: operationID, jobID: created.id, createdAtMs: 1, job: created
        )
        creations[operationID] = outcome
        if loseCreateReply { throw FixtureError.disconnected }
        return outcome
    }
    func automationCreationReceipt(operationID: String) async throws -> AutomationCreationOutcome? {
        creations[operationID]
    }
    func updateAutomation(_ job: Automation) async throws -> Automation {
        updates += 1
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw FixtureError.conflict }
        jobs[index] = job
        return job
    }
    func editAutomation(_ job: Automation, revision: UInt64) async throws -> Automation {
        edits += 1
        guard var current = jobs.first(where: { $0.id == job.id }) else { throw FixtureError.conflict }
        guard current.revision == revision else { throw FixtureError.conflict }
        current.name = job.name
        current.prompt = job.prompt
        current.backend = job.backend
        current.model = job.model
        current.effort = job.effort
        current.workspaceID = job.workspaceID
        current.schedule = job.schedule
        current.budgetSeconds = job.budgetSeconds
        current.enabled = job.enabled
        current.revision = revision + 1
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = current
        }
        return current
    }
    func runningJobIDs() async throws -> [String] { running }
    func removeAutomation(id: String) async throws {
        jobs.removeAll { $0.id == id }
    }
    func automation(id: String) async throws -> Automation? { jobs.first { $0.id == id } }
    func automations() async throws -> [Automation] { jobs }
    func automationBackends() async throws -> [AgentBackend] { backends }
    func automationQueue() async throws -> AutomationQueue { queue }
    func setCreateFailure(before: Bool = false, after: Bool = false, uncertainBefore: Bool = false) {
        failCreateBeforeAcceptance = before
        loseCreateReply = after
        loseCreateBefore = uncertainBefore
    }
    func setReceipts(_ value: Bool) { receiptsEnabled = value }
    func setRunning(_ ids: [String]) { running = ids }
    func changePrompt(_ id: String, _ prompt: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].prompt = prompt
        jobs[index].revision += 1
    }
    func seed(_ job: Automation) { jobs.append(job) }
    func delete(_ id: String) { jobs.removeAll { $0.id == id } }
}

@main struct AutomationEditorSessionTests {
    @MainActor static func main() async throws {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixtureAutomations()

        func createSession() -> AutomationEditorSession {
            AutomationEditorSession(
                target: AutomationEditorTarget(peer: "computer"),
                workspaceID: "folder",
                folderName: "Website",
                existing: nil,
                lockedFolder: true,
                scope: .local(installationID: "fixture"),
                hostIdentity: "computer",
                service: service,
                draftDirectory: directory
            )
        }

        do {
            var draft = AutomationEditorDraft(workspaceID: "")
            check(draft.validation == "Give this job a name.", "empty name")
            draft.name = "Nightly"
            check(draft.validation == "Write what the agent should do.", "empty prompt")
            draft.prompt = "Review the tree"
            check(draft.validation == "Choose a folder for this job.", "empty folder")
            draft.workspaceID = "folder"
            check(draft.validation == "Choose an agent for this job.", "empty agent")
            draft.backend = "codex"
            check(draft.validation == nil, "ready draft")
            draft.scheduleKind = .custom
            draft.customDays = 0
            check(draft.validation == "Pick at least one day for a custom schedule.", "custom days")
            draft.customDays = AutomationSchedule.weekdaysMask
            draft.noTimeLimit = false
            draft.budgetMinutes = "0"
            check(draft.validation == "Enter a positive time limit, or choose No limit.", "budget")
            draft.budgetMinutes = "30"
            check(draft.validation == nil, "valid budget")
        }

        do {
            var draft = AutomationEditorDraft(workspaceID: "folder", backend: "codex")
            draft.name = "Tick"
            draft.prompt = "Check"
            draft.scheduleKind = .interval
            draft.intervalSeconds = 90
            draft.intervalTouched = false
            check(draft.builtSchedule.everySeconds == 90, "keep raw interval seconds")
            draft.intervalMinutes = "15"
            draft.intervalTouched = true
            check(draft.builtSchedule.everySeconds == 15 * 60, "preset interval")
            let job = Automation(
                id: "weekly", name: "Weekly notes", backend: "codex", workspaceID: "folder",
                prompt: "Summarize", schedule: AutomationSchedule(kind: .weekly, hour: 10, minute: 0, weekday: 0, weekdays: 0b0000_0101),
                budgetSeconds: 900, enabled: true
            )
            let loaded = AutomationEditorDraft(job)
            check(loaded.weeklyDays == 0b0000_0101, "keep weekly mask")
            check(!loaded.weeklyDayEdited, "weekly mask is untouched")
            check(loaded.builtSchedule.weekdays == 0b0000_0101, "round-trip weekly mask")
            check(loaded.matches(job), "loaded draft matches job")
        }

        let created = createSession()
        await created.load()
        check(created.fields.workspaceID == "folder", "create keeps the folder")
        check(created.fields.backend == "codex", "create picks the default agent")
        check(created.fields.budgetMinutes == "2", "queue default minutes")
        check(created.schedulerTimezone == "America/New_York", "host scheduler zone")
        check(created.persistedFields == created.fields, "load keeps the opening draft")
        created.fields.workspaceID = "other"
        created.fields.name = "Nightly docs"
        created.fields.prompt = "Read the recent changes."
        await created.create()
        check(await service.creates == 1, "one create")
        check(created.saved.created?.workspaceID == "folder", "create locked the folder")
        check(created.saved.created?.name == "Nightly docs", "created name")
        check(created.fields.workspaceID == "folder", "folder stays locked after create")

        let lost = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: nil,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "lost",
            service: service,
            draftDirectory: directory.appendingPathComponent("lost")
        )
        await service.setCreateFailure(after: true)
        await lost.load()
        lost.fields.name = "Maybe created"
        lost.fields.prompt = "Do not retry this automatically."
        await lost.create()
        let createsAfterLoss = await service.creates
        check(createsAfterLoss == 2, "uncertain create still reached the host once")
        check(lost.saved.pendingCreate, "uncertain create stays pending")
        check(lost.saved.created == nil, "uncertain create has no local job")
        check(lost.canCreate == false, "create stays off after a lost reply")
        await lost.create()
        check(await service.creates == 2, "lost create is not retried automatically")
        await lost.checkCreated()
        check(lost.saved.created?.name == "Maybe created", "check finds the host job")
        check(lost.saved.pendingCreate == false, "check clears pending create")

        let refused = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: nil,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "refused",
            service: service,
            draftDirectory: directory.appendingPathComponent("refused")
        )
        await service.setCreateFailure(before: true)
        await refused.load()
        refused.fields.name = "Never sent"
        refused.fields.prompt = "Host refused before accepting."
        await refused.create()
        let createsAfterRefuse = await service.creates
        check(createsAfterRefuse == 2, "refused create did not store a job")
        check(refused.saved.pendingCreate == false, "host validation is not pending")
        check(refused.canCreate, "host validation can be tried again")
        await service.setCreateFailure()
        await refused.create()
        check(await service.creates == 3, "explicit retry after a refused create")

        await service.setCreateFailure()
        let existing = Automation(
            id: "daily", name: "Daily project review", backend: "codex", workspaceID: "folder",
            prompt: "Read the recent changes.", schedule: AutomationSchedule(kind: .daily, hour: 9),
            budgetSeconds: 1800, enabled: true
        )
        await service.seed(existing)
        let editor = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: existing,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "edit",
            service: service,
            draftDirectory: directory.appendingPathComponent("edit")
        )
        await editor.load()
        check(editor.canSave == false, "clean edit cannot save")
        check(editor.persistedFields == editor.fields, "edit load keeps the opening draft")
        editor.fields.prompt = "Read the recent changes and note regressions."
        editor.fields.workspaceID = "elsewhere"
        await editor.save()
        check(await service.updates == 1, "one update")
        check(editor.saved.baseline?.workspaceID == "folder", "edit locked the folder")
        check(editor.saved.baseline?.prompt == "Read the recent changes and note regressions.", "saved prompt")
        check(editor.saved.baseline?.enabled == true, "enabled is not an editor field")

        editor.fields.prompt = "Draft kept while inspecting history."
        editor.fields.model = "gpt-5.3-codex"
        await editor.flush()
        let afterHistory = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: editor.saved.baseline,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "edit",
            service: service,
            draftDirectory: directory.appendingPathComponent("edit")
        )
        await afterHistory.load()
        check(afterHistory.fields.prompt == "Draft kept while inspecting history.", "draft survives leaving the editor")
        check(afterHistory.fields.model == "gpt-5.3-codex", "model draft survives a picker")

        await service.delete("daily")
        let gone = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: existing,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "gone",
            service: service,
            draftDirectory: directory.appendingPathComponent("gone")
        )
        await gone.load()
        gone.fields.prompt = "This should not overwrite a missing job."
        check(gone.missing, "deleted job is missing")
        check(gone.canSave == false, "missing job cannot save")
        await gone.save()
        check(await service.updates == 1, "missing job did not update")

        let recovered = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: nil,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "lost",
            service: service,
            draftDirectory: directory.appendingPathComponent("lost")
        )
        await recovered.load()
        check(recovered.saved.created?.name == "Maybe created", "reopened session keeps the created job")
        let finished = await recovered.finishCreated()
        check(finished?.name == "Maybe created", "finish returns the created job")
        check(recovered.saved.created == nil, "finish clears the create draft")
        check(recovered.isCreate, "finish leaves a blank create")
        check(recovered.fields.name.isEmpty, "finish does not keep the old name")

        let receipts = FixtureAutomations()
        await receipts.setReceipts(true)
        let receiptDir = directory.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        let receiptCreate = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: nil,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "receipts",
            service: receipts,
            draftDirectory: receiptDir
        )
        await receiptCreate.load()
        check(receiptCreate.supportsReceipts, "protocol 21 is available")
        receiptCreate.fields.name = "Durable nightly"
        receiptCreate.fields.prompt = "Read the tree once."
        await receipts.setCreateFailure(after: true)
        await receiptCreate.create()
        check(await receipts.createOnceCalls == 1, "createOnce reached the host")
        check(receiptCreate.saved.created?.name == "Durable nightly", "a lost reply recovers the receipt")
        check(receiptCreate.creating == false, "recovered create is not pending")

        let pendingDir = directory.appendingPathComponent("pending-create")
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let pendingCreate = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: nil,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "pending-create",
            service: receipts,
            draftDirectory: pendingDir
        )
        await pendingCreate.load()
        pendingCreate.fields.name = "Retry nightly"
        pendingCreate.fields.prompt = "Retry the same creation."
        await receipts.setCreateFailure(uncertainBefore: true)
        await pendingCreate.create()
        check(await receipts.createOnceCalls == 1, "uncertain createOnce did not store a job")
        check(pendingCreate.creating, "lost createOnce stays pending")
        check(pendingCreate.canRetryCreate, "lost createOnce can retry the same id")
        check(pendingCreate.canCreate == false, "create stays off after a lost receipt")
        await pendingCreate.create()
        check(await receipts.createOnceCalls == 1, "pending create is not retried automatically")
        await receipts.setCreateFailure()
        await pendingCreate.retryCreate()
        check(await receipts.createOnceCalls == 2, "retry uses the original creation")
        check(pendingCreate.saved.created?.name == "Retry nightly", "retry createOnce stores the job")
        check(pendingCreate.creating == false, "retry clears pending create")

        let live = Automation(
            id: "live", name: "Live job", backend: "codex", workspaceID: "folder",
            prompt: "Original prompt", schedule: AutomationSchedule(kind: .daily, hour: 9),
            budgetSeconds: 1800, enabled: true, revision: 1
        )
        await receipts.seed(live)
        await receipts.setRunning(["live"])
        let liveDir = directory.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let liveEditor = AutomationEditorSession(
            target: AutomationEditorTarget(peer: "computer"),
            workspaceID: "folder",
            folderName: "Website",
            existing: live,
            lockedFolder: true,
            scope: .local(installationID: "fixture"),
            hostIdentity: "live",
            service: receipts,
            draftDirectory: liveDir
        )
        await liveEditor.load()
        check(liveEditor.liveRun, "a live run is visible in the editor")
        liveEditor.fields.prompt = "Next run prompt"
        await liveEditor.save()
        check(await receipts.edits == 1, "live save uses edit")
        check(liveEditor.saved.baseline?.prompt == "Next run prompt", "saved prompt is for the next run")
        check(liveEditor.saved.baseline?.revision == 2, "edit advances revision")

        await receipts.changePrompt("live", "Computer prompt")
        liveEditor.fields.prompt = "Phone prompt"
        await liveEditor.refresh()
        check(liveEditor.conflict, "stale host copy is a conflict")
        check(liveEditor.canSave == false, "conflict blocks save")
        check(liveEditor.fields.prompt == "Phone prompt", "draft stays during conflict")
        await liveEditor.resolveConflict(keepMine: true)
        check(liveEditor.conflict == false, "keeping the draft clears conflict")
        check(liveEditor.fields.prompt == "Phone prompt", "keep mine retains the draft")
        check(liveEditor.saved.baseline?.prompt == "Computer prompt", "baseline becomes the computer copy")
        await liveEditor.save()
        check(await receipts.edits == 2, "kept draft saves against the new revision")
        check(liveEditor.saved.baseline?.prompt == "Phone prompt", "kept draft replaced the computer copy")

        await receipts.changePrompt("live", "Later computer prompt")
        liveEditor.fields.prompt = "Later phone prompt"
        await liveEditor.save()
        check(liveEditor.conflict, "a stale save opens the comparison")
        check(liveEditor.canSave == false, "conflict after a stale save still blocks save")
        check(liveEditor.fields.prompt == "Later phone prompt", "stale save keeps the draft")
        check(liveEditor.saved.pendingEdit == nil, "stale save is not left pending")

        print("AutomationEditorSessionTests passed")
    }
}
