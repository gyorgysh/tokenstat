// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Local writing belongs to an account and repository. No host conversation
/// exists until an explicit Send/Open chat captures one immutable ticket.
@MainActor @Observable
final class ChatStartDraft {
    struct Owner: Equatable { var scope: WorkReference.Scope; var session: UInt64 }
    struct AgentChoice: Equatable {
        var backend: String
        var model: String?
        var effort: String?
        var mode = "execute"
        var autonomy = "bypass"
        var fastMode = false
    }
    struct Submission {
        let id: UUID
        let owner: Owner
        let repositoryID: String
        let text: String
        let agent: AgentChoice
        let attachments: [ChatAttachment]
        let attachmentReference: WorkReference
    }
    private struct Key: Hashable { var scope: WorkReference.Scope; var repository: String? }
    private struct Writing {
        var text = ""
        var agent: AgentChoice?
        var attachments: [ChatAttachment] = []
        var previews: [String: Data] = [:]
        var localID = UUID().uuidString
    }
    private var writings: [Key: Writing] = [:]
    private var lastRepository: [WorkReference.Scope: String] = [:]
    private var claimedUnbound: Set<WorkReference.Scope> = []
    private var changingOwner = false
    private var localID = UUID().uuidString
    private var importGeneration = UUID()
    private var imports: [String: Int] = [:]
    private var importOwners: [WorkReference: Owner] = [:]
    private(set) var owner: Owner?
    var text = ""
    var agent: AgentChoice?
    var attachments: [ChatAttachment] = []
    var previews: [String: Data] = [:]
    var repositoryID: String? {
        didSet {
            guard !changingOwner, oldValue != repositoryID, let owner else { return }
            save(scope: owner.scope, repository: oldValue)
            let unbound = Key(scope: owner.scope, repository: nil)
            let firstSelection = oldValue == nil && repositoryID != nil && !claimedUnbound.contains(owner.scope)
            if firstSelection, let repositoryID {
                let destination = Key(scope: owner.scope, repository: repositoryID)
                // Claim the initial unbound writing once. Returning through a
                // host picker must never copy it into a second repository.
                if writings[destination] == nil { writings[destination] = writings[unbound] }
                writings[unbound] = nil
                claimedUnbound.insert(owner.scope)
            }
            restore(scope: owner.scope, repository: repositoryID)
            if let repositoryID { remember(repositoryID, for: owner.scope) }
            retire()
        }
    }
    private(set) var pending: UUID?
    private(set) var presentation: UUID?
    private(set) var preparationStartedAt: Double?
    var error: String?
    var isSubmitting: Bool { pending != nil || presentation != nil }
    var attachmentReference: WorkReference? {
        guard let owner else { return nil }
        // The namespace stays stable when initial unbound writing is claimed
        // by its first repository. Neither this ID nor this workspace is sent
        // to Bridge. Individual repository drafts have distinct local IDs.
        return WorkReference(scope: owner.scope, hostIdentity: "new-chat-local", workspaceID: "new-chat-local",
                             kind: .conversation, itemID: localID, anchor: importGeneration.uuidString)
    }
    var stagingAttachments: Int { attachmentReference.flatMap(WorkReferenceKey.conversation).map { imports[$0] ?? 0 } ?? 0 }

    func activate(scope: WorkReference.Scope?, session: UInt64, repositoryID requested: String? = nil) {
        let next = scope.map { Owner(scope: $0, session: session) }
        if owner?.scope != next?.scope {
            if let previous = owner { save(scope: previous.scope, repository: repositoryID) }
            changingOwner = true
            owner = next
            repositoryID = requested ?? scope.flatMap { lastRepository[$0] }
            if let scope { restore(scope: scope, repository: repositoryID) }
            else { apply(Writing()) }
            changingOwner = false
            retire()
        } else if owner != next { owner = next; retire() }
        if let requested { repositoryID = requested }
        if let owner, let parked = writings[Key(scope: owner.scope, repository: repositoryID)], parked.localID == localID {
            for file in parked.attachments where !attachments.contains(where: { $0.id == file.id }) { attachments.append(file) }
            previews = parked.previews.merging(previews) { _, current in current }
        }
    }
    func retire() {
        if let owner { save(scope: owner.scope, repository: repositoryID) }
        pending = nil; presentation = nil; preparationStartedAt = nil
        error = nil; importGeneration = UUID()
    }
    func begin(available: Set<String>) -> Submission? {
        guard !isSubmitting, stagingAttachments == 0, let owner, let repositoryID, let agent,
              let reference = attachmentReference, available.contains(repositoryID) else { return nil }
        let id = UUID(); pending = id; error = nil
        preparationStartedAt = Date.timeIntervalSinceReferenceDate
        return Submission(id: id, owner: owner, repositoryID: repositoryID,
                          text: text.trimmingCharacters(in: .whitespacesAndNewlines), agent: agent,
                          attachments: attachments, attachmentReference: reference)
    }
    func accepts(_ submission: Submission, scope: WorkReference.Scope?, session: UInt64) -> Bool {
        pending == submission.id && owner == submission.owner && repositoryID == submission.repositoryID
            && text.trimmingCharacters(in: .whitespacesAndNewlines) == submission.text && agent == submission.agent
            && attachments == submission.attachments && scope == submission.owner.scope && session == submission.owner.session
    }
    func transferred(_ submission: Submission, preparingPresentation: Bool = false) {
        guard accepts(submission, scope: owner?.scope, session: owner?.session ?? 0) else { return }
        let started = preparationStartedAt
        if let owner { writings[Key(scope: owner.scope, repository: repositoryID)] = Writing(agent: agent, localID: localID) }
        text = ""; attachments = []; previews = [:]
        retire()
        // The real conversation owns the draft now. Keep the transition up
        // while it sends, without leaving another sendable copy on this page.
        if preparingPresentation { presentation = submission.id; preparationStartedAt = started }
    }
    func ownsPresentation(_ submission: Submission, scope: WorkReference.Scope?, session: UInt64) -> Bool {
        presentation == submission.id && owner == submission.owner && repositoryID == submission.repositoryID
            && scope == submission.owner.scope && session == submission.owner.session
    }
    func finishPresentation(_ submission: Submission) {
        guard presentation == submission.id else { return }
        presentation = nil; preparationStartedAt = nil
    }
    func failed(_ submission: Submission, message: String?) {
        guard pending == submission.id, owner == submission.owner else { return }
        pending = nil; preparationStartedAt = nil; error = message
    }
    func beginImport(_ reference: WorkReference) -> Bool {
        guard reference == attachmentReference, !isSubmitting, let owner,
              let key = WorkReferenceKey.conversation(reference) else { return false }
        guard attachments.count + (imports[key] ?? 0) < 20 else {
            error = L10n.text("apple.chatmodel.a_draft_can_include_up_to_20_files_remove.14221a45")
            return false
        }
        imports[key, default: 0] += 1
        importOwners[reference] = owner
        return true
    }
    func finishImport(_ reference: WorkReference, attachment: ChatAttachment?, preview: Data? = nil) {
        guard let importedBy = importOwners[reference], let key = WorkReferenceKey.conversation(reference),
              (imports[key] ?? 0) > 0 else { return }
        imports[key] = max(0, (imports[key] ?? 0) - 1)
        guard let attachment else { return }
        if importedBy == owner, reference.itemID == localID {
            attachments.append(attachment); previews[attachment.id] = preview
        } else {
            // An import already being copied stays with its original draft.
            // Never publish it into a newer repository/presentation.
            guard let key = writings.first(where: { $0.key.scope == reference.scope && $0.value.localID == reference.itemID })?.key,
                  var writing = writings[key] else { return }
            writing.attachments.append(attachment); writing.previews[attachment.id] = preview
            writings[key] = writing
        }
    }
    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }; previews[attachment.id] = nil
        if let owner {
            let key = Key(scope: owner.scope, repository: repositoryID)
            writings[key]?.attachments.removeAll { $0.id == attachment.id }
            writings[key]?.previews[attachment.id] = nil
        }
    }
    /// The repository a new chat opens on, per account. Kept across launches,
    /// so a page that was always opened on one repository does not ask for it
    /// again every morning. It is a local preference and never leaves the
    /// machine.
    private func remember(_ repository: String, for scope: WorkReference.Scope) {
        lastRepository[scope] = repository
        UserDefaults.standard.set(repository, forKey: Self.storageKey(for: scope))
    }

    /// The repository this account last started a chat in, from an earlier
    /// launch. The page applies it only once that repository is in its list,
    /// so a folder removed since then is never selected behind the reader's
    /// back.
    var rememberedRepository: String? {
        guard let owner else { return nil }
        return UserDefaults.standard.string(forKey: Self.storageKey(for: owner.scope))
    }

    private static func storageKey(for scope: WorkReference.Scope) -> String {
        "chatStart.lastRepository.\(scope.kind.rawValue).\(scope.origin).\(scope.identity)"
    }

    private func save(scope: WorkReference.Scope, repository: String?) {
        let key = Key(scope: scope, repository: repository)
        // Preserve imports that finished while this presentation was retired.
        let extra = writings[key].flatMap { $0.localID == localID ? $0 : nil }
        var files = attachments
        for file in extra?.attachments ?? [] where !files.contains(where: { $0.id == file.id }) { files.append(file) }
        writings[key] = Writing(text: text, agent: agent, attachments: files,
                                previews: (extra?.previews ?? [:]).merging(previews) { _, current in current }, localID: localID)
    }
    private func restore(scope: WorkReference.Scope, repository: String?) { apply(writings[Key(scope: scope, repository: repository)] ?? Writing()) }
    private func apply(_ writing: Writing) {
        text = writing.text; agent = writing.agent; attachments = writing.attachments; previews = writing.previews; localID = writing.localID
    }
}
