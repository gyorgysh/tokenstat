// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct SavedWorkflowDraft: Codable, Equatable, Sendable {
    var graphID: String?
    var baseline: WorkflowGraph?
    var fields: WorkflowEditorDraft
    var pendingCreate = false
    var pendingID: String? = nil
    var created: WorkflowGraph? = nil

    enum CodingKeys: String, CodingKey {
        case graphID = "graphId", baseline, fields, pendingCreate, pendingID = "pendingId", created
    }
}

/// One owner per account, computer, folder and graph. A new graph uses a folder key.
@MainActor @Observable
final class WorkflowEditorSession {
    let target: WorkflowEditorTarget
    let workspaceID: String
    let folderName: String
    let lockedFolder: Bool
    private(set) var saved: SavedWorkflowDraft
    var fields: WorkflowEditorDraft { didSet { scheduleSave() } }
    private(set) var current: WorkflowGraph?
    private(set) var missing = false
    private(set) var loaded = false
    private(set) var working = false
    private(set) var canRetryCreate = false
    private(set) var liveRun = false
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    private(set) var backends: [AgentBackend] = []
    /// Automations an automation step can run. Empty until load.
    private(set) var jobs: [Automation] = []
    /// Working copy of steps. Metadata stays on `fields`.
    private(set) var document = WorkflowGraphDocument()
    /// IANA name of the host scheduler clock. Empty until queue answers.
    private(set) var schedulerTimezone: String = ""
    private(set) var otherDraft: WorkbenchDraftFile<SavedWorkflowDraft>.Record?
    private(set) var persistedFields: WorkflowEditorDraft?
    private let service: any WorkflowEditorService
    private let storage: WorkbenchDraftFile<SavedWorkflowDraft>?
    private var diskRevision: String?
    private var writeTask: Task<Void, Never>?
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoring = false
    private var appliedDefaultBudget = false

    init(
        target: WorkflowEditorTarget,
        workspaceID: String,
        folderName: String,
        existing: WorkflowGraph? = nil,
        lockedFolder: Bool = true,
        scope: WorkReference.Scope?,
        hostIdentity: String?,
        service: (any WorkflowEditorService)? = nil,
        draftDirectory: URL? = nil
    ) {
        self.target = target
        self.workspaceID = workspaceID
        self.folderName = folderName
        self.lockedFolder = lockedFolder
        self.service = service ?? target
        let fields = existing.map(WorkflowEditorDraft.init) ?? WorkflowEditorDraft(workspaceID: workspaceID)
        self.fields = fields
        saved = SavedWorkflowDraft(graphID: existing?.id, baseline: existing, fields: fields)
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let suffix = existing.map { "workflow|" + $0.id } ?? "new-workflow"
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: workspaceID) + suffix
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory, maximumBytes: 4 * 1024 * 1024)
        } else {
            storage = nil
        }
        document.open(Self.graph(from: fields, saved: saved), dirty: false)
    }

    var canUndoGraph: Bool { document.canUndo }
    var canRedoGraph: Bool { document.canRedo }
    var selectedStepID: String? { document.selectedNodeID }
    var selectedConnectionID: String? { document.selectedEdgeID }

    var isCreate: Bool { saved.graphID == nil && saved.created == nil }
    var dirty: Bool {
        if let baseline = saved.baseline { return !fields.matches(baseline) }
        return !fields.name.isEmpty
            || fields.starterID != WorkflowEditorDraft.blankStarterID
            || fields.scheduleKind != .once
            || !fields.enabled
    }
    var creating: Bool { saved.pendingCreate || saved.pendingID != nil }
    var canSave: Bool {
        loaded && !working && !missing && otherDraft == nil && !creating
            && saved.created == nil && fields.validation == nil && dirty && !isCreate
    }
    var canCreate: Bool {
        isCreate && loaded && !working && otherDraft == nil && !creating
            && saved.created == nil && fields.validation == nil
    }

    var recipes: [WorkflowRecipe] {
        WorkflowRecipes.recipes(from: backends)
    }

    func load() async {
        if loaded {
            await refresh()
            await loadOptions()
            await loadQueue()
            if creating, saved.created == nil { await readCreation() }
            return
        }
        guard !working else { return }
        working = true
        defer { working = false }
        guard let storage else {
            errorMessage = "Waiting for this account and computer to be verified before saving work."
            return
        }
        do {
            let record = try await storage.load()
            diskRevision = record?.revision
            persistedFields = record?.value.fields
            if let record { restore(record.value) }
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await loadOptions()
        await loadQueue()
        lockFolderIfNeeded()
        await readCurrent()
        _ = await persist()
        if creating, saved.created == nil { await readCreation() }
    }

    func refresh() async {
        guard loaded, !working else { return }
        working = true
        defer { working = false }
        await loadOptions()
        await readCurrent()
    }

    func save() async {
        if isCreate {
            await create()
            return
        }
        guard canSave, let baseline = saved.baseline ?? current else { return }
        working = true
        defer { working = false }
        lockFolderIfNeeded()
        let graph: WorkflowGraph
        do {
            graph = try fields.makeGraph(
                id: baseline.id,
                lastRunAtMs: baseline.lastRunAtMs,
                lastRunID: baseline.lastRunID
            )
        } catch {
            errorMessage = Self.display(error)
            return
        }
        errorMessage = nil
        do {
            let updated = try await service.updateWorkflow(graph)
            await applySaved(updated)
        } catch {
            errorMessage = Self.display(error)
        }
    }

    func create() async {
        guard canCreate else { return }
        working = true
        defer { working = false }
        lockFolderIfNeeded()
        let pendingID = saved.pendingID ?? Self.newGraphID()
        let graph: WorkflowGraph
        do {
            graph = try fields.makeGraph(id: pendingID)
        } catch {
            errorMessage = Self.display(error)
            return
        }
        saved.pendingID = pendingID
        saved.pendingCreate = true
        canRetryCreate = false
        guard await persist() else {
            saved.pendingID = nil
            saved.pendingCreate = false
            return
        }
        await submitCreation(graph, pendingID: pendingID)
    }

    func checkCreated() async {
        guard loaded, !working, creating, saved.created == nil else { return }
        working = true
        defer { working = false }
        await readCreation()
    }

    func retryCreate() async {
        guard loaded, !working, canRetryCreate, let pendingID = saved.pendingID, saved.created == nil, otherDraft == nil else { return }
        working = true
        defer { working = false }
        lockFolderIfNeeded()
        let graph: WorkflowGraph
        do {
            graph = try fields.makeGraph(id: pendingID)
        } catch {
            errorMessage = Self.display(error)
            return
        }
        saved.pendingCreate = true
        guard await persist() else { return }
        await submitCreation(graph, pendingID: pendingID)
    }

    /// Clears a finished create so the next New workflow is a blank graph.
    func finishCreated() async -> WorkflowGraph? {
        guard let created = saved.created else { return nil }
        restoring = true
        let fresh = WorkflowEditorDraft(workspaceID: workspaceID)
        fields = fresh
        saved = SavedWorkflowDraft(graphID: nil, baseline: nil, fields: fresh)
        restoring = false
        adoptDocument()
        appliedDefaultBudget = false
        noticeMessage = nil
        errorMessage = nil
        missing = false
        canRetryCreate = false
        current = nil
        _ = await persist()
        return created
    }

    func resolveDiskConflict(keepMine: Bool) async {
        guard !working, let otherDraft else { return }
        let other = otherDraft.value
        guard !keepMine || (!other.pendingCreate && other.pendingID == nil) else { return }
        diskRevision = otherDraft.revision
        self.otherDraft = nil
        if !keepMine { restore(other) }
        _ = await persist()
        if creating, saved.created == nil { await readCreation() }
    }

    func flush() async {
        writeTask?.cancel()
        _ = await persist()
    }

    func applyBlank() {
        guard isCreate, !creating else { return }
        restoring = false
        fields.applyBlank()
        adoptDocument()
    }

    func applyRecipe(_ recipe: WorkflowRecipe) {
        guard isCreate, !creating else { return }
        fields.applyRecipe(recipe)
        adoptDocument()
    }

    func addStep(kind: WorkflowNodeKind, backend: String? = nil, automationID: String? = nil) {
        guard !creating, otherDraft == nil else { return }
        document.addNode(kind: kind, backend: backend, automationID: automationID)
        writeStepsFromDocument()
    }

    func connectSteps(from: String, to: String, when: WorkflowEdgeWhen) {
        guard !creating, otherDraft == nil else { return }
        document.connect(from: from, to: to, when: when)
        writeStepsFromDocument()
    }

    func replaceConnection(id: String, to: String, when: WorkflowEdgeWhen) {
        guard !creating, otherDraft == nil else { return }
        document.replaceConnection(id: id, to: to, when: when)
        writeStepsFromDocument()
    }

    func removeConnection(id: String) {
        guard !creating, otherDraft == nil else { return }
        document.removeEdge(id: id)
        writeStepsFromDocument()
    }

    func removeSelectedStep() {
        guard !creating, otherDraft == nil else { return }
        document.deleteSelection()
        writeStepsFromDocument()
    }

    func selectStep(_ id: String?) {
        document.selectNode(id)
    }

    func selectConnection(_ id: String?) {
        document.selectEdge(id)
    }

    func updateSelectedStep(_ body: (inout WorkflowNode) -> Void) {
        guard !creating, otherDraft == nil else { return }
        document.updateSelectedNode(body)
        writeStepsFromDocument()
    }

    func beginGroupedStepEdit() {
        guard !creating, otherDraft == nil else { return }
        document.beginGroupedEdit()
    }

    func writeSelectedStep(_ body: (inout WorkflowNode) -> Void) {
        guard !creating, otherDraft == nil else { return }
        guard let id = document.selectedNodeID else { return }
        document.writeWorking { graph in
            guard let idx = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            body(&graph.nodes[idx])
        }
        writeStepsFromDocument()
    }

    func endGroupedStepEdit() {
        document.endGroupedEdit()
    }

    func additionIssue(kind: WorkflowNodeKind) -> String? {
        WorkflowGraphRules.additionIssue(kind: kind, nodeCount: fields.nodes.count)
    }

    func undoGraph() {
        guard !creating, otherDraft == nil else { return }
        document.undo()
        writeStepsFromDocument()
    }

    func redoGraph() {
        guard !creating, otherDraft == nil else { return }
        document.redo()
        writeStepsFromDocument()
    }

    private func lockFolderIfNeeded() {
        guard lockedFolder, fields.workspaceID != workspaceID else { return }
        restoring = true
        fields.workspaceID = workspaceID
        restoring = false
    }

    private func loadOptions() async {
        do {
            backends = try await service.automationBackends()
        } catch {
            errorMessage = Self.display(error)
        }
        do {
            jobs = try await service.automations()
        } catch {
            jobs = []
        }
        do {
            let running = try await service.liveWorkflowIDs()
            if let id = saved.graphID ?? saved.baseline?.id {
                liveRun = running.contains(id)
            } else {
                liveRun = false
            }
        } catch {
            liveRun = false
        }
    }

    private func loadQueue() async {
        do {
            let queue = try await service.automationQueue()
            if let timezone = HostScheduleClock.resolved(queue.timezone) {
                schedulerTimezone = timezone
            }
            if isCreate, !appliedDefaultBudget {
                restoring = true
                fields.loadBudget(seconds: queue.defaultBudgetSeconds)
                restoring = false
                appliedDefaultBudget = true
                _ = await persist()
            }
        } catch {
            if isCreate { appliedDefaultBudget = true }
        }
    }

    private func readCurrent() async {
        guard let id = saved.graphID else {
            missing = false
            current = nil
            return
        }
        do {
            current = try await service.workflow(id: id)
            missing = current == nil
            if missing {
                errorMessage = "This workflow was deleted on the computer. Your draft is still here."
                return
            }
            guard let current else { return }
            if errorMessage?.hasPrefix("This workflow was deleted") == true {
                errorMessage = nil
            }
            if let baseline = saved.baseline, !fields.matches(baseline), !fields.matches(current) {
                noticeMessage = "This workflow also changed on the computer. Saving overwrites that copy."
            }
        } catch {
            errorMessage = Self.display(error)
        }
    }

    private func submitCreation(_ graph: WorkflowGraph, pendingID: String) async {
        canRetryCreate = false
        errorMessage = nil
        noticeMessage = nil
        do {
            let created = try await service.createWorkflow(graph)
            await confirmCreated(created)
        } catch {
            if let existing = try? await service.workflow(id: pendingID) {
                await confirmCreated(existing)
                return
            }
            if Self.isUncertain(error) {
                canRetryCreate = true
                errorMessage = "The computer did not confirm this workflow. Check this folder's workflows before creating another."
            } else if error.localizedDescription.lowercased().contains("already exists") {
                if let existing = try? await service.workflow(id: pendingID) {
                    await confirmCreated(existing)
                } else {
                    canRetryCreate = true
                    errorMessage = "A workflow with this id is already on the computer. Check this folder before creating another."
                }
            } else {
                saved.pendingCreate = false
                saved.pendingID = nil
                canRetryCreate = false
                errorMessage = Self.display(error)
                _ = await persist()
            }
        }
    }

    private func readCreation() async {
        guard let pendingID = saved.pendingID else {
            errorMessage = "This workflow is not in the folder yet. It may still arrive, or it may never have been created. Do not create another until you have checked."
            return
        }
        do {
            if let match = try await service.workflow(id: pendingID) {
                await confirmCreated(match)
            } else {
                canRetryCreate = true
                errorMessage = "This workflow is not in the folder yet. It may still arrive, or it may never have been created. Do not create another until you have checked."
            }
        } catch {
            errorMessage = Self.display(error)
        }
    }

    private func confirmCreated(_ created: WorkflowGraph) async {
        saved.pendingCreate = false
        saved.pendingID = nil
        canRetryCreate = false
        saved.created = created
        saved.graphID = created.id
        saved.baseline = created
        restoring = true
        fields = WorkflowEditorDraft(created)
        restoring = false
        adoptDocument()
        errorMessage = nil
        announceCreated(created)
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
    }

    private func announceCreated(_ created: WorkflowGraph) {
        if created.schedule.repeats, let place = HostScheduleClock.place(schedulerTimezone) {
            noticeMessage = "\(created.name) will run \(created.schedule.summary) in \(place)."
        } else if created.schedule.repeats {
            noticeMessage = "\(created.name) will run \(created.schedule.summary)."
        } else {
            noticeMessage = "\(created.name) is saved. It will not run until you press Run."
        }
    }

    private func applySaved(_ updated: WorkflowGraph) async {
        saved.baseline = updated
        saved.graphID = updated.id
        restoring = true
        fields = WorkflowEditorDraft(updated)
        restoring = false
        adoptDocument()
        noticeMessage = "Saved \(updated.name)."
        _ = await persist()
        NotificationCenter.default.post(name: Self.didChange, object: target)
    }

    private func restore(_ value: SavedWorkflowDraft) {
        restoring = true
        saved = value
        fields = value.fields
        restoring = false
        adoptDocument()
    }

    private func adoptDocument() {
        document.open(Self.graph(from: fields, saved: saved), dirty: false)
    }

    private func writeStepsFromDocument() {
        guard let graph = document.graph else { return }
        restoring = true
        fields.nodes = graph.nodes
        fields.edges = graph.edges
        restoring = false
        scheduleSave()
    }

    private static func graph(from fields: WorkflowEditorDraft, saved: SavedWorkflowDraft) -> WorkflowGraph {
        let name = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowGraph(
            id: saved.graphID ?? saved.pendingID ?? "",
            name: name.isEmpty ? "Untitled" : name,
            scope: .workspace,
            workspaceID: fields.workspaceID,
            budgetSeconds: fields.budgetSeconds ?? 10_800,
            schedule: fields.builtSchedule,
            enabled: fields.builtSchedule.repeats ? fields.enabled : false,
            nodes: fields.nodes,
            edges: fields.edges,
            lastRunAtMs: saved.baseline?.lastRunAtMs,
            lastRunID: saved.baseline?.lastRunID
        )
    }

    private func scheduleSave() {
        guard loaded, !restoring else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.flush()
        }
    }

    @discardableResult
    private func persist() async -> Bool {
        guard loaded, let storage, otherDraft == nil else { return false }
        while writing { await withCheckedContinuation { writeWaiters.append($0) } }
        guard otherDraft == nil else { return false }
        writing = true
        defer {
            writing = false
            let waiters = writeWaiters
            writeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        saved.fields = fields
        let snapshot = saved
        do {
            let record = try await storage.save(snapshot, expectedRevision: diskRevision)
            diskRevision = record.revision
            persistedFields = snapshot.fields
            return true
        } catch {
            errorMessage = error.localizedDescription
            if case WorkbenchDraftFile<SavedWorkflowDraft>.Failure.changed = error {
                otherDraft = try? await storage.load()
            }
            return false
        }
    }

    static let didChange = Notification.Name("tokenstat.workflowDidChange")

    static func newGraphID() -> String {
        "wf-" + UUID().uuidString.lowercased()
    }

    static func isUncertain(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("disconnected")
            || lower.contains("cancelled")
            || lower.contains("canceled")
            || lower.contains("no_such_peer")
            || lower.contains("not on the tunnel")
            || lower.contains("tunnel is not connected")
            || lower.contains("tunnel disconnected")
    }

    static func display(_ error: Error) -> String {
        error.localizedDescription
    }
}

@MainActor enum WorkflowEditorSessions {
    private static var sessions: [String: WorkflowEditorSession] = [:]

    static func session(
        target: WorkflowEditorTarget,
        workspaceID: String,
        folderName: String,
        existing: WorkflowGraph? = nil,
        lockedFolder: Bool = true
    ) -> WorkflowEditorSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else {
            return WorkflowEditorSession(
                target: target, workspaceID: workspaceID, folderName: folderName,
                existing: existing, lockedFolder: lockedFolder, scope: nil, hostIdentity: nil
            )
        }
        let suffix = existing.map { "workflow|" + $0.id } ?? "new-workflow"
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: workspaceID) + suffix
        if let existingSession = sessions[key] { return existingSession }
        let created = WorkflowEditorSession(
            target: target, workspaceID: workspaceID, folderName: folderName,
            existing: existing, lockedFolder: lockedFolder, scope: scope, hostIdentity: host
        )
        sessions[key] = created
        return created
    }
}
