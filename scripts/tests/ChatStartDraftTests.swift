// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatStartDraft.swift WorkReference.swift.
import Foundation

@main struct ChatStartDraftTests {
    @MainActor static func main() {
        let alice = WorkReference.Scope.local(installationID: "alice")
        let bob = WorkReference.Scope.local(installationID: "bob")
        let draft = ChatStartDraft()
        draft.activate(scope: alice, session: 1)
        precondition(draft.pending == nil && draft.begin(available: ["repo"]) == nil,
                     "Opening an empty landing page cannot request a conversation")
        draft.text = "Keep the existing chat draft separate"
        precondition(draft.begin(available: ["repo"]) == nil, "Send requires explicit repository selection")
        draft.repositoryID = "repo"
        precondition(draft.begin(available: ["repo"]) == nil, "The selected agent is required before Send")
        draft.agent = .init(backend: "codex", model: "model", effort: nil)
        precondition(draft.pending == nil && draft.text == "Keep the existing chat draft separate",
                     "Choosing or adding a repository only changes local state")
        guard let first = draft.begin(available: ["repo"]) else { preconditionFailure() }
        precondition(draft.begin(available: ["repo"]) == nil, "A double tap cannot create two conversations")
        precondition(first.repositoryID == "repo" && first.text == draft.text)
        draft.failed(first, message: "Host unavailable")
        precondition(draft.pending == nil && draft.repositoryID == "repo" && draft.text == first.text,
                     "Failed creation retains the prompt and repository")
        guard let retry = draft.begin(available: ["repo"]) else { preconditionFailure() }
        draft.retire()
        precondition(!draft.accepts(retry, scope: alice, session: 1) && draft.text == first.text,
                     "Navigation cancels late sends without discarding the landing draft")
        draft.transferred(retry)
        precondition(draft.text == first.text, "A retired completion cannot clear later writing")
        draft.activate(scope: alice, session: 1)
        precondition(draft.text == first.text && draft.repositoryID == "repo", "Returning to the page keeps writing")
        guard let current = draft.begin(available: ["repo"]) else { preconditionFailure() }
        precondition(draft.accepts(current, scope: alice, session: 1))
        precondition(!draft.accepts(current, scope: bob, session: 1)
                     && !draft.accepts(current, scope: alice, session: 2),
                     "Account changes and same-account sign-in replacement invalidate Send")
        draft.activate(scope: alice, session: 2)
        precondition(draft.text == first.text && draft.repositoryID == "repo" && draft.pending == nil,
                     "Re-authentication cancels old operations without dropping same-account writing")
        draft.activate(scope: bob, session: 2)
        precondition(draft.text.isEmpty && draft.repositoryID == nil && !draft.isSubmitting,
                     "Landing writing cannot appear under another account")
        draft.text = "New account prompt"; draft.repositoryID = "other"
        draft.agent = .init(backend: "claude", model: nil, effort: nil)
        let next = draft.begin(available: ["other"])!
        draft.failed(current, message: "Stale error")
        draft.transferred(current)
        precondition(draft.text == "New account prompt" && draft.pending == next.id && draft.error == nil)
        draft.repositoryID = "different"
        precondition(!draft.accepts(next, scope: bob, session: 2), "Changing visible repository invalidates a pending ticket")
        draft.repositoryID = "other"
        draft.text += "!"
        precondition(!draft.accepts(next, scope: bob, session: 2), "Later writing cannot be sent through an earlier captured ticket")
        draft.text = "New account prompt"
        precondition(next.agent.backend == "claude", "Agent/model choice belongs to the Send ticket")
        draft.transferred(next)
        precondition(draft.text.isEmpty && draft.pending == nil && draft.repositoryID == "other",
                     "Only successful transfer into the created conversation clears the prompt")
        draft.text = "Still here"; draft.repositoryID = "removed"
        precondition(draft.begin(available: ["other"]) == nil && draft.text == "Still here",
                     "Removed repositories cannot silently retarget a send")
        draft.repositoryID = "other"
        draft.text = ""
        let empty = draft.begin(available: ["other"])!
        precondition(empty.text.isEmpty, "Explicit Open chat must allow the normal composer for image/file-first messages")
        draft.transferred(empty)
        print("New chat landing: no eager conversation, selection/cancel/failure draft retention, double-send and owner isolation passed")
    }
}
