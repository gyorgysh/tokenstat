// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

struct GitPushDraft: Codable, Sendable, Equatable {
    var submitted: GitPushSubmission?
}

@MainActor @Observable
final class GitPushSession {
    let target: GitCommitTarget
    private let service: any GitPushService
    private(set) var review: GitPushReview?
    private(set) var outcome: GitPushReceipt?
    private(set) var draft = GitPushDraft()
    private(set) var working = false
    private(set) var loaded = false
    private(set) var canRetry = false
    private(set) var errorMessage: String?
    private let storage: WorkbenchDraftFile<GitPushDraft>?
    private var revision: String?

    init(target: GitCommitTarget, scope: WorkReference.Scope?, hostIdentity: String?, service: (any GitPushService)? = nil, draftDirectory: URL? = nil) {
        self.target = target
        self.service = service ?? target
        if let scope, let hostIdentity, !hostIdentity.isEmpty {
            let key = WorkReferenceKey.folder(scope: scope, hostIdentity: hostIdentity, workspaceID: target.workspaceID) + "git-push"
            storage = WorkbenchDraftFile(key: key, directory: draftDirectory)
        } else { storage = nil }
    }

    func load() async {
        guard !loaded else { return }
        guard let storage else {
            errorMessage = "Waiting for this account and computer to be verified before saving work."
            return
        }
        do {
            let record = try await storage.load()
            guard !loaded else { return }
            revision = record?.revision
            draft = record?.value ?? GitPushDraft()
            loaded = true
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func prepare() async {
        guard !working else { return }
        await load()
        guard loaded, !working, draft.submitted == nil else { return }
        working = true
        defer { working = false }
        review = nil
        guard await service.supportsReviewedPush() else {
            errorMessage = "Update this computer's tokenstat to review and push a branch from here."
            return
        }
        do {
            review = try await service.pushReview()
            outcome = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func submit() async {
        guard loaded, !working, draft.submitted == nil, let review, !review.upToDate, review.outgoing != 0 else { return }
        working = true
        defer { working = false }
        draft.submitted = GitPushSubmission(operationID: UUID().uuidString, review: review)
        guard await persist() else {
            // No network submission occurred. Reload the other window's
            // operation so it can be checked rather than overwritten.
            draft.submitted = nil
            loaded = false
            await load()
            return
        }
        await send(retry: false)
    }

    func checkOutcome() async {
        guard !working, let submission = draft.submitted else { return }
        working = true
        defer { working = false }
        do {
            if let receipt = try await service.pushReceipt(operationID: submission.operationID, recover: false) {
                if receipt.finished { await adopt(receipt) }
                else if let recovered = try await service.pushReceipt(operationID: submission.operationID, recover: true) {
                    await adopt(recovered)
                }
            } else {
                canRetry = true
                errorMessage = "This computer has no receipt for the submitted push. You can retry the same submission."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() async {
        guard loaded, !working, canRetry, draft.submitted != nil else { return }
        working = true
        defer { working = false }
        guard await persist() else { return }
        await send(retry: true)
    }

    private func send(retry: Bool) async {
        guard let submission = draft.submitted else { return }
        canRetry = false
        do { await adopt(try await service.push(submission, retry: retry)) }
        catch { errorMessage = "The push outcome has not been confirmed. Check its outcome before starting another. \(error.localizedDescription)" }
    }

    private func adopt(_ receipt: GitPushReceipt) async {
        guard receipt.operationID == draft.submitted?.operationID, receipt.review == draft.submitted?.review else { return }
        outcome = receipt
        errorMessage = nil
        canRetry = receipt.retryAllowed
        if receipt.finished { draft.submitted = nil; review = nil }
        if receipt.succeeded { target.notifyChanged() }
        _ = await persist()
    }

    private func persist() async -> Bool {
        guard let storage else { return false }
        do {
            let record = try await storage.save(draft, expectedRevision: revision)
            revision = record.revision
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

@MainActor
enum GitPushSessions {
    private static var sessions: [String: GitPushSession] = [:]
    static func session(target: GitCommitTarget) -> GitPushSession {
        let context = WorkSessionContext.shared
        let host = target.peer ?? context.localHostIdentity
        guard let scope = context.scope, let host else { return GitPushSession(target: target, scope: nil, hostIdentity: nil) }
        let key = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: target.workspaceID)
        if let existing = sessions[key] { return existing }
        let created = GitPushSession(target: target, scope: scope, hostIdentity: host)
        sessions[key] = created
        return created
    }
}
