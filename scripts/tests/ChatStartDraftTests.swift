// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatStartDraft.swift WorkReference.swift.
import Foundation

struct ChatAttachment: Codable, Sendable, Identifiable, Hashable {
    var id: String; var name: String; var mediaType: String?; var size: UInt64?
}

@main struct ChatStartDraftTests {
    @MainActor static func main() {
        let alice = WorkReference.Scope.local(installationID: "alice")
        let bob = WorkReference.Scope.local(installationID: "bob")
        let draft = ChatStartDraft()
        let fresh = ChatStartDraft.AgentChoice(backend: "codex", model: nil, effort: nil)
        precondition(fresh.mode == "execute" && fresh.autonomy == "bypass",
                     "An untouched landing composer starts in Execute/Don't ask before any catalog is loaded")
        let picture = ChatAttachment(id: "local-draft:picture", name: "image.png", mediaType: "image/png", size: 3)
        let second = ChatAttachment(id: "local-draft:second", name: "notes.txt", mediaType: "text/plain", size: 4)
        let codex = ChatStartDraft.AgentChoice(backend: "codex", model: "model", effort: "high", mode: "plan", autonomy: "bypass", fastMode: true)
        draft.activate(scope: alice, session: 1)
        precondition(draft.pending == nil && draft.begin(available: ["repo"]) == nil,
                     "Opening a landing page never requests a conversation")
        draft.text = "Initial writing"
        draft.agent = codex
        let initialReference = draft.attachmentReference!
        precondition(draft.beginImport(initialReference), "Files can be staged before repository selection")
        precondition(draft.stagingAttachments == 1)
        draft.finishImport(initialReference, attachment: picture, preview: Data([1, 2, 3]))
        draft.repositoryID = "repo"
        precondition(draft.text == "Initial writing" && draft.attachments == [picture] && draft.agent == codex)
        precondition(WorkReferenceKey.conversation(draft.attachmentReference!) == WorkReferenceKey.conversation(initialReference),
                     "Initial repository selection preserves the local originals' namespace")
        precondition(!draft.beginImport(initialReference), "A picker captured before repository selection cannot attach afterward")
        let first = draft.begin(available: ["repo"])!
        precondition(first.attachments == [picture] && first.agent.fastMode && first.agent.mode == "plan")
        precondition(draft.begin(available: ["repo"]) == nil, "A double tap cannot create two conversations")
        draft.failed(first, message: "Host unavailable")
        precondition(draft.pending == nil && draft.text == first.text && draft.attachments == [picture],
                     "Creation/staging failures retain the entire source draft")
        draft.repositoryID = "remote:other-host:repo"
        precondition(draft.text.isEmpty && draft.attachments.isEmpty && draft.agent == nil,
                     "Different hosts/repositories have independent unsent writing and setup")
        draft.text = "Other repository"; draft.agent = .init(backend: "claude", model: nil, effort: nil, mode: "plan", autonomy: "standard")
        draft.repositoryID = "repo"
        precondition(draft.text == first.text && draft.attachments == [picture] && draft.agent == codex,
                     "Returning to a repository restores text, files and setup")
        let importOwner = draft.attachmentReference!
        precondition(draft.beginImport(importOwner))
        precondition(draft.begin(available: ["repo"]) == nil, "A half-copied file cannot be omitted by Send")
        draft.repositoryID = "remote:other-host:repo"
        draft.finishImport(importOwner, attachment: second)
        precondition(draft.attachments.isEmpty && draft.text == "Other repository" && draft.agent?.mode == "plan" && draft.agent?.autonomy == "standard", "An in-flight copy cannot move into the newly selected repository")
        draft.repositoryID = "repo"
        precondition(draft.attachments == [picture, second] && draft.stagingAttachments == 0,
                     "An already-started import stays with its original draft")
        let retry = draft.begin(available: ["repo"])!
        draft.retire()
        precondition(!draft.accepts(retry, scope: alice, session: 1) && draft.text == first.text)
        draft.transferred(retry)
        precondition(draft.attachments == [picture, second], "A retired transfer cannot clear current writing")
        let current = draft.begin(available: ["repo"])!
        precondition(draft.accepts(current, scope: alice, session: 1))
        precondition(!draft.accepts(current, scope: bob, session: 1) && !draft.accepts(current, scope: alice, session: 2))
        let oldPicker = draft.attachmentReference!
        draft.activate(scope: alice, session: 2)
        precondition(draft.text == first.text && draft.attachments == [picture, second] && draft.pending == nil)
        precondition(!draft.beginImport(oldPicker), "Same-account sign-in replacement closes old picker/drop ownership")
        draft.activate(scope: bob, session: 3)
        precondition(draft.text.isEmpty && draft.repositoryID == nil && draft.attachments.isEmpty && !draft.isSubmitting)
        draft.failed(current, message: "Stale error"); draft.transferred(current)
        precondition(draft.error == nil && draft.text.isEmpty, "Old-account completions cannot edit new-account writing")
        draft.text = "Bob's draft"; draft.repositoryID = "other"; draft.agent = codex
        let bobTicket = draft.begin(available: ["other"])!
        draft.text += "!"
        precondition(!draft.accepts(bobTicket, scope: bob, session: 3), "Later editing cannot be sent through an earlier ticket")
        draft.failed(bobTicket, message: nil)
        draft.text = "Bob's draft"
        let bobRetry = draft.begin(available: ["other"])!
        draft.transferred(bobRetry)
        precondition(draft.text.isEmpty && draft.attachments.isEmpty && draft.repositoryID == "other" && draft.agent == codex)
        let empty = draft.begin(available: ["other"])!
        precondition(empty.text.isEmpty && empty.attachments.isEmpty, "Explicit Open chat allows an ordinary empty composer without a model turn")
        draft.failed(empty, message: nil)
        draft.repositoryID = nil
        draft.text = "Unbound later"
        draft.repositoryID = "third"
        precondition(draft.text.isEmpty, "Initial unbound text only transfers on the first selection")
        draft.activate(scope: alice, session: 4)
        precondition(draft.repositoryID == "repo" && draft.text == first.text && draft.attachments == [picture, second])
        draft.repositoryID = "removed"
        draft.text = "Still here"; draft.agent = codex
        precondition(draft.begin(available: ["repo"]) == nil && draft.text == "Still here")
        let firstCopy = ChatStartDraft()
        firstCopy.activate(scope: alice, session: 4, repositoryID: "fresh")
        let firstCopyOwner = firstCopy.attachmentReference!
        precondition(firstCopy.beginImport(firstCopyOwner))
        firstCopy.retire()
        firstCopy.finishImport(firstCopyOwner, attachment: picture)
        firstCopy.activate(scope: alice, session: 4)
        precondition(firstCopy.attachments == [picture], "Closing a never-saved repository during its first copy cannot orphan the original")
        let cap = ChatStartDraft(); cap.activate(scope: alice, session: 4, repositoryID: "cap"); cap.agent = codex
        cap.attachments = (0..<20).map { .init(id: "file-\($0)", name: "file", mediaType: nil, size: 1) }
        precondition(!cap.beginImport(cap.attachmentReference!), "The twenty-file limit applies to staged landing files")
        let preparing = ChatStartDraft()
        preparing.activate(scope: alice, session: 4, repositoryID: "fresh")
        preparing.text = "Send once"; preparing.agent = codex; preparing.attachments = [picture]
        let sending = preparing.begin(available: ["fresh"])!
        let began = preparing.preparationStartedAt
        preparing.transferred(sending, preparingPresentation: true)
        precondition(preparing.text.isEmpty && preparing.attachments.isEmpty && preparing.isSubmitting,
                     "The retained conversation owns the only sendable copy while the prism stays up")
        precondition(preparing.preparationStartedAt == began && began != nil,
                     "Transferring ownership must not restart the prism animation")
        precondition(preparing.begin(available: ["fresh"]) == nil)
        precondition(preparing.ownsPresentation(sending, scope: alice, session: 4))
        precondition(!preparing.ownsPresentation(sending, scope: bob, session: 4))
        precondition(!preparing.ownsPresentation(sending, scope: alice, session: 5))
        preparing.retire()
        precondition(!preparing.isSubmitting && !preparing.ownsPresentation(sending, scope: alice, session: 4))
        preparing.activate(scope: alice, session: 4, repositoryID: "fresh")
        precondition(preparing.text.isEmpty && preparing.attachments.isEmpty,
                     "Leaving during preload cannot restore a duplicate of the transferred send")
        preparing.text = "Later message"
        let later = preparing.begin(available: ["fresh"])!
        preparing.transferred(later, preparingPresentation: true)
        preparing.finishPresentation(sending)
        precondition(preparing.ownsPresentation(later, scope: alice, session: 4),
                     "An old preload completion cannot dismiss a newer presentation")
        preparing.finishPresentation(later)
        precondition(!preparing.isSubmitting && preparing.preparationStartedAt == nil)
        print("New chat landing: local attachment ownership, repository/account restoration, one-time unbound carry, stale picker/drop guards, immutable setup, failure retention and explicit empty Open chat passed")
    }
}
