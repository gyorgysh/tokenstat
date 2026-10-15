// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// The landing page owns writing, never a server-side conversation. A Send
/// ticket captures account/session, repository and words before any await.
@MainActor @Observable
final class ChatStartDraft {
    struct Owner: Equatable {
        var scope: WorkReference.Scope
        var session: UInt64
    }
    struct AgentChoice: Equatable {
        var backend: String
        var model: String?
        var effort: String?
    }
    struct Submission {
        let id: UUID
        let owner: Owner
        let repositoryID: String
        let text: String
        let agent: AgentChoice
    }
    private(set) var owner: Owner?
    var text = ""
    var repositoryID: String?
    var agent: AgentChoice?
    private(set) var pending: UUID?
    var error: String?
    var isSubmitting: Bool { pending != nil }

    func activate(scope: WorkReference.Scope?, session: UInt64, repositoryID: String? = nil) {
        let next = scope.map { Owner(scope: $0, session: session) }
        if owner != next {
            // Re-authentication retires in-flight work, while unsent words
            // still belong to the same account. Another account starts empty.
            if owner?.scope != next?.scope {
                text = ""
                self.repositoryID = nil
                agent = nil
            }
            owner = next
            retire()
        }
        if let repositoryID {
            if self.repositoryID != repositoryID { retire() }
            self.repositoryID = repositoryID
        }
    }
    func retire() { pending = nil; error = nil }
    func begin(available: Set<String>) -> Submission? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending == nil, let owner, let repositoryID, let agent, available.contains(repositoryID) else { return nil }
        let id = UUID()
        pending = id
        error = nil
        return Submission(id: id, owner: owner, repositoryID: repositoryID, text: words, agent: agent)
    }
    func accepts(_ submission: Submission, scope: WorkReference.Scope?, session: UInt64) -> Bool {
        pending == submission.id && owner == submission.owner
            && repositoryID == submission.repositoryID && text.trimmingCharacters(in: .whitespacesAndNewlines) == submission.text
            && agent == submission.agent && scope == submission.owner.scope && session == submission.owner.session
    }
    func transferred(_ submission: Submission) {
        guard accepts(submission, scope: owner?.scope, session: owner?.session ?? 0) else { return }
        text = ""
        retire()
    }
    func failed(_ submission: Submission, message: String?) {
        guard pending == submission.id, owner == submission.owner else { return }
        pending = nil
        error = message
    }
}
