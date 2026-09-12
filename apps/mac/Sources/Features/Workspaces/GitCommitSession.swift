// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct GitCommitDraft: Codable, Equatable, Sendable {
    var title = ""
    var details = ""
    var paths: Set<String> = []
    var submitted: GitCommitSubmission?

    var message: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? title : "\(title)\n\n\(details)"
    }
}

/// One target's writing and submitted operation outlive sheets and layouts.
@MainActor @Observable
final class GitCommitSession: Identifiable {
    let target: GitCommitTarget
    let service: any GitCommitService
    var draft = GitCommitDraft()
    private(set) var review: GitCommitReview?
    private(set) var outcome: GitCommitReceipt?
    private(set) var working = false
    private(set) var loaded = false
    private(set) var canRetrySubmission = false
    var errorMessage: String?
    private(set) var saveError: String?
    struct SavedAlternative {
        let revision: String?
        let draft: GitCommitDraft
    }
    private(set) var savedAlternative: SavedAlternative?
    @ObservationIgnored private let storage: WorkbenchDraftFile<GitCommitDraft>?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var saved: GitCommitDraft?
    @ObservationIgnored private var persisting: Task<Bool, Never>?

    init(target: GitCommitTarget, scope: WorkReference.Scope?, hostIdentity: String?, service: (any GitCommitService)? = nil, draftDirectory: URL? = nil) {
        self.target = target
        self.service = service ?? target
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: target.workspaceID) + "git-commit"
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory)
        } else {
            storage = nil
        }
    }

    var canCommit: Bool {
        loaded && !working && draft.submitted == nil && review != nil
            && Set(review?.paths ?? []) == draft.paths
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.message.utf8.count <= 128 * 1024
    }

    var canUseSavedVersion: Bool {
        guard let savedAlternative else { return false }
        return !working && (draft.submitted == nil || draft.submitted?.operationID == savedAlternative.draft.submitted?.operationID)
    }

    var canCompareSavedVersion: Bool { storage != nil && !working }

    var canKeepCurrentVersion: Bool {
        guard let savedAlternative else { return false }
        let pending = savedAlternative.draft.submitted?.operationID
        return !working && (pending == nil || pending == draft.submitted?.operationID
            || (outcome?.succeeded == true && pending == outcome?.operationID))
    }

    func compareSavedVersion() async {
        guard let storage else { return }
        do {
            let record = try await storage.load()
            savedAlternative = SavedAlternative(revision: record?.revision, draft: record?.value ?? GitCommitDraft())
        } catch { saveError = error.localizedDescription }
    }

    func useSavedVersion() {
        guard canUseSavedVersion, let alternative = savedAlternative else { return }
        draft = alternative.draft
        saved = alternative.draft
        revision = alternative.revision
        review = nil
        outcome = nil
        saveError = nil
        loaded = true
        savedAlternative = nil
    }

    func keepCurrentVersion() async {
        guard canKeepCurrentVersion, let alternative = savedAlternative else { return }
        revision = alternative.revision
        saved = alternative.draft
        saveError = nil
        if await persist() { savedAlternative = nil }
    }

    func load() async {
        guard !loaded else { return }
        guard let storage else {
            saveError = "Waiting for this account and computer to be verified before saving work."
            loaded = true
            return
        }
        do {
            let record = try await storage.load()
            guard !loaded else { return }
            if let record { draft = record.value; revision = record.revision }
            saved = draft
            saveError = nil
            loaded = true
        } catch { saveError = error.localizedDescription }
    }

    /// Coalesce changes through one writer. Commit awaits this before the host
    /// call so a process restart still knows which operation to reconcile.
    @discardableResult
    func persist() async -> Bool {
        if let persisting { return await persisting.value }
        guard loaded, let storage else { return false }
        let task = Task { @MainActor [self] in
            while saved != draft {
                let value = draft
                do {
                    let record = try await storage.save(value, expectedRevision: revision)
                    revision = record.revision
                    saved = record.value
                    saveError = nil
                } catch {
                    saveError = error.localizedDescription
                    return false
                }
            }
            return true
        }
        persisting = task
        let result = await task.value
        persisting = nil
        return result
    }

    func select(_ path: String) {
        guard !working, draft.submitted == nil else { return }
        if !draft.paths.insert(path).inserted { draft.paths.remove(path) }
        review = nil
        outcome = nil
    }

    func selectAll(_ paths: Set<String>) {
        setSelection(draft.paths == paths ? [] : paths)
    }

    func setSelection(_ paths: Set<String>) {
        guard !working, draft.submitted == nil else { return }
        guard draft.paths != paths else { return }
        draft.paths = paths
        review = nil
        outcome = nil
    }

    func reconcileAvailablePaths(_ paths: Set<String>) {
        guard !working, draft.submitted == nil, review == nil else { return }
        draft.paths.formIntersection(paths)
    }

    func prepareReview() async {
        guard loaded, !working, draft.submitted == nil, !draft.paths.isEmpty else { return }
        working = true
        defer { working = false }
        let paths = draft.paths
        do {
            guard await service.supportsReviewedCommit() else {
                errorMessage = "Update the connected computer to commit selected files."
                return
            }
            let fresh = try await service.review(paths: paths.sorted())
            guard draft.paths == paths else { return }
            review = fresh
            outcome = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func submit() async {
        guard canCommit, let review else { return }
        working = true
        defer { working = false }
        let submission = GitCommitSubmission(operationID: UUID().uuidString, review: review, message: draft.message)
        canRetrySubmission = false
        draft.submitted = submission
        guard await persist() else { draft.submitted = nil; return }
        do {
            adopt(try await service.commit(submission))
            await persist()
        } catch {
            // No rollback, retry or new ID follows a lost response.
            errorMessage = "The commit outcome has not been confirmed. Check its outcome before starting another. \(error.localizedDescription)"
        }
    }

    func checkOutcome(recover: Bool = false) async {
        guard !working, let submission = draft.submitted else { return }
        working = true
        defer { working = false }
        do {
            if let receipt = try await service.receipt(operationID: submission.operationID, recover: false) {
                canRetrySubmission = false
                if recover && receipt.unresolved,
                   let reconciled = try await service.receipt(operationID: submission.operationID, recover: true) {
                    adopt(reconciled)
                } else { adopt(receipt) }
                await persist()
            } else {
                canRetrySubmission = true
                errorMessage = "The computer has no recorded outcome yet. You can retry this same submission."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retrySubmission() async {
        guard !working, canRetrySubmission, let submission = draft.submitted else { return }
        working = true
        defer { working = false }
        guard await persist() else { return }
        canRetrySubmission = false
        do {
            adopt(try await service.commit(submission))
            await persist()
        } catch { errorMessage = "Check this commit's outcome before starting another. \(error.localizedDescription)" }
    }

    private func adopt(_ receipt: GitCommitReceipt) {
        guard receipt.operationID == draft.submitted?.operationID else { return }
        outcome = receipt
        errorMessage = nil
        if receipt.succeeded {
            draft = GitCommitDraft()
            review = nil
        } else if !receipt.unresolved {
            draft.submitted = nil
            review = nil
        }
    }
}

/// Shared within the current app, scoped by verified account and computer.
/// Returning to a workspace reuses its writing, even after its view was removed.
@MainActor
enum GitCommitSessions {
    private struct Key: Hashable {
        let scope: WorkReference.Scope
        let host: String
        let workspace: String
    }
    private static var sessions: [Key: GitCommitSession] = [:]

    static func session(target: GitCommitTarget) -> GitCommitSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else {
            return GitCommitSession(target: target, scope: nil, hostIdentity: nil)
        }
        let key = Key(scope: scope, host: host, workspace: target.workspaceID)
        if let existing = sessions[key] { return existing }
        let created = GitCommitSession(target: target, scope: scope, hostIdentity: host)
        sessions[key] = created
        return created
    }
}
