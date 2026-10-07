// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import OSLog
import SwiftUI

@MainActor @Observable
final class ChatModel {
    private struct LaunchChoice: Codable {
        var backend: String
        var model: String?
        var effort: String?
        var mode: String
        var autonomy: String
        /// The persona the last conversation ended up with. Three states, and
        /// they are all different: absent means nothing has been recorded yet
        /// and the workspace default applies, empty means the person chose no
        /// persona, and an id means that one.
        var personaID: String?
    }

    private static let launchChoiceKey = "chat.lastLaunchChoice.v1"
    var chats: [ChatConversation] = [] {
        didSet { noteRunningChats() }
    }
    /// When each known conversation was first seen running, by conversation
    /// id. The host reports only whether a turn is running, so the stamp is
    /// the moment this app observed it: exact for a turn sent from here, a
    /// lower bound for one already going when the list was read. Reconciled
    /// on every list write, so a stopped turn leaves no stamp behind it.
    private var runningSince: [String: Date] = [:]
    /// When this conversation's current turn started, for the Working clock
    /// in the composer and the sidebar. Nil when it is not running.
    func turnStartedAt(for conversationID: String) -> Date? {
        runningSince[conversationID]
    }
    var selected: ChatConversation? {
        didSet {
            noteRunningChats()
            if oldValue?.backend != selected?.backend || oldValue?.running != selected?.running {
                refreshDisplayMetadata()
            }
        }
    }
    private(set) var events: [ChatTimelineEvent] = [] {
        didSet {
            eventsRevision &+= 1
            if events.isEmpty {
                displayCache = []
                displayKey = nil
                foldKey = nil
                hasRunningToolCacheKey = nil
            }
        }
    }
    /// A prompt that has been sent and is not in `events` yet.
    ///
    /// The composer clears on Send. Without this the bubble is missing
    /// until the host answers, and a lazy stack can also skip that first
    /// landing until the next layout.
    private(set) var outgoing: [ChatDisplayItem] = []
    var approvals: [ChatApproval] = []
    /// Whether the live approval list has answered for the current selection.
    /// Until it has, the transcript's own records are the only evidence of a
    /// question still waiting, and one with time left must not read as
    /// expired.
    private(set) var approvalsLoaded = false
    /// What this conversation says to its agent ahead of the person's
    /// words. Read so the inspector can show it rather than describe it.
    var instructions: ChatInstructions?
    /// Whether the instructions read has finished for the current selection.
    /// Once it has, a nil `instructions` means the host could not answer
    /// rather than a load still in flight.
    private(set) var instructionsLoaded = false
    var offset: UInt64 = 0
    @ObservationIgnored private var tailCursor: String?
    /// Asks the host for the page before the oldest one held. Nil once the
    /// beginning of the archive is on screen.
    private(set) var earlierCursor: String?
    /// Whether there is anything before what is held.
    private(set) var hasEarlier = false
    /// An older page is on its way, and the transcript should say so. Quiet
    /// backfill while a conversation opens does not set this: nobody is
    /// waiting at the top of a screen that has not been drawn yet.
    private(set) var loadingEarlier = false
    /// An older page is on its way at all.
    ///
    /// Separate from what the transcript shows, and the reason is that two
    /// loads on one cursor is how a stale cursor gets written back over a
    /// fresh one. Everything that fetches sets this.
    private var earlierInFlight = false
    /// Whether the person has actually paged back in this sitting. Until they
    /// have, saying "start of chat" would be announcing the obvious about a
    /// short conversation.
    private(set) var reachedStart = false
    private(set) var historyTrimmed = false
    /// What the whole conversation has spent, as counted by the host over the
    /// whole archive. Nil on a host that predates paging, and then the meter
    /// folds what is held, which on that host is everything.
    private(set) var conversationUsage: ChatUsageTotals?
    /// Where the host's count stopped. Usage written after this is added on
    /// top of it, so a turn taken while the conversation is open moves the
    /// meter without asking the host to read the archive again.
    private var usageThrough: UInt64?
    /// This host predates `chat.eventPage`, so the timeline is read whole the
    /// way it always was. Latched per model, not per call: a host does not
    /// grow the method while a conversation is open.
    private var pagingUnavailable = false
    var attachments: [ChatAttachment] = []
    /// Downsampled JPEG for the composer strip, keyed by attachment id.
    var attachmentPreviews: [String: Data] = [:]
    private(set) var stagingAttachments = 0
    private(set) var missingDraftAttachments: Set<String> = []
    private var draftAttachmentLoadGeneration = UUID()
    /// Agent-returned file bytes, loaded lazily from the chat's owning host.
    /// The transcript only persists descriptors, so remote files work exactly
    /// like local ones without exposing a host filesystem path to SwiftUI.
    var responseAttachmentData: [String: Data] = [:]
    var backends: [ChatBackend] = []
    var backendRefreshError: String?
    /// A failed authentication attempt is useful evidence even when the CLI's
    /// status command is unavailable. Only the latest turn may offer recovery;
    /// earlier failures in an otherwise working conversation are history.
    private var signInRecovery: ChatAuthenticationFailure.Recovery? {
        guard let selected else { return nil }
        return ChatAuthenticationFailure.latestRecovery(in: displayItems, backend: selected.backend)
    }
    var signInQueuedMessage: ChatQueuedMessage? {
        guard savedCopy == nil, ownsQueue, let selected else { return nil }
        return queued.first { $0.signInBackend == selected.backend && $0.delivery == .waiting }
    }
    var signInGateRowID: String? {
        if let item = signInQueuedMessage { return "signin-gate-\(item.id)" }
        return signInRecovery?.failureID
    }
    var signInFailureID: String? {
        guard let selected, let gate = signInGateRowID else { return nil }
        return "\(selected.id):\(gate)"
    }

    /// Whether this agent's own CLI said it is signed out. Only that stops a
    /// send: a stored token past its expiry is routine (the CLI renews it),
    /// and an agent signed in with an environment key has no login file.
    func needsSignIn(_ backendID: String) -> Bool {
        guard let backend = backend(for: backendID), backend.signInVerified else { return false }
        return ["needsSignIn", "expired"].contains(backend.readiness ?? "")
    }

    enum SignInHold { case notNeeded, held, refused }

    /// Keep a send for after sign-in, when the agent needs one. The Mac and
    /// the phone both submit through here, so they hold the same sends.
    /// Only one message waits: a second is refused and its words stay in the
    /// draft, which is cleared only once the first is safely queued.
    func holdForSignIn(_ text: String, backend backendID: String) -> SignInHold {
        guard needsSignIn(backendID) else { return .notNeeded }
        guard signInQueuedMessage == nil else {
            backendRefreshError = L10n.text("apple.agentsetup.finish_saved")
            return .refused
        }
        guard enqueue(text, awaitingSignIn: true) != nil else { return .refused }
        clearDraft()
        return .held
    }

    /// Explicit Continue reuses durable delivery and receipts, keeping any new
    /// composer draft untouched. A stale card cannot send into a different chat.
    func continueAfterSignIn(gateID: String?, owner: WorkReference?) async {
        guard let owner, owner == currentReference, ownsQueue, savedCopy == nil,
              gateID == signInGateRowID, !busy, !sending, unconfirmedSend == nil, heldSubmission == nil, let selected else { return }
        if needsSignIn(selected.backend) { return }
        do {
            let candidate: ChatQueuedMessage
            if let held = signInQueuedMessage {
                var resumed = held
                resumed.signInBackend = nil
                queued = try ChatOutboxStore.shared.update(owner) { items in
                    guard let index = items.firstIndex(where: { $0.id == held.id }), items[index] == held else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                    items[index] = resumed
                }
                candidate = resumed
            } else if let recovery = signInRecovery {
                var retry = ChatQueuedMessage(id: "signin-retry-\(recovery.failureID)",
                                              text: recovery.text, attachments: recovery.attachments)
                retry.expectedRevision = contextRevision
                queued = try ChatOutboxStore.shared.update(owner) { items in
                    if items.contains(where: { $0.id == retry.id }) { return }
                    guard items.count < ChatOutboxStore.capacity else { throw ChatOutboxStore.Failure.full }
                    items.insert(retry, at: 0)
                }
                guard let stored = queued.first(where: { $0.id == retry.id }), !stored.needsReceipt else { return }
                candidate = stored
            } else { return }
            authorizedQueueItems.insert(candidate.id)
            _ = await deliverQueued(candidate, stopCurrent: false)
        } catch {
            self.error = L10n.text("apple.chatmodel.this_message_could_not_be_saved_to_the_que.95da1002")
        }
    }
    var selectedBackendMissing: Bool {
        backend(for: selected?.backend ?? "")?.installed == false
    }
    var personas: [ChatPersona] = []
    /// New conversations inherit this persona unless the person picks none.
    var defaultPersonaID: String?
    var isLoading = false
    /// The selected conversation's first page is still on its way.
    ///
    /// Separate from `isLoading`, which is about the folder's list. A chat
    /// that has been picked but not yet read back has no rows, and an empty
    /// transcript and an unread one look identical while meaning opposite
    /// things.
    private(set) var openingConversation = false
    var error: String?
    /// What the transcript is showing when the machine cannot be reached.
    ///
    /// Set exactly when the live open failed and a sealed copy was read
    /// instead. While set, the transcript is a snapshot: sending, approvals,
    /// attachment downloads and earlier-page fetches are refused with a
    /// reason, and drafting, copying and reading carry on. A live page
    /// arriving clears it.
    private(set) var savedCopy: SavedCopyInfo?
    /// Rechecks belong to the selection that started them. A slow previous
    /// host must not hold the next conversation's retry button or spinner.
    private var savedCopyCheckGeneration: UInt64?
    var checkingSavedCopy: Bool {
        savedCopyCheckGeneration == selectionGeneration
            && continuityScope == WorkSessionContext.shared.scope
    }
    /// The folder id RootView knows, which is `remote:<peer>:<id>` for a
    /// workspace on another machine. Host methods use `workspaceID` instead.
    private(set) var folderID: String?
    /// The workspace id the owning host stores. Local, even for a remote folder.
    private(set) var workspaceID: String?
    /// Set when this model is talking to a peer over the tunnel.
    private(set) var peer: String?
    /// Whether the peer can take a mid-turn note. Nil until a probe or a
    /// successful steer says so. A failed probe stays nil: an unreachable
    /// computer is not an older one. Local hosts are always current.
    private var remoteSteer: Bool?

    /// Remember a peer change. A different computer has its own protocol, so
    /// a previous answer must not decide the next placeholder.
    private func adoptPeer(_ next: String?) {
        if peer != next {
            remoteSteer = nil
            steerProbeStarted = false
            steerProbeTicket = nil
            steerProbeOwner = nil
        }
        peer = next
    }
    /// Async bridge calls may finish after navigation. Only the generation
    /// that started them may mutate the currently displayed workspace/chat.
    private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var setupLoadTask: Task<Void, Never>?
    private(set) var selectionGeneration: UInt64 = 0
    @ObservationIgnored let viewportContinuity = ChatViewportContinuity()
    /// Conversation a notification asked to open, consumed by the next load.
    private var pendingRevealID: String?
    /// The folder that reveal was asked for, so a load of a different one
    /// cannot answer for it. See the not-found branch in `load`.
    private var pendingRevealFolderID: String?
    // Old unscoped v1 ids cannot prove which account owned them. Leave them
    // untouched rather than silently migrating them into the next account.
    private var continuityScope: WorkReference.Scope?

    private func continuityOwner(folderID: String) -> (scope: WorkReference.Scope, host: String, workspace: String)? {
        guard let scope = continuityScope, scope == WorkSessionContext.shared.readingScope else { return nil }
        let route = WorkDestinationResolver.route(folderID: folderID,
            explicitPeer: folderID == self.folderID ? peer : nil)
        guard let host = route.peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        return (scope, host, route.workspaceID)
    }

    private func rememberedChat(in folderID: String) -> String? {
        guard let owner = continuityOwner(folderID: folderID) else { return nil }
        return WorkContinuityStore.shared.lastConversation(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)?.itemID
    }

    private func rememberLastSelected(chatID: String, folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        WorkContinuityStore.shared.remember(WorkReference(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace,
            kind: .conversation, itemID: chatID))
    }

    private func forgetLastSelected(folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        WorkContinuityStore.shared.forget(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)
    }

    /// A deleted conversation takes its unsent words with it. There is nothing
    /// left to send them to.
    private func forgetDraft(chatID: String, folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        let reference = WorkReference(scope: owner.scope, hostIdentity: owner.host,
            workspaceID: owner.workspace, kind: .conversation, itemID: chatID)
        if draftReference == reference {
            draftReference = nil
            // Keep the old conversation identity until selection swaps the
            // composer. Clearing both would make a nil selection keep its
            // deleted draft, attachments and unresolved receipt in memory.
            draftSaveTask?.cancel()
            draftSaveTask = nil
        }
        ChatDraftStore.shared.clear(for: reference)
        // And the place somebody had reached in it. There is nothing left to
        // come back to.
        ChatReadingStore.shared.forget(for: reference)
    }

    // MARK: - Unsent words

    /// What is in the composer.
    ///
    /// It lives here rather than in the view because it belongs to the
    /// conversation, not to the pane it was typed in. Switching conversations
    /// swaps it, leaving the folder keeps it, and it is on disk within a
    /// third of a second of the last keystroke.
    var draft = "" {
        didSet {
            guard !restoringDraft, draft != oldValue else { return }
            scheduleDraftSave()
        }
    }
    /// The conversation the words in `draft` belong to. Saves use this rather
    /// than recomputing a reference, so a save that lands after the selection
    /// moved still writes to the conversation the words were typed in.
    private var draftReference: WorkReference?
    /// The conversation the composer's words were typed into, known even
    /// before the account and machine identity that key them have arrived.
    private var draftConversationID: String?
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDraft = false
    private var heldSubmission: ChatDraftSubmission?
    /// Context captured before the displayed transcript request, never a newer
    /// metadata-only refresh that the reader has not seen yet.
    private var contextRevision: UInt64?
    /// Long enough that a save is not queued per keystroke, short enough that
    /// nothing meaningful is lost to a crash.
    private static let draftSaveDelay = Duration.milliseconds(300)

    /// The last save did not reach the disk, so the composer is the only copy.
    var draftSaveFailed: Bool { ChatDraftStore.shared.saveFailed }

    /// How to name one of this folder's conversations to the draft store.
    ///
    /// Built by the list once and handed to each row's mark, so the list
    /// itself never reads the store. See `ChatDraftMark`.
    func draftReference(for conversationID: String, in folderID: String) -> WorkReference? {
        guard let owner = continuityOwner(folderID: folderID) else { return nil }
        return WorkReference(scope: owner.scope, hostIdentity: owner.host,
            workspaceID: owner.workspace, kind: .conversation, itemID: conversationID)
    }

    /// How to name the conversation on screen to a device-local store.
    ///
    /// The same reference the draft is filed under, so the words somebody
    /// left and the place they were reading are kept together.
    var currentReference: WorkReference? {
        guard let selected, let folderID else { return nil }
        return draftReference(for: selected.id, in: folderID)
    }

    private var readingRestorationPulse: UInt64 = 0

    var readingIdentity: ChatReadingIdentity {
        ChatReadingIdentity(reference: currentReference, generation: selectionGeneration,
                            restoration: readingRestorationPulse)
    }

    var handoffDraft: WorkSharedDraft {
        WorkSharedDraft(text: draft, attachmentIDs: attachments.map(\.id))
    }

    /// Explicit import is a new local draft, never another device's send.
    /// Compare the snapshot again after metadata resolution so later typing wins.
    func importHandoffDraft(_ shared: WorkSharedDraft, files: [ChatAttachment],
                            replacing expected: WorkSharedDraft, reference: WorkReference) -> Bool {
        guard currentReference == reference, draftReference == reference,
              reference.scope == WorkSessionContext.shared.scope, savedCopy == nil,
              !sending, heldSubmission == nil, unconfirmedSend == nil,
              handoffDraft == expected, files.map(\.id) == shared.attachmentIDs else { return false }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        setDraft(shared.text)
        attachments = files
        attachmentPreviews = [:]
        missingDraftAttachments = []
        draftAttachmentLoadGeneration = UUID()
        ChatDraftStore.shared.save(text: draft, attachments: files, for: reference, newMessage: true)
        return true
    }

    /// A search hit in the already-mounted conversation must move the
    /// viewport too, without changing selection or touching the draft.
    @discardableResult
    func restoreSearchReadingPosition(_ reference: WorkReference) -> Bool {
        guard WorkDestinationResolver.sameConversation(reference, currentReference),
              reference.scope == WorkSessionContext.shared.readingScope,
              let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) else { return false }
        ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date()), for: reference)
        readingRestorationPulse &+= 1
        return true
    }

    func importHandoffAnchor(_ anchor: WorkHandoffAnchor, reference: WorkReference) -> Bool {
        guard currentReference == reference, reference.scope == WorkSessionContext.shared.scope,
              savedCopy == nil, anchor.fraction <= 10_000,
              ChatReadingMark.isStable(eventID: anchor.eventID) else { return false }
        if anchor.followsLatest {
            ChatReadingStore.shared.requestLatest(for: reference)
        } else {
            ChatReadingStore.shared.request(ChatReadingMark(eventID: anchor.eventID, offset: 0,
                updatedAt: Date(), within: Double(anchor.fraction) / 10_000), for: reference)
        }
        readingRestorationPulse &+= 1
        return true
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: ChatModel.draftSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    /// Write the composer out now: leaving the screen, going to the
    /// background, or handing the words to a send.
    func saveDraftNow() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let reference = draftReference else { return }
        // The empty composer is only a presentation change while delivery is
        // pending. Lifecycle saves must leave the durable recovery copy alone.
        guard heldSubmission?.owns(reference: draftReference, conversationID: draftConversationID,
                                   peer: peer, scope: continuityScope) != true else { return }
        ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference)
    }

    /// Try the write again. The words never left the composer, so this is a
    /// retry of the save and not a resend of anything.
    func retryDraftSave() {
        ChatDraftStore.shared.retryFailedSave()
        saveDraftNow()
    }

    /// Point the composer at another conversation: the words on screen go to
    /// the one being left, and the one being opened brings its own back.
    private func loadDraft(for id: String?, scope: WorkReference.Scope?,
                           hostIdentity: String?, workspaceID: String?) {
        saveDraftNow()
        var reference: WorkReference?
        if let id, let scope, let hostIdentity, let workspaceID, !hostIdentity.isEmpty,
           !workspaceID.isEmpty {
            reference = WorkReference(scope: scope, hostIdentity: hostIdentity,
                workspaceID: workspaceID, kind: .conversation, itemID: id)
        }
        let transition = ChatDraftTransition.resolve(incoming: id, reference: reference,
            current: draftConversationID, currentReference: draftReference)
        draftConversationID = id
        draftReference = reference
        switch transition {
        case let .adopt(reference):
            draftReference = reference
            saveDraftNow()
        case .keep:
            break
        case let .swap(reference):
            draftAttachmentLoadGeneration = UUID()
            setDraft("")
            attachments = []
            attachmentPreviews = [:]
            missingDraftAttachments = []
            unconfirmedSend = nil
            guard let reference, let stored = ChatDraftStore.shared.draft(for: reference) else {
                return
            }
            setDraft(stored.text)
            attachments = stored.attachments
            let attachmentLoadGeneration = draftAttachmentLoadGeneration
            Task { [weak self] in
                guard let self else { return }
                for attachment in stored.attachments {
                    let data = try? await ChatLocalAttachmentStore.shared.read(attachment, reference: reference)
                    guard self.draftAttachmentLoadGeneration == attachmentLoadGeneration,
                          self.draftReference == reference, self.attachments.contains(attachment) else { return }
                    if let data {
                        if let preview = ChatThumbnail.make(from: data) { self.attachmentPreviews[attachment.id] = preview }
                    } else { self.missingDraftAttachments.insert(attachment.id) }
                }
            }
        }
    }

    private func loadDraft(for id: String?) {
        guard let id, let folderID, let owner = continuityOwner(folderID: folderID) else {
            loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            return
        }
        loadDraft(for: id, scope: owner.scope, hostIdentity: owner.host,
                  workspaceID: owner.workspace)
    }

    /// Clear the composer without persisting the change: for restoring stored
    /// words, and for a send that has not been answered yet.
    private func setDraft(_ text: String) {
        restoringDraft = true
        draft = text
        restoringDraft = false
    }

    /// Clear the composer but keep the stored copy until the send resolves.
    /// Nothing is lost if the app stops between the two.
    @discardableResult
    func holdDraftForSending(_ text: String) -> Bool {
        guard !selectedBackendMissing, savedCopy == nil, let selected, !sending, stagingAttachments == 0, heldSubmission == nil else { return false }
        saveDraftNow()
        if let pending = queued.first(where: { $0.id == draftMessageID && $0.needsReceipt }) {
            unconfirmedSend = .init(conversationID: selected.id, messageID: pending.id, checking: false)
            error = L10n.text("apple.chatmodel.check_delivery_before_sending_this_draft_a.7ce8d3db")
            return false
        }
        if let previous = queued.first(where: { $0.id == draftMessageID }),
           previous.text != text || previous.attachments != attachments {
            guard let reference = draftReference, previous.canEdit else { return false }
            do {
                queued = try ChatOutboxStore.shared.update(reference) { items in
                    guard let index = items.firstIndex(where: { $0.id == previous.id }),
                          items[index] == previous else { throw ChatOutboxStore.Failure.conflict }
                    items.remove(at: index)
                }
                ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference, newMessage: true)
            } catch {
                self.error = L10n.text("apple.chatmodel.the_pending_message_changed_review_pending.99de1c5d")
                return false
            }
        }
        heldSubmission = ChatDraftSubmission(
            conversationID: selected.id, peer: peer, scope: continuityScope,
            reference: draftReference, generation: selectionGeneration,
            text: text, draftText: draft, attachments: attachments,
            messageID: draftMessageID, expectedRevision: contextRevision
        )
        // Reserve the send before the caller starts its Task or capability
        // discovery suspends, so a second click cannot replace this snapshot.
        composerSendToken = noteSendStarted()
        setDraft("")
        return true
    }

    /// The host took the words, or they moved to the queue.
    func clearDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        setDraft("")
        if let reference = draftReference { ChatDraftStore.shared.clear(for: reference) }
    }

    /// The send did not happen. Put the words back where they were typed.
    func returnDraft(_ text: String) {
        guard draft.isEmpty else { return }
        setDraft(text)
    }

    /// The name this draft's words travel under. Minted with the draft and
    /// kept for as long as it exists, so sending again is the same message
    /// rather than a second one.
    private var draftMessageID: String? {
        guard let draftReference else { return nil }
        return ChatDraftStore.shared.draft(for: draftReference)?.messageID
    }

    // MARK: - Sends that are not confirmed

    /// A message the machine had and did not answer for.
    ///
    /// Neither failure nor success. Keep the original payload and check its
    /// receipt before any retry. An expired receipt cannot prove non-delivery.
    struct UnconfirmedSend: Equatable, Sendable {
        let conversationID: String
        let messageID: String
        var checking: Bool
    }

    private(set) var unconfirmedSend: UnconfirmedSend?
    /// Probe when acting. An unavailable computer is not an older host, and
    /// a failed probe must not remain cached after reconnection or an update.
    private func machineConfirmsSends(peer: String?, checkingReceipt: Bool) async throws -> Bool {
        guard let peer, !peer.isEmpty else { return true }
        let version = try await Bridge.peerProtocolVersion(peer)
        // Reading an older receipt is safe. New sends require revision-checked protocol 14.
        return version >= (checkingReceipt ? 10 : RemoteHostFeature.confirmedSend.minimumProtocol)
    }

    /// Send what is in the composer.
    ///
    /// The composer is emptied by the caller and the stored copy is kept, so
    /// the words exist somewhere at every moment. They come back on a refusal,
    /// and on a machine that did not answer they come back with a note saying
    /// so rather than a claim in either direction.
    func sendFromComposer() async {
        guard let submission = heldSubmission else { return }
        let outer = composerSendToken
        defer {
            heldSubmission = nil
            deliveringFromComposer = nil
            if let outer { noteSendFinished(outer) }
        }
        guard let reference = submission.reference, let messageID = submission.messageID,
              submission.owns(reference: currentReference, conversationID: selected?.id,
                              peer: peer, scope: WorkSessionContext.shared.scope) else {
            restoreSubmission(submission)
            return
        }
        do {
            var candidate = ChatQueuedMessage(id: messageID, text: submission.text, attachments: submission.attachments)
            candidate.sourceDraftText = submission.draftText
            candidate.expectedRevision = submission.expectedRevision
            queued = try ChatOutboxStore.shared.update(reference) { items in
                if let existing = items.first(where: { $0.id == messageID }) {
                    guard existing.text == candidate.text, existing.attachments == candidate.attachments else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                } else { items.append(candidate) }
            }
            guard let item = queued.first(where: { $0.id == messageID }) else { throw ChatOutboxStore.Failure.invalid }
            deliveringFromComposer = messageID
            let accepted = await deliverQueued(item, stopCurrent: false, reserved: true)
            if !accepted {
                restoreSubmission(submission)
                if submission.owns(reference: currentReference, conversationID: selected?.id,
                                   peer: peer, scope: WorkSessionContext.shared.scope),
                   queued.contains(where: { $0.id == messageID && $0.needsReceipt }) {
                    unconfirmedSend = .init(conversationID: submission.conversationID, messageID: messageID, checking: false)
                }
            }
        } catch {
            restoreSubmission(submission)
            if currentReference == reference {
                self.error = L10n.text("apple.chatmodel.this_message_could_not_be_safely_saved_for.35073d4d")
            }
        }
    }

    private func clearSubmittedDraft(_ item: ChatQueuedMessage, reference: WorkReference) {
        let text = item.sourceDraftText ?? item.text
        let stored = ChatDraftStore.shared.draft(for: reference)
        let ownsDraft = stored?.messageID == item.id
        if let stored, ownsDraft, stored.text == text, stored.attachments == item.attachments {
            ChatDraftStore.shared.clear(stored)
        }
        guard currentReference == reference else { return }
        if ownsDraft, draft.isEmpty || draft == text {
            setDraft("")
            let sent = Set(item.attachments.map(\.id))
            attachments.removeAll { sent.contains($0.id) }
            for id in sent { attachmentPreviews.removeValue(forKey: id) }
        }
        if unconfirmedSend?.messageID == item.id { unconfirmedSend = nil }
    }

    private func restoreSubmission(_ submission: ChatDraftSubmission) {
        guard submission.owns(reference: draftReference, conversationID: selected?.id,
                              peer: peer, scope: WorkSessionContext.shared.scope) else { return }
        returnDraft(submission.draftText)
    }

    /// Ask the machine what became of a message it never answered for.
    func checkUnconfirmedSend() async {
        guard savedCopy == nil, let pending = unconfirmedSend, !pending.checking,
              let reference = currentReference, reference.itemID == pending.conversationID,
              WorkCacheAccess.canSave(reference) else { return }
        unconfirmedSend?.checking = true
        defer { if unconfirmedSend?.messageID == pending.messageID { unconfirmedSend?.checking = false } }
        do {
            guard let item = try ChatOutboxStore.shared.items(for: reference).first(where: { $0.id == pending.messageID }) else {
                // A legacy unresolved send has no durable payload to compare.
                // Never interpret a missing record or receipt as permission to replay.
                error = L10n.text("apple.chatmodel.review_the_conversation_before_starting_a.51f999d2")
                return
            }
            _ = await deliverQueued(item, stopCurrent: false)
        } catch { self.error = L10n.text("apple.chatmodel.pending_delivery_could_not_be_read_your_dr.8bf84006") }
    }

    @ObservationIgnored private var recentMessages = ChatRecentMessages<ChatDisplayItem>()
    @ObservationIgnored private var steerOverlay = ChatSteerOverlay()
    @ObservationIgnored private var listMutations = ChatListMutations<ChatConversation>()
    private struct ChatListRead {
        let steer: ChatSteerOverlay.Read
        let mutations: ChatListMutations<ChatConversation>.Read
    }

    private func beginChatListRead(workspaceID: String, peer: String?, scope: WorkReference.Scope? = nil) -> ChatListRead? {
        guard let scope = scope ?? continuityScope,
              scope == WorkSessionContext.shared.scope,
              let host = peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        let owner = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: workspaceID)
        return ChatListRead(steer: steerOverlay.beginRead(owner: owner), mutations: listMutations.beginRead(owner: owner))
    }

    private func applyChatList(_ rows: [ChatConversation], read: ChatListRead?, current: [ChatConversation]) -> [ChatConversation] {
        guard let read else { return rows }
        return steerOverlay.apply(listMutations.apply(rows, read: read.mutations, current: current), read: read.steer, current: current)
    }

    private func steerMutationSnapshot(_ reference: WorkReference) -> ChatSteerOverlay.Mutation? {
        guard reference.scope == WorkSessionContext.shared.scope, let id = reference.itemID else { return nil }
        let owner = WorkReferenceKey.folder(scope: reference.scope, hostIdentity: reference.hostIdentity,
                                           workspaceID: reference.workspaceID)
        return steerOverlay.mutation(owner: owner, conversationID: id)
    }

    @discardableResult
    private func rememberSteerMutation(_ reference: WorkReference, note: String?,
                                       since mutation: ChatSteerOverlay.Mutation? = nil) -> Bool {
        guard reference.scope == WorkSessionContext.shared.scope, let id = reference.itemID else { return false }
        let owner = WorkReferenceKey.folder(scope: reference.scope, hostIdentity: reference.hostIdentity,
                                           workspaceID: reference.workspaceID)
        return steerOverlay.remember(owner: owner, conversationID: id, note: note, ifUnchangedSince: mutation)
    }
    @ObservationIgnored private var previewWarmTask: Task<Void, Never>?
    /// Chats waiting to be warmed, for one account, host and project.
    @ObservationIgnored private var warmQueue: [ChatConversation] = []
    @ObservationIgnored private var warmQueueOwner: String?
    @ObservationIgnored private var warmGeneration: UInt64 = 0
    @ObservationIgnored private var previewCacheEpoch: UInt64 = 0
    private(set) var recentMessagePreview: [ChatDisplayItem] = []

    /// The transcript reads the preview, so an empty write to an empty
    /// preview still redrew it.
    private func clearRecentMessagePreview() {
        if !recentMessagePreview.isEmpty { recentMessagePreview = [] }
    }

    @ObservationIgnored private var previewReads: Set<String> = []

    private func cancelPreviewWarmup() {
        warmGeneration &+= 1
        previewWarmTask?.cancel()
        previewWarmTask = nil
        warmQueue = []
        warmQueueOwner = nil
    }

    /// A row's cancellable dwell task calls this without selecting the chat.
    /// Uses the same bounded preview cache and account/host keys as opening.
    func warmConversationPreview(_ conversation: ChatConversation, in folder: String) async {
        #if os(macOS)
        guard !Task.isCancelled, !pagingUnavailable,
              !(folderID == folder && selected?.id == conversation.id),
              let owner = continuityOwner(folderID: folder),
              owner.scope == WorkSessionContext.shared.scope else { return }
        let key = WorkReferenceKey.folder(scope: owner.scope, hostIdentity: owner.host,
            workspaceID: owner.workspace) + WorkReferenceKey.encode(conversation.id)
        guard !recentMessages.contains(key),
              previewReads.count < 2,
              previewReads.insert(key).inserted else { return }
        defer { previewReads.remove(key) }
        let epoch = previewCacheEpoch
        let route = WorkDestinationResolver.route(folderID: folder,
            explicitPeer: folder == folderID ? peer : nil)
        do {
            let page = try await Bridge.chatEventPage(id: conversation.id, cursor: nil,
                limit: ChatPaging.previewPageEvents, peer: route.peer)
            guard !Task.isCancelled, WorkSessionContext.shared.scope == owner.scope,
                  continuityScope == owner.scope, previewCacheEpoch == epoch,
                  !recentMessages.contains(key),
                  !(folderID == folder && selected?.id == conversation.id) else { return }
            let rows = ChatDisplayItem.coalesce(page.events,
                defaultBackend: conversation.backend, running: conversation.running)
            recentMessages.store(rows, for: key, speculative: true) { String(reflecting: $0).utf8.count }
            DiagnosticsLog.note("chat preview prepared source=hover rows=\(rows.count) held=\(recentMessages.contains(key))")
            Self.warmMarkdown(recentMessages.peek(key))
        } catch { /* Opening still performs its normal fresh read. */ }
        #endif
    }

    /// Opening a project's sessions also prepares its recent chat previews,
    /// without changing the active conversation or starting an agent.
    func warmWorkspacePreviews(_ folder: String, includeMessages: Bool = true) async {
        #if os(macOS)
        let scope = WorkSessionContext.shared.scope
        let epoch = previewCacheEpoch
        let route = Bridge.chatRoute(workspaceID: folder, peer: nil)
        if route.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
        guard let scope, let host = route.peer ?? WorkSessionContext.shared.localHostIdentity,
              !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
        let listRead = beginChatListRead(workspaceID: route.workspaceID, peer: route.peer, scope: scope)
        do {
            let answer = try await Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                  previewCacheEpoch == epoch else { return }
            if continuityScope == nil { continuityScope = scope }
            guard continuityScope == scope else { return }
            let list = applyChatList(answer, read: listRead, current: sidebarChats(in: folder))
            storeChatListCache(Self.uniqued(list), folderID: folder)
            // Expanded sidebar projects need titles, not every transcript.
            // Leave message warming to hover or explicitly opening a project.
            guard includeMessages else { return }
            let prefix = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: route.workspaceID)
            let worth = Self.uniqued(list).filter { !isUnused($0, in: folder) }
            let candidates = ChatHistoryWindow.previews(in: worth,
                limit: ChatRecentMessages<ChatDisplayItem>.perFolderLimit) {
                    folderID == folder && selected?.id == $0.id
                }
            for chat in candidates {
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                      previewCacheEpoch == epoch else { return }
                if folderID == folder && selected?.id == chat.id { continue }
                let key = prefix + WorkReferenceKey.encode(chat.id)
                if recentMessages.contains(key) { continue }
                while previewReads.count >= 2 {
                    try await Task.sleep(for: .milliseconds(40))
                    guard scope == WorkSessionContext.shared.scope,
                          previewCacheEpoch == epoch else { return }
                }
                if recentMessages.contains(key) || (folderID == folder && selected?.id == chat.id) { continue }
                guard previewReads.insert(key).inserted else { continue }
                defer { previewReads.remove(key) }
                do {
                    let page = try await Bridge.chatEventPage(id: chat.id, cursor: nil,
                        limit: ChatPaging.previewPageEvents, peer: route.peer)
                    guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                          previewCacheEpoch == epoch else { return }
                    if recentMessages.contains(key) || (folderID == folder && selected?.id == chat.id) { continue }
                    let rows = ChatDisplayItem.coalesce(page.events,
                        defaultBackend: chat.backend, running: chat.running)
                    recentMessages.store(rows, for: key, speculative: true) {
                        String(reflecting: $0).utf8.count
                    }
                    DiagnosticsLog.note("chat preview prepared source=workspace rows=\(rows.count) held=\(recentMessages.contains(key))")
                    Self.warmMarkdown(recentMessages.peek(key))
                } catch {
                    // One unavailable conversation must not stop the rest.
                    continue
                }
            }
        } catch { /* A preview failure leaves normal opening available. */ }
        #endif
    }

    /// Speculative reads use the same small, memory-only preview as a chat
    /// just left. Never fall back to the legacy whole-conversation endpoint.
    ///
    /// A queue per project rather than one task per call. Every selection
    /// used to cancel the warm-up in flight and start one for the next three
    /// chats, so a person moving around a project never got past the first
    /// few and came back to chats that opened cold. Now a selection adds to
    /// the queue, and only a change of project throws it away.
    private func warmRecentChats() {
        #if os(macOS)
        guard !pagingUnavailable, let folderID,
              let owner = continuityOwner(folderID: folderID),
              owner.scope == WorkSessionContext.shared.scope else { return }
        let prefix = WorkReferenceKey.folder(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)
        if warmQueueOwner != prefix {
            cancelPreviewWarmup()
            warmQueueOwner = prefix
        }
        // The chats the sidebar shows. Empty New chats have nothing to read,
        // and a project with twenty of them at the top spent every warm read
        // on those and never reached a real conversation.
        let worth = chats.filter { !isUnused($0, in: folderID) }
        let candidates = ChatHistoryWindow.previews(in: worth,
            limit: ChatRecentMessages<ChatDisplayItem>.perFolderLimit) { $0.id == selected?.id }
        for chat in candidates where !recentMessages.contains(prefix + WorkReferenceKey.encode(chat.id))
            && !warmQueue.contains(where: { $0.id == chat.id }) {
            warmQueue.append(chat)
        }
        guard previewWarmTask == nil, !warmQueue.isEmpty else { return }
        let peer = self.peer
        warmGeneration &+= 1
        let generation = warmGeneration
        previewWarmTask = Task { [weak self] in
            defer {
                if let self, self.warmGeneration == generation { self.previewWarmTask = nil }
            }
            // Let the selected conversation and its first frame finish first.
            try? await Task.sleep(for: .milliseconds(250))
            while let self, !Task.isCancelled, !self.warmQueue.isEmpty,
                  self.warmGeneration == generation, self.warmQueueOwner == prefix,
                  self.folderID == folderID, self.continuityScope == owner.scope,
                  WorkSessionContext.shared.scope == owner.scope {
                if self.previewReads.count >= 2 {
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                    continue
                }
                let chat = self.warmQueue.removeFirst()
                let key = prefix + WorkReferenceKey.encode(chat.id)
                guard self.selected?.id != chat.id,
                      self.chats.contains(where: { $0.id == chat.id }),
                      !self.recentMessages.contains(key),
                      self.previewReads.insert(key).inserted else { continue }
                defer { self.previewReads.remove(key) }
                let epoch = self.previewCacheEpoch
                do {
                    let page = try await Bridge.chatEventPage(id: chat.id, cursor: nil,
                        limit: ChatPaging.previewPageEvents, peer: peer)
                    guard !Task.isCancelled, self.folderID == folderID,
                          self.warmGeneration == generation,
                          WorkSessionContext.shared.scope == owner.scope else { break }
                    // Opened while this was reading: the live page owns it.
                    guard self.selected?.id != chat.id,
                          !self.recentMessages.contains(key),
                          self.previewCacheEpoch == epoch else { continue }
                    let rows = ChatDisplayItem.coalesce(page.events,
                        defaultBackend: chat.backend, running: chat.running)
                    self.recentMessages.store(rows, for: key, speculative: true) { String(reflecting: $0).utf8.count }
                    DiagnosticsLog.note("chat preview prepared source=recent rows=\(rows.count) held=\(self.recentMessages.contains(key))")
                    Self.warmMarkdown(self.recentMessages.peek(key))
                } catch {
                    // Warming is optional. One failed read skips that chat.
                    continue
                }
            }
        }
        #endif
    }

    var isShowingCachedTranscript: Bool { openingConversation && !recentMessagePreview.isEmpty }
    /// The rows a transcript draws: the conversation folded to the chosen
    /// detail level. `displayItems` stays every row, for anything that has
    /// to see a step whether or not it is folded away.
    var transcriptItems: [ChatDisplayItem] {
        let detail = ChatDetailPreference.shared.level
        // Read before the cache check, so Observation sees both every time.
        let open = groupsOpen
        let toggled = toggledGroups
        if isShowingCachedTranscript {
            // A preview is one window of rows, briefly, while a chat opens.
            return ChatTranscriptFold.fold(ChatAuthenticationFailure.presented(recentMessagePreview), detail: detail, running: false) { open != toggled.contains($0) }
        }
        let pending = outgoing
        let rows = coalescedItems
        let key = FoldKey(display: displayKey, detail: detail, open: open, toggled: toggled)
        if key != foldKey {
            foldCache = ChatTranscriptFold.fold(ChatAuthenticationFailure.presented(rows), detail: detail, running: selected?.running == true) {
                open != toggled.contains($0)
            }
            foldKey = key
        }
        var shown = pending.isEmpty ? foldCache : foldCache + pending
        if let item = signInQueuedMessage {
            shown.append(ChatDisplayItem(id: "signin-message-\(item.id)", kind: .user(item.text)))
            shown += item.attachments.map { ChatDisplayItem(id: "signin-attachment-\(item.id)-\($0.id)", kind: .attachment($0)) }
            shown.append(ChatDisplayItem(id: "signin-gate-\(item.id)", kind: .failed("")))
        }
        return shown
    }

    /// Every group starts open (Expand all) or closed. A group in
    /// `toggledGroups` is the other way, because a person opened or closed it.
    private(set) var groupsOpen = false
    private(set) var toggledGroups: Set<String> = []

    func toggleGroup(_ id: String) {
        if toggledGroups.contains(id) { toggledGroups.remove(id) } else { toggledGroups.insert(id) }
    }

    func setAllGroups(open: Bool) {
        groupsOpen = open
        toggledGroups = []
    }

    /// Whether Expand all is in force or a group was opened by hand. Read
    /// from the two flags rather than the rows, so the menus that ask do not
    /// redraw on every streamed token.
    var anyGroupOpen: Bool { groupsOpen || !toggledGroups.isEmpty }

    /// The row to scroll to for `id`. A step folded into a closed group
    /// opens that group, so a search hit or a kept reading place lands on
    /// the step itself rather than on a line that hides it.
    @discardableResult
    func revealRow(_ id: String) -> String {
        guard let owner = ChatTranscriptFold.owner(of: id, in: transcriptItems) else { return id }
        toggleGroup(owner)
        return id
    }

    /// Where a kept reading place lands. A mark taken on a closed group's
    /// header is saved as that group's first step, so it comes back to the
    /// header rather than opening a group the person left closed.
    func readingRow(_ id: String) -> String {
        let header = ChatTranscriptFold.groupID(firstMember: id)
        if ChatTranscriptFold.owner(of: id, in: transcriptItems) == header { return header }
        return revealRow(id)
    }

    private func rememberRecentMessages() {
        guard savedCopy == nil, let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope,
              chats.contains(where: { $0.id == selected?.id }),
              let key = WorkReferenceKey.conversation(reference), !events.isEmpty else { return }
        // Preserve every row kind and its identity, including reasoning,
        // failures, tools and edits. No downloaded attachment bytes are held.
        let rows = Array(displayItems.suffix(TranscriptSlice.length))
        recentMessages.store(rows, for: key) { row in
            // Include nested tool output and patch strings in the budget.
            String(reflecting: row).utf8.count
        }
    }

    private func restoreRecentMessages() {
        clearRecentMessagePreview()
        guard let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope,
              let key = WorkReferenceKey.conversation(reference) else { return }
        let preview = recentMessages.messages(for: key)
        #if os(macOS)
        DiagnosticsLog.note("chat preview cache \(preview.isEmpty ? "miss" : "hit") rows=\(preview.count)")
        #endif
        if preview != recentMessagePreview { recentMessagePreview = preview }
    }

    /// Adjacent conversation in sidebar order, looping inside the warm ten.
    /// A held arrow key cycles those instead of stopping dead or walking
    /// the archive; older chats live behind See-all. The sidebar draws the
    /// same window, so every landing is already on screen.
    func adjacentConversation(_ step: Int) -> ChatConversation? {
        // The rows the sidebar draws, in its order. Stepping over the list
        // it hides landed on an empty chat that had no row to light, so the
        // arrows looked as if they had selected nothing.
        let rows = folderID.map { folder in chats.filter { !isUntouched($0, in: folder) } } ?? chats
        guard !rows.isEmpty, step == -1 || step == 1 else { return nil }
        let current = rows.firstIndex(where: { $0.id == selected?.id })
        guard let next = ChatHistoryWindow.looped(count: rows.count, current: current, step: step),
              rows.indices.contains(next) else {
            return nil
        }
        return rows[next]
    }

    /// Conversation lists read earlier this session, keyed by the folder id
    /// the sidebar knows (`remote:<peer>:<id>` for a folder on another
    /// machine). The model holds one folder's live list, while the cache lets
    /// the sidebar keep every opened folder's chats on screen, so opening a
    /// chat in one project does not collapse the one just left in another.
    /// Small records only, never transcripts. Refreshed on every open, so a
    /// stale entry lasts until its folder is opened again.
    private var chatListCache: [String: [ChatConversation]] = [:]
    private static let chatListCacheCap = 30

    /// The conversations to draw under this folder in the sidebar. The live
    /// list for the folder on screen, otherwise what its last load read, or
    /// nothing when the folder has not been opened in this session.
    /// A chat that was opened and never used: still the host's default
    /// title, no message either way, nothing running and no unsent words.
    ///
    /// The sidebar leaves these out, so a row of "New chat" left behind by
    /// every press of New chat does not bury the conversations that have
    /// something in them. The one on screen always stays. All four tests
    /// are needed: a host too old to send `lastMessageAtMs` still renames a
    /// chat from its first prompt, so the title alone keeps its chats. The
    /// draft is read without observing, so typing never lays the list out
    /// again. Leaving the chat changes the selection, and that is when the
    /// list asks.
    func isUntouched(_ conversation: ChatConversation, in folderID: String) -> Bool {
        conversation.id != selected?.id && isUnused(conversation, in: folderID)
    }

    /// The same test without the exemption for the chat on screen, for
    /// places that list work to go back to. An empty chat is nothing to
    /// continue, even while it is still the selection.
    func isUnused(_ conversation: ChatConversation, in folderID: String) -> Bool {
        guard conversation.title == "New chat",
              conversation.lastMessageAtMs == nil,
              !conversation.running
        else { return false }
        guard let reference = draftReference(for: conversation.id, in: folderID) else { return true }
        return ChatDraftStore.shared.draft(for: reference) == nil
    }

    func sidebarChats(in folderID: String) -> [ChatConversation] {
        guard continuityScope == WorkSessionContext.shared.scope else { return [] }
        if self.folderID == folderID { return chats }
        return chatListCache[folderID] ?? []
    }

    /// Written only when it changed. The cache is observed as one value, so
    /// any write redraws every folder's rows in the sidebar, and a reload that
    /// returns the same list is the usual case.
    private func storeChatListCache(_ list: [ChatConversation], folderID: String) {
        guard chatListCache[folderID] != list else { return }
        chatListCache[folderID] = list
        if chatListCache.count > Self.chatListCacheCap,
           let drop = chatListCache.keys.first(where: { $0 != folderID }) {
            chatListCache.removeValue(forKey: drop)
        }
        noteRunningChats()
    }

    /// Stamp newly running conversations, drop stopped ones. Reads every
    /// list the model holds, because the sidebar draws cached folders the
    /// live list does not currently cover, and a stamp must live exactly as
    /// long as its row claims Working: both correct together on the next
    /// read of that folder. Runs from `chats`'s didSet, which also fires for
    /// element writes like the accepted-send path's `replace`, so no send
    /// site stamps anything itself.
    private func noteRunningChats() {
        var running = Set<String>()
        for conversation in chats where conversation.running {
            running.insert(conversation.id)
        }
        if let selected, selected.running {
            running.insert(selected.id)
        }
        for list in chatListCache.values {
            for conversation in list where conversation.running {
                running.insert(conversation.id)
            }
        }
        let next = reconcileRunningSince(runningSince, running: running, now: Date())
        if next != runningSince {
            runningSince = next
        }
    }

    private var attachmentCacheGeneration: UInt64 = 0
    private var attemptedResponseAttachments: Set<String> = []
    @ObservationIgnored private var attachmentDescriptorRevision: UInt64?
    @ObservationIgnored private var attachmentDescriptors: [ChatAttachment] = []
    private(set) var loadingResponseAttachments: Set<String> = []
    private(set) var responseAttachmentErrors: [String: String] = [:]

    /// Whether this model has answered for the folder on screen.
    ///
    /// Nothing may draw "no conversations here" before this is true: the
    /// pane would promise an empty folder and then contradict itself.
    func isReady(for workspaceID: String) -> Bool {
        folderID == workspaceID && !isLoading
    }

    func count(in workspaceID: String) -> Int {
        guard folderID == workspaceID || self.workspaceID == workspaceID else { return 0 }
        return chats.count
    }

    func load(workspaceID: String, peer: String? = nil, selectFirst: Bool = true) async {
        let route = Bridge.chatRoute(workspaceID: workspaceID, peer: peer)
        let scope = WorkSessionContext.shared.scope
        // Keep the conversation being left while the model still describes
        // it. Once the list below is another project's, this chat is no
        // longer in it and would not be kept, so coming back opened cold.
        if folderID != workspaceID || self.workspaceID != route.workspaceID
            || self.peer != route.peer || continuityScope != scope {
            rememberRecentMessages()
            cancelPreviewWarmup()
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        let probe = Logger(subsystem: "ai.tokenstat.tokenstat", category: "chatload")
        probe.error("load start ws=\(workspaceID) gen=\(generation) scope=\(String(describing: WorkSessionContext.shared.scope?.identity)) selectFirst=\(selectFirst)")
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        if route.peer == nil {
            await WorkSessionContext.shared.resolveLocalHostIdentity()
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
        }
        let rememberedID: String?
        if let scope, let host = route.peer ?? WorkSessionContext.shared.localHostIdentity {
            rememberedID = WorkContinuityStore.shared.lastConversation(scope: scope,
                hostIdentity: host, workspaceID: route.workspaceID)?.itemID
        } else {
            rememberedID = nil
        }
        if continuityScope != scope {
            // A different account, rather than the first one arriving: these
            // words belong to the account being left, where they were kept.
            if let previous = continuityScope, let scope, previous != scope {
                loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            }
            chatListCache = [:]
            backends = []
            personas = []
            defaultPersonaID = nil
            backendRefreshError = nil
            steerOverlay.removeAll()
            listMutations.removeAll()
            noteRunningChats()
            previewCacheEpoch &+= 1
            recentMessages.removeAll()
            clearRecentMessagePreview()
            chats = []
            selected = nil
            folderID = nil
            continuityScope = scope
        }
        let draftHost = route.peer ?? WorkSessionContext.shared.localHostIdentity
        if folderID != workspaceID || self.workspaceID != route.workspaceID || self.peer != route.peer {
            clearRecentMessagePreview()
            personas = []
            defaultPersonaID = nil
            if self.peer != route.peer {
                pagingUnavailable = false
                backends = []
                backendRefreshError = nil
            }
            // The folder is changing. Remember which conversation was open
            // before the clear below drops it, or coming back can only ever
            // find the first row.
            if let selected, let old = folderID {
                rememberLastSelected(chatID: selected.id, folderID: old)
            }
            if let old = folderID, !chats.isEmpty {
                storeChatListCache(chats, folderID: old)
            }
            if selectFirst, let cached = chatListCache[workspaceID] {
                // Opened before. Show its remembered conversation at once,
                // from the cache, while the refresh below re-reads the list.
                // Clicking the Chat row then opens the last chat rather than
                // an empty loading state, and the transcript fetch runs once,
                // after the list confirms what is still there.
                if let pending = pendingRevealID,
                   (pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID),
                   let found = cached.first(where: { $0.id == pending }) {
                    selected = found
                } else if let remembered = rememberedID,
                          let found = cached.first(where: { $0.id == remembered }) {
                    selected = found
                } else {
                    selected = cached.first
                }
                chats = cached
                events = []
                outgoing = []
                outgoingWatermark = [:]
                approvals = []
                approvalsLoaded = false
                instructions = nil
                instructionsLoaded = false
                responseAttachmentData = [:]
                attemptedResponseAttachments = []
                loadingResponseAttachments = []
                responseAttachmentErrors = [:]
                forgetWindow()
                loadQueue(for: selected?.id)
                loadDraft(for: selected?.id, scope: scope, hostIdentity: draftHost,
                          workspaceID: route.workspaceID)
                openingConversation = selected != nil
            } else {
                chats = []
                selected = nil
                events = []
                outgoing = []
                outgoingWatermark = [:]
                approvals = []
                approvalsLoaded = false
                forgetWindow()
                loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            }
            advanceSelection("folder-load")
            discardSteerReservations()
        }
        folderID = workspaceID
        self.workspaceID = route.workspaceID
        adoptPeer(route.peer)
        if events.isEmpty { restoreRecentMessages() }
        loadQueue(for: selected?.id)
        setupLoadTask?.cancel()
        setupLoadTask = Task { [weak self] in
            await self?.loadSetup(workspaceID: route.workspaceID, peer: route.peer,
                                  generation: generation, scope: scope)
        }
        let listRead = beginChatListRead(workspaceID: route.workspaceID, peer: route.peer, scope: scope)
        do {
            // Catalog and persona failures must not hide a successful chat list.
            let loaded = try await Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            probe.error("load answered gen=\(generation)/\(self.loadGeneration) scopeThen=\(String(describing: scope?.identity)) scopeNow=\(String(describing: WorkSessionContext.shared.scope?.identity)) chats=\(loaded.count)")
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else {
                // A superseded load must not touch the opening flag: load N+1
                // may already have asserted opening=true in its folder-change
                // block, and clearing it here would clobber the newer load.
                return
            }
            chats = Self.uniqued(applyChatList(loaded, read: listRead, current: chats))
            storeChatListCache(chats, folderID: workspaceID)
            if let owner = continuityOwner(folderID: workspaceID) {
                let prefix = WorkReferenceKey.folder(scope: owner.scope, hostIdentity: owner.host, workspaceID: owner.workspace)
                recentMessages.retain(Set(chats.map { prefix + WorkReferenceKey.encode($0.id) }), in: prefix)
            }
            if let pending = pendingRevealID,
               pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID {
                if let found = chats.first(where: { $0.id == pending }) {
                    pendingRevealID = nil
                    pendingRevealFolderID = nil
                    if selected?.id == found.id {
                        if found != selected { self.selected = found }
                        await refreshOpen(id: found.id)
                    } else {
                        await select(found)
                    }
                } else {
                    // The host has just answered with the whole list and the
                    // conversation a notification named is not in it, so it
                    // was deleted and no later load will find it either.
                    // Clearing the reveal is the point: it used to survive
                    // this branch and re-run on every load of the folder,
                    // blanking the pane for an id that is never coming back.
                    //
                    // Only this folder may say so. A reveal armed for another
                    // one is waiting for its own load, and answering for it
                    // here would drop the tap on the floor.
                    if pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID {
                        pendingRevealID = nil
                        pendingRevealFolderID = nil
                    }
                    // An explicit destination must never fall back to a different
                    // conversation. Pins and notifications name one exact thread.
                    await select(nil)
                    error = L10n.text("apple.chatmodel.this_conversation_is_no_longer_available_i.d930b486")
                }
            } else if let selected, let fresh = chats.first(where: { $0.id == selected.id }) {
                // This conversation is already open. Re-selecting it would
                // empty the transcript and read it back, which is a blank
                // pane, a persona where the last turn was, and a lost scroll
                // position every time somebody leaves this screen and comes
                // back to it. Take the fresh record and keep the rows.
                if fresh != selected { self.selected = fresh }
                await refreshOpen(id: fresh.id)
            } else if selectFirst {
                probe.error("selecting remembered=\(String(describing: rememberedID)) of \(self.chats.count)")
                // No reveal named one and the old selection is gone with the
                // folder change. Reopen this folder's own conversation when
                // it is still here; the first row only when it is not.
                if let remembered = rememberedID,
                   let found = chats.first(where: { $0.id == remembered }) {
                    await select(found)
                } else {
                    await select(chats.first)
                }
            } else {
                await select(nil)
            }
            // Prepare the project's ten recent conversations. Already warm
            // ones are skipped without a read.
            if generation == loadGeneration {
                warmRecentChats()
            }
        } catch {
            if generation == loadGeneration {
                if !Task.isCancelled, !(error is CancellationError), scope == WorkSessionContext.shared.scope {
                    self.error = error.localizedDescription
                }
                // A primed folder otherwise keeps its opening state with
                // nothing coming to clear it.
                openingConversation = false
            }
        }
    }

    /// Secondary menus have their own owner and cannot hold the transcript open.
    private func loadSetup(workspaceID: String, peer: String?, generation: UInt64,
                           scope: WorkReference.Scope?) async {
        async let catalog: Void = loadBackendCatalog(peer: peer, generation: generation, scope: scope)
        async let voices: Void = loadPersonaCatalog(workspaceID: workspaceID, peer: peer,
                                                   generation: generation, scope: scope)
        _ = await (catalog, voices)
    }

    private func loadBackendCatalog(peer: String?, generation: UInt64, scope: WorkReference.Scope?) async {
        do {
            let loaded = try await Bridge.chatBackends(peer: peer)
            guard !Task.isCancelled, generation == loadGeneration,
                  scope == WorkSessionContext.shared.scope else { return }
            backends = loaded
            backendRefreshError = nil
        } catch {
            guard !Task.isCancelled, generation == loadGeneration,
                  scope == WorkSessionContext.shared.scope else { return }
            backendRefreshError = error.localizedDescription
        }
    }

    private func loadPersonaCatalog(workspaceID: String, peer: String?, generation: UInt64,
                                    scope: WorkReference.Scope?) async {
        do {
            let loaded = try await Bridge.chatPersonas(workspaceID: workspaceID, peer: peer)
            guard !Task.isCancelled, generation == loadGeneration,
                  scope == WorkSessionContext.shared.scope else { return }
            personas = loaded.personas
            defaultPersonaID = loaded.defaultId.isEmpty ? nil : loaded.defaultId
        } catch { /* Keep the last verified voices; a later open retries. */ }
    }

    private static func uniqued(_ chats: [ChatConversation]) -> [ChatConversation] {
        var seen = Set<String>()
        return chats.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// Open this conversation once its folder is loaded.
    ///
    /// A notification tap names a thread this model may not have read yet.
    /// Stash the id so `load` selects it instead of the first row. Callers
    /// that already hold the folder also select immediately.
    /// Open this conversation on the next load that can see it.
    ///
    /// `folderID` is the folder it lives in, when the caller knows: a load of
    /// any other folder then leaves the reveal alone rather than deciding on
    /// a list that was never going to contain it.
    func reveal(id: String, in folderID: String? = nil) {
        guard !id.isEmpty else { return }
        pendingRevealID = id
        pendingRevealFolderID = folderID
    }

    func select(_ chat: ChatConversation?) async {
        await select(chat, savedPage: nil)
        if selected?.id == chat?.id { warmRecentChats() }
    }

    /// Cold opening of an existing copy. No pairing, peer request or queue
    /// reconciliation runs here. Only a fresh model may adopt this owner.
    func loadSavedConversation(_ reference: WorkReference) async -> Bool {
        guard folderID == nil, selected == nil,
              reference.scope == WorkSessionContext.shared.readingScope,
              WorkReferenceKey.conversation(reference) != nil else { return false }
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let copy = await WorkCacheStore.shared.savedConversation(for: reference),
              !Task.isCancelled, generation == loadGeneration,
              reference.scope == WorkSessionContext.shared.readingScope else { return false }
        if let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) {
            ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date()), for: reference)
        }
        continuityScope = reference.scope
        adoptPeer(reference.hostIdentity == WorkSessionContext.shared.localHostIdentity ? nil : reference.hostIdentity)
        workspaceID = reference.workspaceID
        folderID = peer.map { "remote:\($0):\(reference.workspaceID)" } ?? reference.workspaceID
        var chat = ChatConversation(saved: reference, title: copy.title, backend: copy.backend)
        chat.sendRevision = copy.sendRevision
        chats = [chat]
        await select(chat, savedPage: copy)
        return savedCopy != nil
    }

    private func select(_ chat: ChatConversation?, savedPage: CachedRecordPayload?, fresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        if savedPage == nil, let chat, chat.id == selected?.id {
            await refreshOpen(id: chat.id)
            return
        }
        rememberRecentMessages()
        advanceSelection("select")
        discardSteerReservations()
        let generation = selectionGeneration
        #if DEBUG
        let openingStarted = ProcessInfo.processInfo.systemUptime
        #endif
        selected = chat
        contextRevision = savedPage?.sendRevision
        // Group ids are archive positions, which repeat from one chat to the
        // next. A group opened here must not open its namesake elsewhere.
        groupsOpen = false
        toggledGroups = []
        if let chat, let folderID {
            rememberLastSelected(chatID: chat.id, folderID: folderID)
        }
        responseAttachmentData = [:]
        attemptedResponseAttachments = []
        loadingResponseAttachments = []
        responseAttachmentErrors = [:]
        approvals = []
        approvalsLoaded = false
        instructions = nil
        instructionsLoaded = false
        events = []
        outgoing = []
        outgoingWatermark = [:]
        savedCopy = nil
        forgetWindow()
        restoreRecentMessages()
        #if DEBUG
        let hadOpeningPreview = !recentMessagePreview.isEmpty
        if chat != nil {
            TranscriptProbe.shared.noteOpen(milliseconds: (ProcessInfo.processInfo.systemUptime - openingStarted) * 1000,
                preview: hadOpeningPreview, phase: "selection-state")
        }
        #endif
        loadQueue(for: chat?.id)
        loadDraft(for: chat?.id)
        #if os(macOS)
        if let chat { RunNotifications.shared.chatAttentionHandled(id: chat.id) }
        #endif
        guard let chat else {
            openingConversation = false
            return
        }
        if fresh {
            // Created a moment ago on this machine, so there is nothing to
            // open: no rows, no earlier pages, no approvals, no sealed copy.
            // Asking anyway put the wireframe over an empty screen for as
            // long as the host took to answer "nothing", which is the jump a
            // new chat used to open with. The state below is what an empty
            // live page would have set, so the first poll picks the opening
            // turn up exactly as it does after any other open.
            openingConversation = false
            contextRevision = chat.sendRevision
            eventsEpoch &+= 1
            offset = 0
            tailCursor = nil
            earlierCursor = nil
            hasEarlier = false
            reachedStart = false
            historyTrimmed = false
            conversationUsage = nil
            usageThrough = nil
            // Not awaited: the empty conversation is already on screen, and
            // the inspector's disclosure can fill itself in behind it.
            Task { await loadInstructions(id: chat.id, generation: generation) }
            return
        }
        openingConversation = true
        defer {
            if selectionGeneration == generation { openingConversation = false }
        }
        if let savedPage {
            await applySavedCopy(savedPage)
            return
        }
        let openedLive = await openEvents(id: chat.id, generation: generation)
        #if DEBUG
        if openedLive, selectionMatches(id: chat.id, generation: generation) {
            TranscriptProbe.shared.noteOpen(milliseconds: (ProcessInfo.processInfo.systemUptime - openingStarted) * 1000,
                preview: hadOpeningPreview, phase: "live-page-ready")
        }
        #endif
        if !openedLive, events.isEmpty, selectionMatches(id: chat.id, generation: generation) {
            // The live open failed with nothing on screen. A sealed copy
            // opens instead of an error, when one was kept.
            await openSavedCopy(id: chat.id, generation: generation)
        }
        // The transcript is ready once its page lands. Secondary status
        // requests must not hold the message preview over already-loaded rows.
        if selectionMatches(id: chat.id, generation: generation) {
            openingConversation = false
        }
        // Approvals and instructions are live state. Against a saved copy
        // they are refused rather than read stale: an approval resolved from
        // old rows would act on a conversation that has moved on.
        if savedCopy == nil {
            await loadApprovals(id: chat.id, generation: generation)
            await loadInstructions(id: chat.id, generation: generation)
        }
        #if !os(macOS)
        if !Task.isCancelled, selectionMatches(id: chat.id, generation: generation) {
            ClientChatReadState.shared.markRead(peer: peer, chat: selected ?? chat)
        }
        #endif
        if selectionMatches(id: chat.id, generation: generation) {
            if let delivery = claimSteerDelivery() {
                await performSteerDelivery(delivery)
            } else {
                await drainQueue()
            }
        }
    }

    /// Bring an already open conversation up to date without emptying it.
    ///
    /// The counterpart to `select`, for the case where the conversation on
    /// screen is the one being asked for. Everything here adds to what is
    /// held: no reset, so no row that is already drawn is drawn again.
    private func refreshOpen(id: String) async {
        let generation = selectionGeneration
        let wasSavedCopy = savedCopy != nil
        if wasSavedCopy {
            // Live data arriving under a snapshot is a reopen, never a tail:
            // the copy's byte offset belongs to an archive that may have
            // compacted since it was kept, and only a reset open clears the
            // read-only state that refuses sending, approvals and draining.
            savedCopy = nil
            events = []
            outgoing = []
            outgoingWatermark = [:]
            forgetWindow()
        }
        if events.isEmpty {
            // No rows held, so this is an opening whatever it is called from,
            // and the transcript has to know: revealing an empty transcript
            // and then filling it is the build-up the wireframe exists to
            // cover.
            openingConversation = true
            defer {
                if selectionGeneration == generation { openingConversation = false }
            }
            let openedLive = await openEvents(id: id, generation: generation, quiet: wasSavedCopy)
            if !openedLive, events.isEmpty, selectionMatches(id: id, generation: generation) {
                await openSavedCopy(id: id, generation: generation)
            }
        } else {
            await loadEvents(id: id, reset: false, generation: generation)
        }
        guard selectionMatches(id: id, generation: generation) else { return }
        if savedCopy == nil {
            await loadApprovals(id: id, generation: generation, quiet: wasSavedCopy)
        }
        guard selectionMatches(id: id, generation: generation) else { return }
        if instructions == nil, savedCopy == nil {
            await loadInstructions(id: id, generation: generation)
        }
        guard selectionMatches(id: id, generation: generation) else { return }
        if let delivery = claimSteerDelivery() {
            await performSteerDelivery(delivery)
        } else {
            await drainQueue()
        }
    }

    /// Reopen the conversation on its newest page, dropping the window that
    /// paging back has grown.
    ///
    /// Every scroll to something far from the viewport costs the lazy stack a
    /// walk over each item in between, so a window grown to thousands of rows
    /// makes coming back to the latest turn expensive in a way no amount of
    /// scrolling can fix. Returning to the end is the one moment that window
    /// can be dropped: the newest page is exactly what is being asked for,
    /// and what is before it is a page away again.
    func reopenAtLatest() async {
        guard let selected else { return }
        advanceSelection("explicit-latest")
        discardSteerReservations()
        let generation = selectionGeneration
        events = []
        outgoing = []
        outgoingWatermark = [:]
        forgetWindow()
        openingConversation = true
        defer {
            if selectionGeneration == generation { openingConversation = false }
        }
        await openEvents(id: selected.id, generation: generation)
    }

    /// One creation at a time: a second tap while the backend answers awaits
    /// the same conversation instead of doubling the sidebar.
    private let createSingleflight = Singleflight<ChatConversation?>()

    @discardableResult
    func create() async -> ChatConversation? {
        // A cancelled New-chat tap must not create in the background: the
        // shared task does not inherit waiter cancellation, so check here
        // where the waiter's flag is visible.
        guard !Task.isCancelled else { return nil }
        isCreating = true
        defer { isCreating = false }
        return await createSingleflight.run { await self.performCreate() }
    }

    /// True while a creation is reaching the backend. New-chat buttons read
    /// this so the tap shows as busy instead of dead. Stored rather than
    /// read off the singleflight, which nothing observes.
    private(set) var isCreating = false

    private func performCreate() async -> ChatConversation? {
        guard !Task.isCancelled, let workspaceID, let scope = continuityScope,
              scope == WorkSessionContext.shared.scope else { return nil }
        let context = loadGeneration
        let selection = selectionGeneration
        let targetPeer = peer
        do {
            if backends.isEmpty {
                let loaded = try await Bridge.chatBackends(peer: targetPeer)
                guard !Task.isCancelled, context == loadGeneration, scope == WorkSessionContext.shared.scope else { return nil }
                backends = loaded
            }
            let saved = lastLaunchChoice
            let available = backends.filter { $0.installed != false && $0.id != "sh" }
            let chosen = available.first { $0.id == saved?.backend }
                ?? available.first { $0.id == "codex" }
                ?? available.first
                ?? backends.first { $0.id != "sh" }
            let model = chosen?.models.contains(saved?.model ?? "") == true ? saved?.model : nil
            let effort = chosen?.efforts.contains(saved?.effort ?? "") == true ? saved?.effort : nil
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                // Always execute. Plan is a choice for one piece of work,
                // and carried over it left every later chat planning at
                // somebody who had asked for something to be done. The rest
                // of the setup is remembered. Autonomy stays standard unless
                // chosen: the agent acts, and a tool that needs permission
                // still stops and asks.
                mode: "execute",
                autonomy: chosen?.gateTier == "bypassOnly"
                    ? "bypass"
                    : (saved?.autonomy ?? "standard"),
                model: model,
                effort: effort,
                personaID: rememberedPersonaID(saved),
                peer: targetPeer
            )
            guard context == loadGeneration, scope == WorkSessionContext.shared.scope else { return nil }
            chats.insert(chat, at: 0)
            if let folderID { storeChatListCache(chats, folderID: folderID) }
            if !Task.isCancelled, selection == selectionGeneration {
                await select(chat, savedPage: nil, fresh: true)
            }
            return chat
        } catch {
            if !Task.isCancelled, context == loadGeneration, scope == WorkSessionContext.shared.scope { self.error = error.localizedDescription }
            return nil
        }
    }

    /// Take the backend list again when the one in hand looks like a daemon
    /// that had not finished probing.
    ///
    /// The host answers immediately and fills its model lists on a background
    /// thread, so the first request after it starts is served from curated
    /// fallbacks. A client that asks once, at launch, and keeps the answer
    /// forever is holding that half-filled list for the life of the window,
    /// which is how a Codex chat ended up with no model picker on a machine
    /// whose host could list six models a second later.
    ///
    /// Unforced: this is the ordinary cached read, arriving late enough to be
    /// the real one. Refresh in the picker is the other call, for a list that
    /// is complete but out of date.
    func refillBackendsIfIncomplete() async {
        guard savedCopy == nil else { return }
        guard let chosen = backends.first(where: { $0.id == selected?.backend }) else { return }
        guard chosen.models.isEmpty, chosen.id != "sh" else { return }
        let context = loadGeneration
        guard let loaded = try? await Bridge.chatBackends(peer: peer) else { return }
        guard context == loadGeneration else { return }
        backends = loaded
    }

    /// Ask this conversation's host to read the agent CLIs' model lists again.
    ///
    /// The host caches them for ten minutes, which is right for a picker that
    /// opens on every screen and wrong the moment somebody adds an API key to
    /// a CLI and comes straight here looking for the models it just gained.
    /// Keep the previous choices on failure and explain the failed check
    /// inline, so a disconnected host never looks like an empty installation.
    func reloadBackends(refreshModels: Bool = true) async {
        let context = loadGeneration
        do {
            let loaded = try await Bridge.chatBackends(peer: peer, refresh: refreshModels)
            guard context == loadGeneration else { return }
            backends = loaded
            backendRefreshError = nil
        } catch {
            guard context == loadGeneration else { return }
            backendRefreshError = L10n.text("apple.chatmodel.can_t_check_agents_on_this_computer_reconn.49c16d28")
        }
    }

    @discardableResult
    func checkSignIn(_ backend: ChatBackend) async -> AgentSetupStatus? {
        guard let id = backend.launcherID, backend.installed != false, savedCopy == nil else { return nil }
        // An older host only has its file evidence. Rereading the list for it
        // must not re-enumerate every agent's models on each chat open.
        guard backend.canCheckSignIn else { await reloadBackends(refreshModels: false); return nil }
        let context = loadGeneration
        let owner = peer
        do {
            let status = try await Bridge.agentSetupCheck(peer: owner, id: id)
            guard context == loadGeneration, peer == owner,
                  let index = backends.firstIndex(where: { $0.id == backend.id }) else { return nil }
            backends[index].readiness = status.readiness
            backends[index].signInVerified = status.checked == true
            backendRefreshError = nil
            return status
        } catch {
            guard context == loadGeneration else { return nil }
            backendRefreshError = error.localizedDescription
            return nil
        }
    }

    func update(
        title: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        fastMode: Bool? = nil,
        mode: String? = nil,
        autonomy: String? = nil,
        personaID: String? = nil,
        systemPrompt: String? = nil,
        allowedTools: [String]? = nil,
        allowedShellPrefixes: [String]? = nil
    ) async {
        guard savedCopy == nil, let selected else { return }
        let generation = selectionGeneration
        do {
            let updated = try await Bridge.updateChat(
                id: selected.id,
                title: title,
                backend: backend,
                model: model,
                effort: effort,
                fastMode: fastMode,
                expectedRevision: fastMode != nil ? selected.sendRevision : nil,
                mode: mode,
                autonomy: autonomy,
                personaID: personaID,
                systemPrompt: systemPrompt,
                allowedTools: allowedTools,
                allowedShellPrefixes: allowedShellPrefixes,
                peer: peer
            )
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            replace(updated)
            // The backend decides whether the rules travel on a flag or ahead
            // of the turn, and the brief is half of what they say. Either
            // moving means the shown text is stale.
            if backend != nil || systemPrompt != nil || personaID != nil {
                await loadInstructions(id: selected.id, generation: generation)
            }
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    /// Give this conversation a voice, and change nothing else.
    ///
    /// A persona no longer picks the agent, the model, the mode or the
    /// autonomy: those belong to the conversation and the person adjusts them
    /// there. That is what lets one persona be used with any agent, and what
    /// lets it survive a chat being handed from one to another.
    func applyPersona(_ persona: ChatPersona?) async {
        guard let persona else {
            await update(personaID: "", systemPrompt: "")
            return
        }
        await update(personaID: persona.id, systemPrompt: persona.systemPrompt)
    }

    /// Ask an agent for a starting point, from a sentence about what the
    /// persona should be good at. Returns a draft for a form, never a save.
    func draftPersona(brief: String, backend: String, name: String? = nil,
                      owner: PersonaContext) async throws -> ChatPersonaDraft {
        try requirePersonaContext(owner)
        let result = try await Bridge.draftChatPersona(
            brief: brief, backend: backend, name: name, peer: owner.peer
        )
        try requirePersonaContext(owner)
        return result
    }

    /// Sidebar mutations route through the row's project, including unopened projects.
    func rename(_ conversation: ChatConversation, in folderID: String, to title: String, peer: String? = nil) async throws {
        let scope = WorkSessionContext.shared.scope
        let updated = try await Bridge.updateChat(id: conversation.id, title: title,
                                                  peer: Bridge.chatRoute(workspaceID: folderID, peer: peer).peer)
        guard scope == WorkSessionContext.shared.scope else { return }
        publishSidebarConversation(updated, in: folderID)
        if let reference = draftReference(for: updated.id, in: folderID),
           PinnedWorkStore.shared.isPinned(reference) {
            let folderName = PinnedWorkStore.shared.pins(in: reference.scope)
                .first { $0.reference == reference }?.folderName ?? L10n.text("apple.chatmodel.project.98595978")
            PinnedWorkStore.shared.pin(reference, label: updated.title, folderName: folderName)
        }
    }

    func fork(_ conversation: ChatConversation, in folderID: String, peer: String? = nil) async throws -> ChatConversation {
        let scope = WorkSessionContext.shared.scope
        let copied = try await Bridge.forkChat(id: conversation.id,
                                               peer: Bridge.chatRoute(workspaceID: folderID, peer: peer).peer)
        guard scope == WorkSessionContext.shared.scope else {
            throw NSError(domain: "Chat", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.text("apple.chatmodel.the_account_changed_while_copying_the_chat.223191a0")])
        }
        publishSidebarConversation(copied, in: folderID)
        return copied
    }

    private func publishSidebarConversation(_ conversation: ChatConversation, in folderID: String) {
        if let owner = continuityOwner(folderID: folderID) {
            listMutations.replace(conversation, owner: WorkReferenceKey.folder(scope: owner.scope,
                hostIdentity: owner.host, workspaceID: owner.workspace))
        }
        var list = sidebarChats(in: folderID)
        let conversation = ChatSteerOverlay.preservingNote(in: conversation,
            from: list.first { $0.id == conversation.id })
        if let index = list.firstIndex(where: { $0.id == conversation.id }) {
            list[index] = conversation
        } else {
            list.insert(conversation, at: 0)
        }
        storeChatListCache(list, folderID: folderID)
        if self.folderID == folderID {
            chats = list
            if selected?.id == conversation.id { selected = conversation }
        }
    }

    @discardableResult
    func remove(_ chat: ChatConversation) async -> Bool {
        await remove(chat, in: folderID)
    }

    /// A sibling mobile reader already completed the host deletion. Retire
    /// this copy without sending another mutation or choosing another chat.
    func forgetRemovedConversation(_ id: String) async {
        previewCacheEpoch &+= 1
        if let folderID, let owner = continuityOwner(folderID: folderID) {
            let key = WorkReferenceKey.folder(scope: owner.scope,
                hostIdentity: owner.host, workspaceID: owner.workspace)
            listMutations.remove(id, owner: key)
            recentMessages.remove(key + WorkReferenceKey.encode(id))
            forgetDraft(chatID: id, folderID: folderID)
        }
        if selected?.id == id { clearRecentMessagePreview() }
        chats.removeAll { $0.id == id }
        if let folderID { storeChatListCache(chats, folderID: folderID) }
        if selected?.id == id { await select(nil) }
    }

    func acceptRenamedConversation(_ chat: ChatConversation) {
        guard let folderID, workspaceID == chat.workspaceID else { return }
        publishSidebarConversation(chat, in: folderID)
    }

    /// Delete one conversation shown in the sidebar.
    ///
    /// A row under another folder cannot use the live peer, which is the
    /// folder on screen and not the conversation's host. Routing by folder id
    /// deletes from the owning host and drops the row from the cache, leaving
    /// the open transcript alone.
    @discardableResult
    func remove(_ chat: ChatConversation, in folderID: String?) async -> Bool {
        let targetPeer = WorkDestinationResolver.deletionPeer(folderID: folderID, currentFolderID: self.folderID, currentPeer: peer)
        let cacheKey = (folderID ?? self.folderID).flatMap { folder in
            continuityOwner(folderID: folder).map { owner in
                WorkReferenceKey.folder(scope: owner.scope, hostIdentity: owner.host,
                    workspaceID: owner.workspace) + WorkReferenceKey.encode(chat.id)
            }
        }
        let context = loadGeneration
        let scope = WorkSessionContext.shared.scope
        do {
            try await Bridge.removeChat(id: chat.id, peer: targetPeer)
            guard context == loadGeneration, scope == WorkSessionContext.shared.scope else { return false }
            error = nil
            if let folder = folderID ?? self.folderID, let owner = continuityOwner(folderID: folder) {
                listMutations.remove(chat.id, owner: WorkReferenceKey.folder(scope: owner.scope,
                    hostIdentity: owner.host, workspaceID: owner.workspace))
            }
            // Only this chat. Every other warm conversation is still right.
            previewCacheEpoch &+= 1
            if let cacheKey { recentMessages.remove(cacheKey) }
            if (folderID == nil || folderID == self.folderID) && selected?.id == chat.id {
                clearRecentMessagePreview()
            }
            if let folderID { forgetDraft(chatID: chat.id, folderID: folderID) }
            if let folderID, folderID != self.folderID {
                chatListCache[folderID]?.removeAll { $0.id == chat.id }
                if rememberedChat(in: folderID) == chat.id { forgetLastSelected(folderID: folderID) }
                if pendingRevealID == chat.id,
                   pendingRevealFolderID == nil || pendingRevealFolderID == folderID {
                    pendingRevealID = nil
                    pendingRevealFolderID = nil
                }
            } else {
                if let folderID, rememberedChat(in: folderID) == chat.id {
                    forgetLastSelected(folderID: folderID)
                }
                chats.removeAll { $0.id == chat.id }
                if let folderID { storeChatListCache(chats, folderID: folderID) }
                if selected?.id == chat.id {
                    await select(chats.first)
                }
            }
            return context == loadGeneration && scope == WorkSessionContext.shared.scope
        } catch {
            if context == loadGeneration, scope == WorkSessionContext.shared.scope { self.error = error.localizedDescription }
            return false
        }
    }

    func removeAll(in folderID: String, peer: String? = nil) async {
        let scope = WorkSessionContext.shared.scope
        let cachePrefix = continuityOwner(folderID: folderID).map { owner in
            WorkReferenceKey.folder(scope: owner.scope, hostIdentity: owner.host, workspaceID: owner.workspace)
        }
        let context = loadGeneration
        do {
            // `folderID` may encode a different remote peer than the chat
            // currently loaded in this model. Let the bridge route the folder
            // itself instead of borrowing the current conversation's peer.
            _ = try await Bridge.removeAllChats(workspaceID: folderID, peer: peer)
            guard context == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
            previewCacheEpoch &+= 1
            if let cachePrefix { recentMessages.retain([], in: cachePrefix) }
            if self.folderID == folderID { clearRecentMessagePreview() }
            error = nil
            storeChatListCache([], folderID: folderID)
            forgetLastSelected(folderID: folderID)
            if self.folderID == folderID || workspaceID == folderID {
                chats = []
                await select(nil)
            }
        } catch {
            if context == loadGeneration, scope == WorkSessionContext.shared.scope { self.error = error.localizedDescription }
        }
    }

    /// A send is in flight. Set synchronously on entry (the main actor runs
    /// one task at a time, so a second tap cannot slip between the check and
    /// the set) and cleared when the bridge answers. The composer disables
    /// Send on this; without it a double-tap re-sent the same attachments,
    /// which image-only sends made reachable.
    private(set) var sending = false
    /// Distinguishes the send that reserved the composer from one a delivery
    /// started inside it. A newer send must not be cleared by the older one.
    @ObservationIgnored private var sendToken: UInt64 = 0
    @ObservationIgnored private var composerSendToken: UInt64?
    /// The reservation `beginBusyNote` made, released by `finishBusyNote`.
    @ObservationIgnored private var busyNoteToken: UInt64?
    @ObservationIgnored private var busyNoteSubmission: ChatDraftSubmission?
    /// One probe per busy stretch. A miss stays unknown until the turn ends,
    /// so a dropped packet is not remembered as an older host.
    @ObservationIgnored private var steerProbeStarted = false
    @ObservationIgnored private var steerProbeTicket: UUID?
    @ObservationIgnored private var steerProbeOwner: PollOwner?
    /// Set before any await so a poll and a queue drain cannot both send.
    @ObservationIgnored private var deliveringSteer: ChatSteerContext?
    @ObservationIgnored private var deliveringSteerToken: UInt64?
    @ObservationIgnored private var clearingSteer: ChatSteerContext?
    @ObservationIgnored private var clearingSteerToken: UInt64?
    /// Messages waiting for the open turn to finish. Kept per conversation so
    /// leaving the thread and coming back still has them.
    private(set) var queued: [ChatQueuedMessage] = []
    /// The message the composer is delivering on its first attempt.
    ///
    /// The outbox is written before the host is asked, because an
    /// acknowledgement that never arrives must not take the words with it.
    /// That record is not news to the person who just pressed Send: on a
    /// healthy send it exists for one round trip, and drawing it made the
    /// pending strip open and shut on every message.
    private var deliveringFromComposer: String?
    /// What the pending strip draws: everything genuinely waiting, which is
    /// to say everything except the send that is in flight right now. A
    /// refused or unconfirmed send clears this on its way out, so it appears
    /// the moment it really is pending.
    var pendingQueue: [ChatQueuedMessage] {
        let signInID = signInQueuedMessage?.id
        return queued.filter { $0.id != deliveringFromComposer && $0.id != signInID }
    }
    private var queuedReference: WorkReference?
    @ObservationIgnored private var sendingNow = false
    private var authorizedQueueItems: Set<String> = []
    /// The message the queue sends next. One held for another agent's
    /// sign-in waits in its place, for the person to switch back or remove
    /// it, and does not hold up the messages behind it for this agent.
    private var queueHead: ChatQueuedMessage? {
        queued.first { item in
            guard let held = item.signInBackend else { return true }
            return held == selected?.backend
        }
    }

    var queuePaused: Bool {
        guard let first = queueHead else { return false }
        return first.signInBackend != nil || !authorizedQueueItems.contains(first.id) || first.delivery != .waiting
    }

    private var ownsQueue: Bool {
        guard let queuedReference else { return false }
        return currentReference == queuedReference && WorkCacheAccess.canRead(queuedReference)
    }

    @discardableResult
    func enqueue(_ text: String, atFront: Bool = false, whenConnected: Bool = false, awaitingSignIn: Bool = false) -> ChatQueuedMessage? {
        guard stagingAttachments == 0, (savedCopy == nil || whenConnected), ownsQueue, let reference = queuedReference else { return nil }
        var item = ChatQueuedMessage(id: draftMessageID ?? UUID().uuidString, text: text, attachments: attachments)
        item.whenConnected = whenConnected
        item.signInBackend = awaitingSignIn ? selected?.backend : nil
        item.expectedRevision = contextRevision
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                if let existing = items.first(where: { $0.id == item.id }) {
                    guard existing.text == item.text, existing.attachments == item.attachments else { throw ChatOutboxStore.Failure.conflict }
                    return
                }
                guard items.count < ChatOutboxStore.capacity else { throw ChatOutboxStore.Failure.full }
                if atFront { items.insert(item, at: 0) } else { items.append(item) }
            }
            guard let stored = queued.first(where: { $0.id == item.id }), !stored.needsReceipt else {
                self.error = L10n.text("apple.chatmodel.check_delivery_in_pending_messages_before.af602276")
                return nil
            }
            authorizedQueueItems.insert(item.id)
            attachments = []
            attachmentPreviews = [:]
            Task { await drainQueue() }
            return item
        } catch {
            self.error = L10n.text("apple.chatmodel.this_message_could_not_be_saved_to_the_que.95da1002")
            return nil
        }
    }

    func updateQueued(_ item: ChatQueuedMessage, text: String, owner: WorkReference?) {
        guard text != item.text else { return }
        guard let owner, owner == queuedReference, ownsQueue, let reference = queuedReference else { return }
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] == item,
                      items[index].canEdit else { throw ChatOutboxStore.Failure.conflict }
                guard items[index].text != text else { return }
                // The row keeps its id while it is edited: re-identifying it
                // rebuilds the field and drops the caret on the first
                // keystroke. An edit after an attempt still goes out under a
                // fresh delivery id, so `attemptedAt` stays as the mark the
                // send path rotates; the stale authorization goes with it.
                if items[index].attemptedAt != nil {
                    items[index].firstAttemptAt = nil
                    items[index].delivery = .waiting
                    authorizedQueueItems.remove(item.id)
                }
                items[index].text = text
                items[index].expectedRevision = contextRevision
            }
        } catch { self.error = L10n.text("apple.chatmodel.this_queued_message_changed_or_could_not_b.8393fdc8") }
    }

    func removeQueued(_ item: ChatQueuedMessage, owner: WorkReference?) {
        guard let owner, owner == queuedReference, ownsQueue, let reference = queuedReference else { return }
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                guard let stored = items.first(where: { $0.id == item.id }), stored == item, stored.delivery != .sending else {
                    throw ChatOutboxStore.Failure.conflict
                }
                items.removeAll { $0.id == item.id }
            }
            authorizedQueueItems.remove(item.id)
            Task { await drainQueue() }
        } catch { self.error = L10n.text("apple.chatmodel.the_queued_copy_could_not_be_removed_check.dc44397e") }
    }

    func moveQueued(from offsets: IndexSet, to destination: Int, owner: WorkReference?) {
        guard let owner, owner == queuedReference, ownsQueue, let reference = queuedReference else { return }
        let expected = queued.map(\.id)
        var reordered = pendingQueue
        guard offsets.allSatisfy({ reordered.indices.contains($0) }), (0...reordered.count).contains(destination) else { return }
        reordered.move(fromOffsets: offsets, toOffset: destination)
        do {
            queued = try ChatOutboxStore.shared.reorder(reference, expectedIDs: expected, visibleOrder: reordered.map(\.id))
        } catch { self.error = L10n.text("apple.chatmodel.the_queue_changed_or_could_not_be_saved_re.fa598b04") }
    }

    func queueDraftWhenConnected() {
        guard savedCopy != nil, unconfirmedSend == nil, heldSubmission == nil,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        if enqueue(draft, whenConnected: true) != nil { clearDraft() }
    }

    func resumeWaitingConnection() async {
        guard ownsQueue, let reference = queuedReference, WorkCacheAccess.canSave(reference),
              queued.contains(where: { $0.whenConnected && $0.delivery == .waiting }) else { return }
        authorizedQueueItems.formUnion(queued.filter { $0.whenConnected && $0.delivery == .waiting }.map(\.id))
        if savedCopy != nil { await checkSavedCopyForUpdates(quiet: true) }
        else { await drainQueue() }
    }

    func sendNow(_ item: ChatQueuedMessage, owner: WorkReference?) async {
        guard let owner, owner == queuedReference, ownsQueue else { return }
        if let backend = item.signInBackend {
            error = L10n.text("apple.agentsetup.pending_other_agent", self.backend(for: backend)?.label ?? backend.capitalized)
            return
        }
        guard savedCopy == nil else {
            error = L10n.text("apple.chatmodel.check_for_updates_to_return_to_the_live_co.3b041e43")
            return
        }
        if item.delivery == .needsReview {
            guard let revision = contextRevision else {
                error = L10n.text("apple.chatmodel.check_for_updates_before_using_the_latest.71504043")
                return
            }
            do {
                queued = try ChatOutboxStore.shared.update(owner) { items in
                    guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] == item else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                    items[index].expectedRevision = revision
                    items[index].delivery = .ready
                }
                error = L10n.text("apple.chatmodel.the_message_is_ready_with_the_conversation.a1db2644")
            } catch { self.error = L10n.text("apple.chatmodel.the_pending_message_changed_reopen_it_befo.3d158d7b") }
            return
        }
        guard !sendingNow else { return }
        sendingNow = true
        defer { sendingNow = false }
        _ = await deliverQueued(item, stopCurrent: true)
    }

    func drainQueue() async {
        // A parked note owns the next send. Delivering it and draining the
        // queue in the same breath would start two turns.
        if deliveringSteer != nil || clearingSteer != nil { return }
        if let note = selected?.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return
        }
        guard !busy, !sending, !sendingNow, !queuePaused, let item = queueHead else { return }
        if await deliverQueued(item, stopCurrent: false), !busy {
            await drainQueue()
        }
    }

    /// A refusal with no words looks like a dead button: the message stays
    /// queued, the draft comes back, and nothing says why.
    private func busyTurnError() {
        error = L10n.text("apple.chatmodel.this_conversation_is_still_finishing_its_p.01b9e26a")
    }

    /// Acceptance updates the captured owner's disk record even if navigation
    /// changes. Nothing leaves the outbox before the host's acknowledgement.
    private func deliverQueued(_ candidate: ChatQueuedMessage, stopCurrent: Bool, reserved: Bool = false) async -> Bool {
        guard candidate.signInBackend == nil, savedCopy == nil, ownsQueue, (!sending || reserved), let reference = queuedReference,
              WorkCacheAccess.canSave(reference), let conversationID = reference.itemID,
              ChatOutboxStore.shared.beginDelivery(reference) else { return false }
        let token = noteSendStarted()
        defer { ChatOutboxStore.shared.endDelivery(reference); noteSendFinished(token) }
        let targetPeer = peer
        let generation = selectionGeneration
        @MainActor func current() -> Bool {
            !Task.isCancelled && selectionMatches(id: conversationID, generation: generation)
                && currentReference == reference && WorkCacheAccess.canSave(reference) && savedCopy == nil
        }
        func publish(_ items: [ChatQueuedMessage]) {
            if currentReference == reference { queued = items }
        }
        do {
            guard try await machineConfirmsSends(peer: targetPeer, checkingReceipt: candidate.needsReceipt), current() else {
                if current() { error = candidate.needsReceipt
                    ? L10n.text("apple.chatmodel.update_this_computer_to_check_message_deli.32c24339")
                    : L10n.text("apple.chatmodel.update_this_computer_before_sending_it_nee.37a38ceb") }
                authorizedQueueItems.remove(candidate.id)
                return false
            }
            if let targetPeer {
                guard try await Bridge.workspaceAccessAllowed(peer: targetPeer), current() else {
                    authorizedQueueItems.remove(candidate.id)
                    return false
                }
            }
            guard current() else { return false }
            let stored = try ChatOutboxStore.shared.items(for: reference)
            guard let item = stored.first(where: { $0.id == candidate.id }), item == candidate else {
                publish(stored)
                authorizedQueueItems.remove(candidate.id)
                error = L10n.text("apple.chatmodel.the_pending_message_changed_review_its_cur.51debf03")
                return false
            }
            if item.needsReceipt {
                let receipt = try await Bridge.chatReceipt(id: conversationID, clientMessageID: item.id, peer: targetPeer)
                if receipt.isAccepted {
                    let items = try ChatOutboxStore.shared.update(reference) { $0.removeAll { $0.id == item.id } }
                    publish(items)
                    clearSubmittedDraft(item, reference: reference)
                    authorizedQueueItems.remove(item.id)
                    if current() { await loadEvents(id: conversationID, reset: false, generation: generation) }
                    return true
                }
                publish(try ChatOutboxStore.shared.update(reference) { items in
                    if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].delivery = .deliveryUnknown }
                })
                authorizedQueueItems.remove(item.id)
                if current() { error = receipt.state == .needsRecovery
                    ? L10n.text("apple.chatmodel.the_computer_could_not_confirm_whether_thi.64b634e0")
                    : L10n.text("apple.chatmodel.delivery_is_not_confirmed_check_the_conver.7944f74e") }
                return false
            }
            guard item.delivery != .needsReview, item.expectedRevision != nil else {
                publish(try ChatOutboxStore.shared.update(reference) { items in
                    if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].delivery = .needsReview }
                })
                authorizedQueueItems.remove(item.id)
                if current() { error = L10n.text("apple.chatmodel.review_the_live_conversation_then_choose_u.aec734da") }
                return false
            }
            guard current(), !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !item.attachments.isEmpty else { return false }
            if stopCurrent, selected?.running == true {
                await stop()
                for _ in 0..<80 {
                    guard current() else { return false }
                    if selected?.running != true { break }
                    await poll()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard current(), !busy else {
                if current() { busyTurnError() }
                return false
            }
            // Setup's background probe can still be in flight on a newly
            // opened chat, and a catalog refresh replaces its local evidence.
            // Check before sending, so a CLI that signs in automatically in
            // exec mode cannot park a browser challenge inside the chat.
            if let backend = backend(for: selected?.backend ?? ""),
               backend.canCheckSignIn, backend.signInFlow?.supported == true {
                let status = await checkSignIn(backend)
                guard current(), selected?.backend == backend.id, !busy else { return false }
                if status?.checked == true, ["needsSignIn", "expired"].contains(status?.readiness ?? "") {
                    publish(try ChatOutboxStore.shared.update(reference) { items in
                        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] == item else {
                            throw ChatOutboxStore.Failure.conflict
                        }
                        items[index].delivery = .waiting
                        items[index].signInBackend = backend.id
                    })
                    authorizedQueueItems.remove(item.id)
                    return false
                }
            }
            let resolved = try await resolveDraftAttachments(item.attachments, reference: reference, peer: targetPeer)
            guard current(), !busy else {
                if current() { busyTurnError() }
                return false
            }
            // An edit after an attempt marks its row by leaving `attemptedAt`
            // in place. The words changed, so the delivery id does too: the
            // old one may already have a receipt on the host. It is minted
            // here, at the send, never while the field is being typed into.
            let rotatesDelivery = item.attemptedAt != nil && item.delivery == .waiting
            var deliveryItem = item
            if rotatesDelivery { deliveryItem.id = UUID().uuidString }
            let firstAttemptAt = rotatesDelivery
                ? Date()
                : (item.firstAttemptAt ?? item.attemptedAt ?? Date())
            publish(try ChatOutboxStore.shared.update(reference) { items in
                guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] == item else {
                    throw ChatOutboxStore.Failure.conflict
                }
                items[index].id = deliveryItem.id
                items[index].delivery = .sending
                items[index].firstAttemptAt = firstAttemptAt
                items[index].attemptedAt = Date()
            })
            let staged = stageOutgoing(item.text)
            var accepted = false
            do {
                let updated = try await Bridge.sendChat(id: conversationID, text: item.text,
                    attachmentIDs: resolved.map(\.id), clientMessageID: deliveryItem.id,
                    clientMessageCreatedAt: firstAttemptAt, expectedRevision: item.expectedRevision, peer: targetPeer)
                accepted = true
                let remaining = try ChatOutboxStore.shared.accept(deliveryItem, revision: updated.sendRevision, for: reference)
                publish(remaining)
                clearSubmittedDraft(item, reference: reference)
                authorizedQueueItems.remove(deliveryItem.id)
                if current() {
                    replace(updated)
                    contextRevision = updated.sendRevision
                    await loadEvents(id: conversationID, reset: false, generation: generation)
                }
                return true
            } catch {
                if current() { dropOutgoing(staged) }
                authorizedQueueItems.remove(deliveryItem.id)
                publish(try ChatOutboxStore.shared.update(reference) { items in
                    if let index = items.firstIndex(where: { $0.id == deliveryItem.id }) {
                        if case BridgeError.core(code: "conversation_changed", message: _) = error {
                            items[index].delivery = .needsReview
                        } else {
                            items[index].delivery = accepted || Bridge.isDeliveryUnknown(error) ? .deliveryUnknown : .failed
                        }
                    }
                })
                if current() { self.error = accepted || Bridge.isDeliveryUnknown(error)
                    ? L10n.text("apple.chatmodel.the_machine_did_not_confirm_delivery_your.dbfa6c4d")
                    : error.localizedDescription }
                return false
            }
        } catch {
            authorizedQueueItems.remove(candidate.id)
            if current() {
                self.error = candidate.needsReceipt
                    ? L10n.text("apple.chatmodel.delivery_could_not_be_checked_the_original.b9f28e27")
                    : L10n.text("apple.chatmodel.this_message_stays_pending.eada83a6") + error.localizedDescription
            }
            return false
        }
    }

    private func resolveDraftAttachments(_ files: [ChatAttachment], reference: WorkReference, peer: String?) async throws -> [ChatAttachment] {
        guard let conversationID = reference.itemID else { throw CancellationError() }
        var resolved: [ChatAttachment] = []
        for file in files {
            guard currentReference == reference, WorkCacheAccess.canSave(reference), savedCopy == nil else { throw CancellationError() }
            if ChatLocalAttachmentStore.isLocal(file) {
                let uploaded = try await ChatLocalAttachmentStore.shared.resolve(file, reference: reference) { data in
                    guard await MainActor.run(body: { WorkCacheAccess.canSave(reference) }) else { throw CancellationError() }
                    return try await Bridge.attachToChat(id: conversationID, name: file.name, data: data, mediaType: file.mediaType, peer: peer)
                }
                resolved.append(uploaded)
            } else { resolved.append(file) }
        }
        guard currentReference == reference, WorkCacheAccess.canSave(reference) else { throw CancellationError() }
        return resolved
    }

    func keepImportedDraftFiles(_ files: [ChatAttachment], reference: WorkReference, expected: WorkSharedDraft) async throws {
        guard let conversationID = reference.itemID else { throw CancellationError() }
        let targetPeer = peer
        for file in files {
            guard currentReference == reference, handoffDraft == expected, WorkCacheAccess.canSave(reference) else { throw CancellationError() }
            if (try? await ChatLocalAttachmentStore.shared.read(file, reference: reference)) != nil { continue }
            let payload = try await Bridge.chatAttachment(id: conversationID, attachmentID: file.id, peer: targetPeer)
            guard payload.attachment == file, let data = Data(base64Encoded: payload.data) else { throw ChatLocalAttachmentStore.Failure.missing }
            guard currentReference == reference, handoffDraft == expected, WorkCacheAccess.canSave(reference) else { throw CancellationError() }
            try await ChatLocalAttachmentStore.shared.keep(file, data: data, reference: reference)
        }
    }

    func prepareHandoffDraft(_ expected: WorkSharedDraft) async throws -> WorkSharedDraft {
        guard let reference = currentReference, handoffDraft == expected, !sending, stagingAttachments == 0 else { throw CancellationError() }
        let files = try await resolveDraftAttachments(attachments, reference: reference, peer: peer)
        guard currentReference == reference, handoffDraft == expected else { throw CancellationError() }
        return WorkSharedDraft(text: expected.text, attachmentIDs: files.map(\.id))
    }

    func attach(_ file: URL) async {
        guard let item = ChatInbox.item(from: file) else {
            error = L10n.text("apple.chatmodel.that_file_could_not_be_read.e9fe8433")
            return
        }
        await attach(item)
    }

    func attach(_ item: ChatInboxItem) async {
        guard let reference = currentReference else { return }
        await attach(item, to: reference)
    }

    /// Imports retain the conversation chosen before file preparation begins.
    /// Later files in a batch must not follow navigation to another draft.
    func attach(_ item: ChatInboxItem, to reference: WorkReference) async {
        guard WorkReferenceKey.conversation(reference) != nil,
              WorkCacheAccess.canRead(reference) else { return }
        let isCurrent = currentReference == reference
        guard !isCurrent || !sending else { return }
        let existing = isCurrent ? attachments : (ChatDraftStore.shared.draft(for: reference)?.attachments ?? [])
        guard existing.count + stagingAttachments < 20 else {
            error = L10n.text("apple.chatmodel.a_draft_can_include_up_to_20_files_remove.14221a45")
            return
        }
        if item.data.count > ChatInbox.maxBytes {
            error = L10n.text("apple.chatmodel.an_attachment_is_limited_to_12_mb.a0b63b0d")
            return
        }
        if isCurrent { saveDraftNow() }
        stagingAttachments += 1
        defer { stagingAttachments -= 1 }
        do {
            let attachment = try await ChatLocalAttachmentStore.shared.stage(data: item.data,
                name: item.name, mediaType: item.mediaType, reference: reference)
            guard currentReference == reference, WorkCacheAccess.canRead(reference) else {
                // Keep an import that completed after navigation in its own
                // draft, alongside any writing saved while it was loading.
                let original = ChatDraftStore.shared.draft(for: reference)
                ChatDraftStore.shared.save(text: original?.text ?? "", attachments: (original?.attachments ?? []) + [attachment], for: reference)
                return
            }
            attachments.append(attachment)
            if let preview = ChatThumbnail.make(from: item.data) {
                attachmentPreviews[attachment.id] = preview
            }
            saveDraftNow()
        } catch {
            if currentReference == reference {
                self.error = error.localizedDescription
            }
        }
    }

    func appendImportedText(_ text: String, to reference: WorkReference) {
        guard WorkCacheAccess.canRead(reference) else { return }
        if currentReference == reference {
            draft.append(text)
        } else {
            let original = ChatDraftStore.shared.draft(for: reference)
            ChatDraftStore.shared.save(text: (original?.text ?? "") + text,
                attachments: original?.attachments ?? [], for: reference)
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        attachmentPreviews.removeValue(forKey: attachment.id)
        missingDraftAttachments.remove(attachment.id)
        saveDraftNow()
    }

    func stop() async {
        // Nothing live to stop from a snapshot, and a stop that lands on a
        // changed conversation stops the wrong turn.
        guard savedCopy == nil else { return }
        guard let selected else { return }
        let generation = selectionGeneration
        let reference = currentReference
        let mutation = reference.flatMap { steerMutationSnapshot($0) }
        var removedNote = false
        do {
            try await Bridge.stopChat(id: selected.id, peer: peer)
            if let reference, let mutation,
               currentReference != reference || self.selected?.pendingSteer == nil
                   || self.selected?.pendingSteer == selected.pendingSteer {
                removedNote = rememberSteerMutation(reference, note: nil, since: mutation)
            }
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
            return
        }
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        if removedNote { clearLocalSteer() }
        await loadEvents(id: selected.id, reset: false, generation: generation)
        await loadApprovals(id: selected.id, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        let listRead = beginChatListRead(workspaceID: selected.workspaceID, peer: peer)
        do {
            let answer = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            let latest = applyChatList(answer, read: listRead, current: chats)
            // Only when it actually moved. Observation notifies on the write,
            // not on the difference, and this runs four hundred milliseconds
            // at a time: an unconditional assignment redraws every open
            // transcript twice a second for nothing.
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == selected.id }),
               current != self.selected {
                self.selected = current
                // Muse flushes counters to its saved session when a turn ends.
                // Ask for the host's complete fold after that transition too.
                if selected.running && !current.running {
                    await refreshUsage(id: selected.id, generation: generation)
                    guard selectionMatches(id: selected.id, generation: generation) else { return }
                }
            }
            settleNotifications()
        } catch {}
    }

    func resolve(_ approval: ChatApproval, choice: String, owner: WorkReference?) async {
        // An approval resolved from old rows acts on a conversation that has
        // moved on. The snapshot shows pending approvals as text, never as
        // live controls.
        guard !Task.isCancelled, savedCopy == nil, let owner,
              owner.scope == WorkSessionContext.shared.scope,
              currentReference == owner, owner.itemID == approval.conversationID,
              selected?.id == approval.conversationID,
              approvalIsPending(approval) else { return }
        let generation = selectionGeneration
        do {
            _ = try await Bridge.resolveChatApproval(id: approval.id, choice: choice, peer: peer)
            guard selectionMatches(id: approval.conversationID, generation: generation) else { return }
            await loadApprovals(id: approval.conversationID, generation: generation)
            guard selectionMatches(id: approval.conversationID, generation: generation) else { return }
            #if os(macOS)
            RunNotifications.shared.chatAttentionHandled(id: approval.conversationID)
            #endif
        } catch {
            if selectionMatches(id: approval.conversationID, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    /// Whether an approval record is still a question waiting for an answer.
    ///
    /// The live list is authoritative once it has answered. Until then — an
    /// open still in flight, or a read that has only ever failed — the
    /// record's own deadline is the evidence, so a question with time left
    /// is not reported as one nobody answered. A saved copy is a snapshot:
    /// its rows stay text, never live controls.
    func approvalIsPending(_ approval: ChatApproval) -> Bool {
        guard savedCopy == nil, approval.decision == nil else { return false }
        guard approvalsLoaded else { return false }
        if approvals.contains(where: { $0.id == approval.id }) { return true }
        return Double(approval.expiresAtMs) / 1000 > Date().timeIntervalSince1970
    }

    /// Workspace ownership does not require a selected conversation: personas
    /// can also be managed before the first chat is created.
    struct PersonaContext: Equatable {
        let generation: UInt64
        let scope: WorkReference.Scope
        let workspaceID: String
        let peer: String?
    }

    var personaContext: PersonaContext? {
        guard !isLoading, savedCopy == nil, let workspaceID,
              let scope = continuityScope, scope == WorkSessionContext.shared.scope else { return nil }
        return PersonaContext(generation: loadGeneration, scope: scope,
                              workspaceID: workspaceID, peer: peer)
    }

    private func requirePersonaContext(_ owner: PersonaContext) throws {
        guard !Task.isCancelled, personaContext == owner else { throw CancellationError() }
    }

    func savePersona(_ persona: ChatPersona, owner: PersonaContext) async throws -> ChatPersona {
        try requirePersonaContext(owner)
        let saved = try await Bridge.saveChatPersona(
            persona, workspaceID: owner.workspaceID, peer: owner.peer
        )
        try requirePersonaContext(owner)
        if let index = personas.firstIndex(where: { $0.id == saved.id }) {
            personas[index] = saved
        } else {
            personas.append(saved)
        }
        return saved
    }

    func removePersona(_ persona: ChatPersona, owner: PersonaContext) async throws {
        try requirePersonaContext(owner)
        try await Bridge.removeChatPersona(id: persona.id, peer: owner.peer)
        try requirePersonaContext(owner)
        personas.removeAll { $0.id == persona.id }
    }

    /// Nil explicitly persists "no persona" for new chats in this workspace.
    func setDefaultPersona(_ persona: ChatPersona?, owner: PersonaContext) async throws {
        try requirePersonaContext(owner)
        let saved = try await Bridge.setDefaultChatPersona(
            workspaceID: owner.workspaceID, personaID: persona?.id ?? "", peer: owner.peer
        )
        try requirePersonaContext(owner)
        defaultPersonaID = saved?.id
    }

    struct PollOwner: Hashable, Sendable {
        let reference: WorkReference
        let generation: UInt64
    }
    var pollingIdentity: PollOwner? {
        guard savedCopy == nil, let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope else { return nil }
        return PollOwner(reference: reference, generation: selectionGeneration)
    }
    @ObservationIgnored private let eventPollLane = ChatPollLane<PollOwner>()
    @ObservationIgnored private let statusPollLane = ChatPollLane<PollOwner>()
    @ObservationIgnored private let approvalPollLane = ChatPollLane<PollOwner>()
    @ObservationIgnored private let attachmentPollLane = ChatPollLane<PollOwner>()
    @ObservationIgnored private let pollWatcher = ChatPollWatcher<PollOwner>()
    @ObservationIgnored private var pollCadence = ChatPollCadence()
    @ObservationIgnored private var cadenceOwner: PollOwner?

    var pollInterval: Duration {
        pollCadence.interval(busy: busy, attachments: hasPendingResponseAttachments,
                             now: ProcessInfo.processInfo.systemUptime)
    }

    func watchPolls() async {
        guard !Task.isCancelled, let owner = pollingIdentity else { return }
        await pollWatcher.watch(owner: owner, cycle: { [weak self] in
            guard let self, self.pollingIdentity == owner else { return }
            await self.poll(forceStatus: false)
        }, interval: { [weak self] in self?.pollInterval ?? .seconds(2) }, stop: { [weak self] in
            self?.cancelPollReads(owner: owner)
        })
    }

    private func pollIsCurrent(_ owner: PollOwner) -> Bool {
        !Task.isCancelled && pollingIdentity == owner
    }

    private func cancelPollReads(owner: PollOwner? = nil) {
        if owner == nil || steerProbeOwner == owner {
            steerProbeTicket = nil
            steerProbeOwner = nil
            steerProbeStarted = false
        }
        eventPollLane.cancel(owner: owner)
        statusPollLane.cancel(owner: owner)
        approvalPollLane.cancel(owner: owner)
        if savedCopy == nil { attachmentPollLane.cancel(owner: owner) }
    }

    private func refreshUsage(id: String, generation: UInt64,
                              permitsPublication: () -> Bool = { true }) async {
        guard !Task.isCancelled, permitsPublication(), selectionMatches(id: id, generation: generation) else { return }
        let page = try? await Bridge.chatEventPage(id: id, cursor: nil, limit: 10, peer: peer)
        guard !Task.isCancelled, permitsPublication(), selectionMatches(id: id, generation: generation),
              let usage = page?.usage, usage.isValid else { return }
        conversationUsage = usage
        usageThrough = page?.events.compactMap(\.seq).max() ?? events.compactMap(\.seq).max()
    }

    /// Questions whose answer is on its way to the host, so a card does not
    /// offer the same choice twice while it waits.
    private(set) var answeringQuestions: Set<String> = []

    /// Answer one of the agent's questions. The answer is recorded on the
    /// host and reaches every device from there, so nothing is kept here.
    func answerQuestion(_ question: ChatQuestion, answer: String) async {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, savedCopy == nil, let id = selected?.id,
              !answeringQuestions.contains(question.id) else { return }
        let reference = currentReference
        let asked = peer
        answeringQuestions.insert(question.id)
        defer { answeringQuestions.remove(question.id) }
        do {
            _ = try await Bridge.answerChatQuestion(id: id, questionID: question.id, text: answer, peer: asked)
            guard currentReference == reference, peer == asked else { return }
            await poll()
        } catch {
            guard currentReference == reference, peer == asked else { return }
            let message = hostMessage(error)
            if self.error != message { self.error = message }
        }
    }

    /// Events, approvals and status share bounded independent producers.
    /// Explicit refreshes await their reads. Live ticks start shared reads
    /// without waiting, keeping metadata and attachment clocks responsive.
    func poll(forceStatus: Bool = true) async {
        guard !Task.isCancelled, !openingConversation, let owner = pollingIdentity else { return }
        if cadenceOwner != owner { cadenceOwner = owner; pollCadence = ChatPollCadence() }
        if let id = owner.reference.itemID {
            scheduleResponseAttachments(id: id, generation: owner.generation)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let status = pollCadence.claimStatus(now: now, force: forceStatus)
            ? startStatusPoll(owner: owner) : nil
        let approvals = pollCadence.claimApprovals(now: now, force: forceStatus)
            ? startApprovalPoll(owner: owner) : nil
        let events = eventPollLane.start(owner: owner) { [weak self] permitsPublication in
            guard let self, self.pollIsCurrent(owner), permitsPublication(),
                  let id = owner.reference.itemID else { return }
            let revision = self.eventsRevision
            let success = await self.loadEvents(id: id, reset: false, generation: owner.generation,
                quiet: true, onFreshEvents: { records in
                    guard self.pollIsCurrent(owner), permitsPublication() else { return }
                    if records.contains(where: { record in
                        ["approval", "question", "answer", "answerWithdrawn"].contains(record.kind)
                            || ["done", "failed"].contains(record.event?.kind ?? "")
                    }) {
                        _ = self.startStatusPoll(owner: owner, refresh: true)
                        _ = self.startApprovalPoll(owner: owner, refresh: true)
                    }
                })
            guard self.pollIsCurrent(owner), permitsPublication() else { return }
            self.pollCadence.note(success: success, changed: self.eventsRevision != revision,
                                  now: ProcessInfo.processInfo.systemUptime)
        }
        // A held event read must not hold the watcher's metadata clock.
        // The lane keeps that read bounded while later ticks share it.
        if forceStatus {
            await events?.value
            guard pollIsCurrent(owner) else { return }
            await status?.value; await approvals?.value
        }
    }

    private func startStatusPoll(owner: PollOwner, refresh: Bool = false) -> Task<Void, Never>? {
        statusPollLane.start(owner: owner, refresh: refresh) { [weak self] permitsPublication in
            guard let self else { return }
            await self.performStatusPoll(owner: owner, permitsPublication: permitsPublication)
        }
    }

    private func startApprovalPoll(owner: PollOwner, refresh: Bool = false) -> Task<Void, Never>? {
        approvalPollLane.start(owner: owner, refresh: refresh) { [weak self] permitsPublication in
            guard let self, self.pollIsCurrent(owner), permitsPublication(),
                  let id = owner.reference.itemID else { return }
            await self.loadApprovals(id: id, generation: owner.generation, quiet: true,
                                     permitsPublication: permitsPublication)
        }
    }

    private func performStatusPoll(owner: PollOwner, permitsPublication: () -> Bool) async {
        guard pollIsCurrent(owner), permitsPublication(), let selected,
              let id = owner.reference.itemID else { return }
        let generation = owner.generation
        let wasRunning = selected.running
        let listRead = beginChatListRead(workspaceID: owner.reference.workspaceID, peer: peer)
        do {
            let answer = try await Bridge.chats(workspaceID: owner.reference.workspaceID, peer: peer)
            guard pollIsCurrent(owner) && permitsPublication() else { return }
            let latest = applyChatList(answer, read: listRead, current: chats)
            // A poll that found nothing new must not write anything back.
            // Same rule as the event chunk below: the write is what redraws
            // the transcript, and most polls of a running turn arrive with
            // an unchanged list.
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == id }),
               current != self.selected {
                self.selected = current
                if wasRunning && !current.running {
                    await refreshUsage(id: id, generation: generation, permitsPublication: permitsPublication)
                    guard pollIsCurrent(owner) && permitsPublication() else { return }
                }
                #if !os(macOS)
                if !Task.isCancelled {
                    ClientChatReadState.shared.markRead(peer: peer, chat: current)
                }
                #endif
            }
            settleNotifications()
        } catch {}
        guard !Task.isCancelled, pollIsCurrent(owner) && permitsPublication() else { return }
        let claimed = claimSteerDelivery()
        let claimedToken = deliveringSteerToken
        await noteSteerAvailability(permitsPublication: permitsPublication)
        if let claimed, let token = claimedToken,
           deliveringSteer == claimed, deliveringSteerToken == token {
            if pollIsCurrent(owner), permitsPublication() {
                await performSteerDelivery(claimed)
            } else {
                finishSteerDelivery(claimed, token: token)
            }
        }
    }

    var busy: Bool {
        selected?.running == true
    }

    /// What a message typed during a turn will do.
    ///
    /// Local hosts are always current. A remote one only promises a note
    /// after a probe or a successful steer. Until then the placeholder stays
    /// the queue, and the send itself may still try.
    var sendsAsNote: Bool {
        guard busy, attachments.isEmpty, stagingAttachments == 0, savedCopy == nil else { return false }
        guard steerAutonomy, steerBackend else { return false }
        if let peer, !peer.isEmpty { return remoteSteer == true }
        return true
    }

    private var steerBackend: Bool {
        if selected?.backend == "cursor", selected?.mode == "plan" { return false }
        return ["claude", "codex", "cursor", "muse"].contains(selected?.backend ?? "")
    }

    /// Muse can take a note on any autonomy. The others only while they ask first.
    private var steerAutonomy: Bool {
        if selected?.backend == "muse" { return true }
        return selected?.autonomy == "standard"
    }

    enum BusyNoteStart { case steering(UInt64), queue }

    /// Decide before the first await. `.queue` is the path the composer
    /// already had. `.steering` reserves Send so a second tap cannot also
    /// enqueue the same words.
    func beginBusyNote(_ text: String) -> BusyNoteStart {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !attachments.isEmpty || savedCopy != nil
            || stagingAttachments > 0 || sending
            || !steerAutonomy || !steerBackend
            || remoteSteer == false {
            return .queue
        }
        guard let selected, let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope else { return .queue }
        saveDraftNow()
        busyNoteSubmission = ChatDraftSubmission(
            conversationID: selected.id, peer: peer, scope: reference.scope,
            reference: reference, generation: selectionGeneration,
            text: trimmed, draftText: draft, attachments: [],
            messageID: draftMessageID, expectedRevision: contextRevision
        )
        let token = noteSendStarted()
        busyNoteToken = token
        return .steering(token)
    }

    /// Park the note, or hand it back to the queue when this turn cannot
    /// carry one. A refusal that is about the words themselves keeps the draft.
    func finishBusyNote(_ token: UInt64) async {
        guard busyNoteToken == token else { return }
        defer {
            if busyNoteToken == token {
                busyNoteToken = nil
                busyNoteSubmission = nil
            }
            noteSendFinished(token)
        }
        guard let submission = busyNoteSubmission, let reference = submission.reference else { return }
        let context = ChatSteerContext(reference: reference,
            generation: submission.generation, peer: submission.peer)
        @MainActor func current() -> Bool {
            !Task.isCancelled && context.matches(reference: currentReference,
                generation: selectionGeneration, peer: peer, scope: WorkSessionContext.shared.scope)
        }
        guard current() else { return }
        let id = submission.conversationID
        let asked = submission.peer
        do {
            if let asked, !asked.isEmpty, remoteSteer != true {
                let version = try await Bridge.peerProtocolVersion(asked)
                guard current() else { return }
                remoteSteer = version >= RemoteHostFeature.steer.minimumProtocol
                if remoteSteer == false {
                    queueBusyNote(submission)
                    return
                }
            }
            try await Bridge.steerChat(id: id, text: submission.text, peer: asked)
            rememberSteerMutation(reference, note: submission.text)
            guard current() else { return }
            parkLocalSteer(submission.text)
            if let asked, !asked.isEmpty, peer == asked { remoteSteer = true }
            if draft == submission.draftText && attachments == submission.attachments {
                clearDraft()
            }
        } catch {
            guard current() else { return }
            if isUnknownMethod(error) {
                if let asked, !asked.isEmpty, peer == asked { remoteSteer = false }
                queueBusyNote(submission)
                return
            }
            let message = hostMessage(error)
            if Self.steerFallsBack(message) {
                queueBusyNote(submission)
                return
            }
            if self.error != message { self.error = message }
        }
    }

    /// Queue the reserved payload. Words edited during the request become a
    /// separate draft, with their own delivery identity.
    private func queueBusyNote(_ submission: ChatDraftSubmission) {
        guard let reference = submission.reference, let messageID = submission.messageID,
              submission.owns(reference: currentReference, conversationID: selected?.id,
                              peer: peer, scope: WorkSessionContext.shared.scope),
              selectionGeneration == submission.generation, ownsQueue else { return }
        var item = ChatQueuedMessage(id: messageID, text: submission.text, attachments: submission.attachments)
        item.sourceDraftText = submission.draftText
        item.expectedRevision = submission.expectedRevision
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                if let existing = items.first(where: { $0.id == item.id }) {
                    guard existing.text == item.text, existing.attachments == item.attachments else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                    return
                }
                guard items.count < ChatOutboxStore.capacity else { throw ChatOutboxStore.Failure.full }
                items.append(item)
            }
            guard let stored = queued.first(where: { $0.id == messageID }), !stored.needsReceipt else {
                error = L10n.text("apple.chatmodel.check_delivery_in_pending_messages_before.af602276")
                return
            }
            authorizedQueueItems.insert(messageID)
            if draft == submission.draftText && attachments == submission.attachments {
                clearDraft()
            } else {
                ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference, newMessage: true)
            }
            Task { await drainQueue() }
        } catch {
            self.error = L10n.text("apple.chatmodel.this_message_could_not_be_saved_to_the_que.342364f9")
        }
    }

    /// Keep the executable note visible until the host acknowledges removal.
    /// While that request runs, neither the queue nor a follow-up may start.
    func clearSteer() {
        guard savedCopy == nil, !sending, clearingSteer == nil,
              let selected, let note = selected.pendingSteer,
              let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope,
              let mutation = steerMutationSnapshot(reference) else { return }
        let context = ChatSteerContext(reference: reference, generation: selectionGeneration, peer: peer)
        clearingSteer = context
        let token = noteSendStarted()
        clearingSteerToken = token
        let id = selected.id
        let asked = context.peer
        Task {
            defer {
                if clearingSteer == context && clearingSteerToken == token {
                    clearingSteer = nil
                    clearingSteerToken = nil
                }
                noteSendFinished(token)
            }
            @MainActor func current() -> Bool {
                !Task.isCancelled && context.matches(reference: currentReference,
                    generation: selectionGeneration, peer: peer, scope: WorkSessionContext.shared.scope)
            }
            guard current() else { return }
            do {
                try await Bridge.steerClearChat(id: id, peer: asked)
                let sameNote = !current() || self.selected?.pendingSteer == nil || self.selected?.pendingSteer == note
                let removed = sameNote && rememberSteerMutation(reference, note: nil, since: mutation)
                guard current() else { return }
                if removed && self.selected?.pendingSteer == note { clearLocalSteer() }
                if removed {
                    clearingSteer = nil
                    clearingSteerToken = nil
                    noteSendFinished(token)
                    if !busy { await drainQueue() }
                }
            } catch {
                guard current() else { return }
                if isUnknownMethod(error) {
                    if let asked, !asked.isEmpty, peer == asked { remoteSteer = false }
                }
                let message = hostMessage(error)
                if self.error != message { self.error = message }
            }
        }
    }

    /// Navigation releases the old selection's reservations immediately.
    /// Late completions still hold their context and cannot release a newer one.
    private func discardSteerReservations() {
        deliveringSteer = nil
        if let token = deliveringSteerToken { noteSendFinished(token) }
        deliveringSteerToken = nil
        clearingSteer = nil
        if let token = clearingSteerToken { noteSendFinished(token) }
        clearingSteerToken = nil
        if let token = busyNoteToken { noteSendFinished(token) }
        busyNoteToken = nil
        busyNoteSubmission = nil
    }

    private func noteSendStarted() -> UInt64 {
        sendToken &+= 1
        sending = true
        return sendToken
    }

    private func noteSendFinished(_ token: UInt64) {
        guard sendToken == token else { return }
        sending = false
    }

    private static func steerFallsBack(_ message: String) -> Bool {
        message == "This agent cannot take a note mid-turn."
            || message == "This chat is not asking before tools, so a note cannot ride the next step."
            || message == "This chat is not in the middle of a turn."
    }

    private func hostMessage(_ error: Error) -> String {
        if case let BridgeError.core(_, message) = error { return message }
        return error.localizedDescription
    }

    /// Reassign the whole value. Writing one field of an optional struct does
    /// not publish, and writing the same note twice would redraw for nothing.
    private func parkLocalSteer(_ note: String) {
        guard let current = selected, current.pendingSteer != note else { return }
        var chat = current
        chat.pendingSteer = note
        selected = chat
        if let index = chats.firstIndex(where: { $0.id == chat.id }), chats[index].pendingSteer != note {
            chats[index].pendingSteer = note
        }
    }

    private func clearLocalSteer() {
        guard var chat = selected, chat.pendingSteer != nil else { return }
        chat.pendingSteer = nil
        selected = chat
        if let index = chats.firstIndex(where: { $0.id == chat.id }), chats[index].pendingSteer != nil {
            chats[index].pendingSteer = nil
        }
    }

    /// Claim before any await. While the flag is set, the queue stays put.
    private func claimSteerDelivery() -> ChatSteerContext? {
        if deliveringSteer != nil || clearingSteer != nil || sending || sendingNow || savedCopy != nil || busy { return nil }
        let note = selected?.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !note.isEmpty, let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope else { return nil }
        let context = ChatSteerContext(reference: reference,
            generation: selectionGeneration, peer: peer)
        deliveringSteer = context
        deliveringSteerToken = noteSendStarted()
        return context
    }

    private func finishSteerDelivery(_ context: ChatSteerContext, token: UInt64) {
        if deliveringSteer == context && deliveringSteerToken == token {
            deliveringSteer = nil
            deliveringSteerToken = nil
        }
        noteSendFinished(token)
    }

    /// Learn whether the current busy reader's remote host can carry a note.
    /// Failed or canceled probes leave the next tick free to retry.
    private func noteSteerAvailability(permitsPublication: () -> Bool = { true }) async {
        if !busy {
            steerProbeStarted = false
            steerProbeTicket = nil
            steerProbeOwner = nil
            return
        }
        guard !Task.isCancelled, permitsPublication(), let owner = pollingIdentity,
              let peer, !peer.isEmpty, remoteSteer == nil, !steerProbeStarted else { return }
        let ticket = UUID()
        steerProbeTicket = ticket
        steerProbeOwner = owner
        steerProbeStarted = true
        defer {
            if steerProbeTicket == ticket {
                steerProbeTicket = nil
                steerProbeOwner = nil
                steerProbeStarted = false
            }
        }
        let asked = peer
        let version = try? await Bridge.peerProtocolVersion(asked)
        guard steerProbeTicket == ticket, pollIsCurrent(owner), permitsPublication(), self.peer == asked else { return }
        if let version {
            remoteSteer = version >= RemoteHostFeature.steer.minimumProtocol
        }
    }

    /// Send a note the turn ended without taking. The queue runs only when
    /// that note is gone and this conversation is still the one on screen.
    private func performSteerDelivery(_ context: ChatSteerContext) async {
        guard deliveringSteer == context, let token = deliveringSteerToken,
              let id = context.reference.itemID else { return }
        defer { finishSteerDelivery(context, token: token) }
        let asked = context.peer
        @MainActor func current() -> Bool {
            !Task.isCancelled && context.matches(reference: currentReference,
                generation: selectionGeneration, peer: peer, scope: WorkSessionContext.shared.scope)
        }
        guard current(), let mutation = steerMutationSnapshot(context.reference) else { return }
        let note = selected?.pendingSteer
        do {
            let result = try await Bridge.steerDeliverChat(id: id, peer: asked)
            let sameNote = !current() || self.selected?.pendingSteer == nil || self.selected?.pendingSteer == note
            let removed = sameNote && rememberSteerMutation(context.reference, note: nil, since: mutation)
            guard current(), removed else { return }
            if result.delivered {
                if let conversation = result.conversation { replace(conversation, preservePendingSteer: false) }
                else { clearLocalSteer() }
                return
            }
            clearLocalSteer()
        } catch {
            guard current() else { return }
            let message = hostMessage(error)
            if message == "This chat is still in the middle of a turn." {
                return
            }
            if isUnknownMethod(error) {
                finishSteerDelivery(context, token: token)
                if let asked, !asked.isEmpty, self.peer == asked { remoteSteer = false }
                if await reloadOpenChats(), current(), !busy { await drainQueue() }
                return
            }
            finishSteerDelivery(context, token: token)
            if self.error != message { self.error = message }
            _ = await reloadOpenChats()
            return
        }
        finishSteerDelivery(context, token: token)
        guard current() else { return }
        _ = await reloadOpenChats()
        guard current() else { return }
        if !busy { await drainQueue() }
    }

    /// Refresh the open list without drawing an unchanged one. False when the
    /// read failed or the reader has moved on.
    private func reloadOpenChats() async -> Bool {
        guard let selected else { return false }
        let generation = selectionGeneration
        let listRead = beginChatListRead(workspaceID: selected.workspaceID, peer: peer)
        do {
            let answer = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return false }
            let latest = applyChatList(answer, read: listRead, current: chats)
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == selected.id }),
               current != self.selected {
                self.selected = current
                #if !os(macOS)
                if !Task.isCancelled {
                    ClientChatReadState.shared.markRead(peer: peer, chat: current)
                }
                #endif
            }
            settleNotifications()
            return true
        } catch {
            return false
        }
    }

    var hasRunningTool: Bool {
        // Memoized via the same DisplayKey as displayItems itself: scanning
        // displayItems on every poll (400ms) and on every onChange was the
        // second per-frame cost after coalescing.
        _ = displayRevision
        return hasRunningToolCache(for: displayKey) ?? computeHasRunningTool()
    }

    @ObservationIgnored private var hasRunningToolCacheKey: DisplayKey?
    @ObservationIgnored private var hasRunningToolCacheValue = false

    private func hasRunningToolCache(for key: DisplayKey?) -> Bool? {
        guard let key, key == hasRunningToolCacheKey else { return nil }
        return hasRunningToolCacheValue
    }

    private func computeHasRunningTool() -> Bool {
        let value = displayItems.contains { item in
            switch item.kind {
            case let .tool(state): return state.running
            case let .edit(state): return state.running
            default: return false
            }
        }
        hasRunningToolCacheKey = displayKey
        hasRunningToolCacheValue = value
        return value
    }

    var hasPendingResponseAttachments: Bool {
        !loadingResponseAttachments.isEmpty
    }

    /// The face of the conversation on screen.
    ///
    /// Its persona's, when it has one, so the same character follows a persona
    /// between chats. Otherwise the chat's own, derived from its id, because
    /// every conversation should have a face whether or not anybody has made a
    /// persona yet.
    var faceSeed: UInt64 {
        selected.map(faceSeed(for:)) ?? personaSeed(for: "chat")
    }

    /// The face for a chat that does not exist yet.
    ///
    /// The workspace's default persona, because that is the character the next
    /// conversation in this folder will actually have. An empty screen showing
    /// some other creature would be introducing somebody who never turns up.
    ///
    /// Falls back to the first persona there is, and then to a face derived
    /// from the workspace itself, so a folder whose personas have not loaded
    /// yet still has a character rather than a gap.
    var defaultFaceSeed: UInt64 {
        if let defaultPersonaID,
           let persona = personas.first(where: { $0.id == defaultPersonaID }) {
            return persona.seed
        }
        if let first = personas.first {
            return first.seed
        }
        return personaSeed(for: workspaceID ?? folderID ?? "chat")
    }

    /// The face a conversation carries when it is shown somewhere other than
    /// the open transcript, such as the workspace launcher.
    func faceSeed(for chat: ChatConversation) -> UInt64 {
        if let personaID = chat.personaID,
           let persona = personas.first(where: { $0.id == personaID }) {
            return persona.seed
        }
        return personaSeed(for: chat.id)
    }

    /// The conversation worth returning to, independent of list ordering.
    var mostRecent: ChatConversation? {
        chats.max { lhs, rhs in lhs.updatedAtMs < rhs.updatedAtMs }
    }

    /// True while a tool is actually running, as opposed to the agent thinking.
    var isRunningTool: Bool {
        displayItems.contains { item in
            switch item.kind {
            case let .tool(state): return state.running
            case let .edit(state): return state.running
            default: return false
            }
        }
    }

    func backend(for id: String) -> ChatBackend? {
        backends.first { $0.id == id }
    }

    /// What this conversation has spent.
    ///
    /// The host's figure where there is one, because it covers the whole
    /// archive and this model only holds a window of it. Folding what is
    /// resident would make the meter climb as somebody read backwards.
    var turnUsage: ChatUsageSummary {
        // Read on every draw of the meter, which redraws on every poll.
        // Folding the whole window that often is what made a long running
        // chat re-scan thousands of records 2.5x a second.
        let key = UsageKey(
            epoch: eventsEpoch,
            count: events.count,
            firstSeq: events.first?.seq,
            lastSeq: events.last?.seq,
            through: usageThrough,
            hasBase: conversationUsage != nil
        )
        if key == turnUsageKey { return turnUsageCache }
        var totals = conversationUsage ?? .zero
        guard totals.isValid else {
            turnUsageCache = .unavailable
            turnUsageKey = key
            return .unavailable
        }
        for timeline in events {
            guard let event = timeline.event, event.kind == "usage" else { continue }
            // With a host figure in hand, only what has been written since it
            // was counted. Without one, this host reads whole conversations,
            // so everything held is everything there is.
            if conversationUsage != nil, let usageThrough, (timeline.seq ?? 0) <= usageThrough { continue }
            guard totals.add(ChatUsageTotals(input: event.input ?? 0, output: event.output ?? 0,
                cacheRead: event.cacheRead ?? 0, cacheWrite: event.cacheWrite ?? 0,
                cost: event.costUsd ?? 0)) else {
                turnUsageCache = .unavailable
                turnUsageKey = key
                return .unavailable
            }
        }
        let answer: ChatUsageSummary = totals.isEmpty ? .empty : .available(totals)
        turnUsageCache = answer
        turnUsageKey = key
        return answer
    }

    /// What a cached usage fold was folded from. Same window identity as the
    /// row cache, plus what the fold itself filters on.
    private struct UsageKey: Equatable {
        var epoch: UInt64
        var count: Int
        var firstSeq: UInt64?
        var lastSeq: UInt64?
        var through: UInt64?
        var hasBase: Bool
    }

    @ObservationIgnored private var turnUsageCache: ChatUsageSummary = .empty
    @ObservationIgnored private var turnUsageKey: UsageKey?

    var hasStarted: Bool {
        !events.isEmpty || selected?.resumeToken != nil
    }

    /// Consecutive text and thinking deltas become one block each, and a
    /// ToolEnd lands on the ToolStart it belongs to so the row can show
    /// running, duration and failure without a second line.
    ///
    /// Answered from the last result while the records behind it are the same
    /// ones. Every view of a conversation reads this several times per draw
    /// (the rows themselves, whether a tool is running, what the live seat is
    /// doing, which rows to measure), and folding a window of several hundred
    /// records into rows that many times per frame is what made a long chat
    /// impossible to scroll.
    var displayItems: [ChatDisplayItem] {
        let pending = outgoing
        let coalesced = coalescedItems
        if pending.isEmpty { return coalesced }
        return coalesced + pending
    }

    /// `displayItems` without the prompts still being sent.
    private var coalescedItems: [ChatDisplayItem] {
        _ = displayRevision
        return displayCache
    }

    /// Build against a snapshot, then publish the records and rows together.
    /// A prepend and a tail read can overlap: if either moved the window while
    /// CPU work ran, rebuild against that window rather than losing its records.
    @discardableResult
    private func publishEvents(id: String, generation: UInt64,
                               canPublish: () -> Bool = { true },
                               rebasesWindow: Bool = true, recordsChanged: Bool = true,
                               transform: ([ChatTimelineEvent]) -> [ChatTimelineEvent]) async -> Bool {
        let initialRevision = eventsRevision
        while !Task.isCancelled, selectionMatches(id: id, generation: generation), canPublish() {
            guard rebasesWindow || eventsRevision == initialRevision else { return false }
            let revision = eventsRevision
            let backend = selected?.backend
            let running = selected?.running == true
            let next = transform(events)
            guard let rows = try? await transcriptProjector.project(next, backend: backend, running: running),
                  !Task.isCancelled, selectionMatches(id: id, generation: generation), canPublish() else { return false }
            guard rebasesWindow || eventsRevision == initialRevision else { return false }
            guard revision == eventsRevision, backend == selected?.backend,
                  running == (selected?.running == true) else { continue }
            if recordsChanged { events = next }
            commitDisplay(rows)
            return true
        }
        return false
    }

    private func commitDisplay(_ rows: [ChatDisplayItem]) {
        let nextKey = DisplayKey(epoch: eventsRevision, count: events.count,
            firstSeq: events.first?.seq, lastSeq: events.last?.seq,
            backend: selected?.backend, running: selected?.running == true)
        if displayKey != nextKey { displayRevision &+= 1 }
        displayKey = nextKey
        foldKey = nil
        hasRunningToolCacheKey = nil
        // Equal rows do not invalidate a visible transcript on metadata polls.
        if displayCache != rows { displayCache = rows }
    }

    private func refreshDisplayMetadata() {
        displayMetadataTask?.cancel()
        guard !events.isEmpty, let id = selected?.id else { return }
        let generation = selectionGeneration
        displayMetadataTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.publishEvents(id: id, generation: generation, recordsChanged: false) { $0 }
        }
    }

    /// Parse the prose in the rows now, off the main thread.
    ///
    /// Called when a page of a conversation lands, never while one is
    /// streaming. A row that scrolls into view would otherwise parse its own
    /// markdown inside `init`, on the main thread, in the middle of a layout
    /// pass, which is a stall on exactly the frame a reader is scrolling back
    /// through history. A message that is still being written is a different
    /// string on every token and is not worth warming.
    func warmMarkdown() {
        Self.warmMarkdown(displayItems)
    }

    private static func warmMarkdown(_ items: [ChatDisplayItem]) {
        MarkdownText.warm(items.compactMap { item in
            switch item.kind {
            case let .user(text): text
            case let .assistant(text, _): text
            case let .thinking(text): text
            case let .failed(text): text
            case let .handoff(_, brief): brief
            default: nil
            }
        })
    }

    /// What the cached rows were folded from. Cheap to build, and every way
    /// the window can change moves at least one field of it.
    private struct DisplayKey: Equatable {
        var epoch: UInt64
        var count: Int
        var firstSeq: UInt64?
        var lastSeq: UInt64?
        var backend: String?
        var running: Bool
    }

    private var displayCache: [ChatDisplayItem] = []
    private var displayRevision: UInt64 = 0
    @ObservationIgnored private var eventsRevision: UInt64 = 0
    @ObservationIgnored private let transcriptProjector = ChatTranscriptProjector()
    @ObservationIgnored private var displayMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var displayKey: DisplayKey?

    /// The folded rows, held for the same reason as `displayCache`: a
    /// transcript asks for them several times per draw.
    private struct FoldKey: Equatable {
        var display: DisplayKey?
        var detail: ChatDetail
        var open: Bool
        var toggled: Set<String>
    }

    @ObservationIgnored private var foldCache: [ChatDisplayItem] = []
    @ObservationIgnored private var foldKey: FoldKey?

    /// Show the prompt in the transcript the moment Send is pressed.
    @discardableResult
    private func stageOutgoing(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = "outgoing-\(UUID().uuidString)"
        outgoing.append(ChatDisplayItem(id: id, kind: .user(trimmed)))
        outgoingWatermark[id] = events.compactMap(\.seq).max()
        return id
    }

    private func dropOutgoing(_ id: String?) {
        guard let id else { return }
        outgoing.removeAll { $0.id == id }
        outgoingWatermark.removeValue(forKey: id)
    }

    /// Newest archive seq seen when each prompt was staged, by staged id.
    /// A text match only counts when it is newer than the send: without this
    /// a repeated prompt ("hi" twice) is dropped by the older copy, and a
    /// host that echoes the text in another form would leave a ghost bubble
    /// that never matches. Hosts without seq fall back to text matching.
    @ObservationIgnored private var outgoingWatermark: [String: UInt64?] = [:]

    /// Drop staged prompts the archive has now given back.
    ///
    /// The stored text can grow a suffix (attachment names), so a prefix
    /// match still counts as the same send. A newer user record also drops
    /// the bubble even when the text matches nothing: the host moved past
    /// this send, so whatever it stored is this prompt under some form.
    private func reconcileOutgoing() {
        guard !outgoing.isEmpty else { return }
        let userSeqs: [UInt64?] = events.lazy
            .filter { $0.kind == "user" }
            .map { $0.seq }
        outgoing.removeAll { item in
            guard case let .user(text) = item.kind else {
                outgoingWatermark.removeValue(forKey: item.id)
                return true
            }
            let watermark = outgoingWatermark[item.id] ?? nil
            let matched = events.contains { event in
                guard event.kind == "user", let held = event.text else { return false }
                guard held == text || held.hasPrefix(text) else { return false }
                // Same text sent before is not this send arriving.
                if let seq = event.seq, let watermark { return seq > watermark }
                return true
            }
            // The host stored something newer from this person. Sends are
            // serialized, so that record is this send under another form.
            let movedPast = userSeqs.contains { seq in
                guard let seq, let watermark else { return false }
                return seq > watermark
            }
            if matched || movedPast { outgoingWatermark.removeValue(forKey: item.id) }
            return matched || movedPast
        }
    }

    /// Bumped whenever the window is replaced rather than grown. A host older
    /// than `seq` gives its records no identity of their own, and two
    /// different windows of the same size would otherwise look like one.
    @ObservationIgnored private var eventsEpoch: UInt64 = 0
    @ObservationIgnored private var windowReplacementTicket: UUID?

    private func beginWindowReplacement() -> UUID {
        let ticket = UUID()
        windowReplacementTicket = ticket
        eventsEpoch &+= 1
        return ticket
    }

    private func finishWindowReplacement(_ ticket: UUID) {
        if windowReplacementTicket == ticket { windowReplacementTicket = nil }
    }

    /// Everything a window of the timeline is, forgotten in one place.
    private func forgetWindow() {
        windowReplacementTicket = nil
        eventsEpoch &+= 1
        offset = 0
        tailCursor = nil
        conversationUsage = nil
        usageThrough = nil
        earlierCursor = nil
        hasEarlier = false
        loadingEarlier = false
        earlierInFlight = false
        reachedStart = false
        historyTrimmed = false
    }

    /// Open a conversation on its newest page rather than on its beginning.
    ///
    /// A conversation is read from the end because that is where a person
    /// starts reading it. What comes before is fetched a page at a time as
    /// they scroll back, so opening a long chat costs one bounded read
    /// whatever is behind it.
    ///
    /// One latest page on ordinary open. Older pages are requested only by
    /// scrolling back or following an explicit reading/search destination.
    @discardableResult
    private func openEvents(id: String, generation: UInt64, quiet: Bool = false) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        guard !pagingUnavailable else {
            return await loadEvents(id: id, reset: true, generation: generation, quiet: quiet)
        }
        let replacement = beginWindowReplacement()
        let requestedEpoch = eventsEpoch
        defer { finishWindowReplacement(replacement) }
        let requestedRevision = selected?.sendRevision
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: nil, limit: ChatPaging.openPageEvents, peer: peer
            )
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), requestedEpoch == eventsEpoch else { return false }
            if let requestedRevision { contextRevision = max(contextRevision ?? 0, requestedRevision) }
            guard await publishEvents(id: id, generation: generation,
                canPublish: { requestedEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in page.events }) else { return false }
            // A live page is the conversation again, not a copy of it.
            savedCopy = nil
            reconcileOutgoing()
            offset = page.nextOffset
            tailCursor = page.tailCursor
            earlierCursor = page.cursor
            hasEarlier = page.hasEarlier
            historyTrimmed = page.historyTrimmed
            conversationUsage = page.usage
            usageThrough = page.events.compactMap(\.seq).max()
            // Opened where the archive begins, with content on screen: say
            // so. Otherwise a fully loaded conversation is indistinguishable
            // from one stuck mid-history. Empty chats stay quiet.
            reachedStart = !page.hasEarlier && !page.events.isEmpty
            finishWindowReplacement(replacement)
            warmMarkdown()
            settleNotifications()
            keepOfflineCopy(id: id, title: selected?.title, page: page, sendRevision: requestedRevision)
            scheduleResponseAttachments(id: id, generation: generation)
            return true
        } catch {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation),
                  requestedEpoch == eventsEpoch else { return false }
            if isUnknownMethod(error) { pagingUnavailable = true }
            // Whatever went wrong, the conversation still has to appear. The
            // whole-timeline read is the behaviour every host has had.
            return await loadEvents(id: id, reset: true, generation: generation, quiet: quiet)
        }
    }

    /// Pull the page before the oldest one held, and put it in front.
    ///
    /// Called by the transcript as the top comes near, so the page is usually
    /// already there by the time somebody reaches it.
    func loadEarlier() async {
        // The copy holds no earlier pages, and fetching them would mix live
        // rows into a snapshot the banner describes as saved.
        guard savedCopy == nil, let selected else { return }
        await loadEarlier(id: selected.id, generation: selectionGeneration, quiet: false)
    }

    private func loadEarlier(id: String, generation: UInt64, quiet: Bool) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
        guard !pagingUnavailable, hasEarlier, !earlierInFlight,
              let cursor = earlierCursor
        else { return }
        var restoreAfterReplacement = false
        earlierInFlight = true
        loadingEarlier = !quiet
        defer {
            if selectionMatches(id: id, generation: generation) {
                earlierInFlight = false
                loadingEarlier = false
            }
            if restoreAfterReplacement, selectionMatches(id: id, generation: generation) {
                if let reference = currentReference, let mark = ChatReadingStore.shared.mark(for: reference) {
                    ChatReadingStore.shared.request(mark, for: reference)
                }
                readingRestorationPulse &+= 1
            }
        }
        let requestedEpoch = eventsEpoch
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: cursor, limit: ChatPaging.pageEvents, peer: peer
            )
            guard selectionMatches(id: id, generation: generation),
                  requestedEpoch == eventsEpoch, cursor == earlierCursor else { return }
            if page.reset {
                // The archive was trimmed while this was in flight, so the
                // offsets under the cursor no longer mean anything. This page
                // is the newest one: take it as the whole window rather than
                // putting it in front of records it now sits after.
                let replacement = beginWindowReplacement()
                let replacementEpoch = eventsEpoch
                defer { finishWindowReplacement(replacement) }
                guard await publishEvents(id: id, generation: generation, canPublish: { replacementEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in page.events }) else { return }
                reconcileOutgoing()
                offset = page.nextOffset
                tailCursor = page.tailCursor
                conversationUsage = page.usage
                usageThrough = page.events.compactMap(\.seq).max()
                warmMarkdown()
            } else {
                // Pages do not overlap, but a trim or a retry could still put
                // a record in two answers. Identity is the record's place in
                // the archive, so a repeat is cheap to spot.
                guard await publishEvents(id: id, generation: generation, canPublish: {
                    requestedEpoch == self.eventsEpoch && cursor == self.earlierCursor
                }, transform: { held in
                    let oldest = held.first?.seq ?? UInt64.max
                    let fresh = page.events.filter { ($0.seq ?? 0) < oldest }
                    return fresh + held
                }) else { return }
                warmMarkdown()
            }
            // Always, even for a page that carried nothing this window can
            // use. The cursor is how the walk moves: keeping the old one
            // means asking the same question on every frame of every scroll
            // and never reaching the beginning.
            earlierCursor = page.cursor
            hasEarlier = page.hasEarlier
            historyTrimmed = page.reset ? page.historyTrimmed : historyTrimmed || page.historyTrimmed
            if page.reset {
                reachedStart = !hasEarlier && !page.events.isEmpty
                restoreAfterReplacement = true
            } else if !hasEarlier {
                reachedStart = true
            }
            scheduleResponseAttachments(id: id, generation: generation)
        } catch {
            if !Task.isCancelled, selectionMatches(id: id, generation: generation),
               requestedEpoch == eventsEpoch, isUnknownMethod(error) {
                pagingUnavailable = true
            }
        }
    }

    /// Whether this host is simply older than the method that was called.
    ///
    /// A coded answer where the host has one, and the sentence where it does
    /// not: a build that predates the code still has to be recognised, and it
    /// is the only reason this fallback exists at all.
    private func isUnknownMethod(_ error: Error) -> Bool {
        if case let BridgeError.core(code, message) = error {
            return code == "unknown_method" || message.hasPrefix("unknown ")
        }
        return false
    }

    @discardableResult
    private func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool = false,
                            onFreshEvents: (([ChatTimelineEvent]) -> Void)? = nil) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        guard reset || windowReplacementTicket == nil else { return false }
        let replacement = reset ? beginWindowReplacement() : nil
        let requestedEpoch = eventsEpoch
        defer { if let replacement { finishWindowReplacement(replacement) } }
        let requestedRevision = selected?.sendRevision
        let requestedOffset = reset ? 0 : offset
        let requestedCursor = reset ? nil : tailCursor
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: requestedOffset, tailCursor: requestedCursor, peer: peer)
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), requestedEpoch == eventsEpoch else { return false }
            guard reset || (requestedOffset == offset && requestedCursor == tailCursor) else { return false }
            if chunk.reset {
                let opened = await openEvents(id: id, generation: generation, quiet: quiet)
                if opened, selectionMatches(id: id, generation: generation) {
                    // A replacement can move the current row or leave it in
                    // an older page. Restore the reader after the new window
                    // lands, just as on a deliberate return to this chat.
                    if let reference = currentReference, let mark = ChatReadingStore.shared.mark(for: reference) {
                        ChatReadingStore.shared.request(mark, for: reference)
                    }
                    readingRestorationPulse &+= 1
                }
                return opened
            }
            if let requestedRevision { contextRevision = max(contextRevision ?? 0, requestedRevision) }
            // A poll that found nothing new must not write anything back. The
            // write is what redraws the transcript, and most polls of a
            // running turn arrive between records rather than on one.
            if !reset, chunk.events.isEmpty, chunk.nextOffset == offset {
                tailCursor = chunk.tailCursor
                scheduleResponseAttachments(id: id, generation: generation)
                return true
            }
            if !reset { onFreshEvents?(chunk.events) }
            if reset {
                guard await publishEvents(id: id, generation: generation,
                    canPublish: { requestedEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in chunk.events }) else { return false }
                // A live page is the conversation again, not a copy of it.
                savedCopy = nil
                // The whole timeline, so there is nothing before it. Say so
                // when there is something on screen; empty chats stay quiet.
                earlierCursor = nil
                hasEarlier = false
                reachedStart = !chunk.events.isEmpty
                keepOfflineCopy(
                    id: id, title: selected?.title,
                    page: ChatEventPage(events: chunk.events, nextOffset: chunk.nextOffset, tailCursor: chunk.tailCursor),
                    sendRevision: requestedRevision
                )
            } else {
                guard await publishEvents(id: id, generation: generation, canPublish: {
                    requestedEpoch == self.eventsEpoch && requestedOffset == self.offset && requestedCursor == self.tailCursor
                }, transform: { held in
                    held + chunk.events
                }) else { return false }
            }
            reconcileOutgoing()
            tailCursor = chunk.tailCursor
            offset = chunk.nextOffset
            if let replacement { finishWindowReplacement(replacement) }
            settleNotifications()
            scheduleResponseAttachments(id: id, generation: generation)
            return true
        } catch {
            // Background polls must not pop an error banner on an idle
            // screen; user-initiated loads still surface.
            if !Task.isCancelled, !quiet, selectionMatches(id: id, generation: generation),
               requestedEpoch == eventsEpoch {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    /// Keep an encrypted copy of what just opened, for airplane mode.
    ///
    /// Fire and forget: a copy that cannot be sealed simply does not exist,
    /// and the live conversation is unaffected. Only the newest page is kept;
    /// earlier pages stay on the host, and the copy says so through the
    /// page's own `hasEarlier` flag.
    private func keepOfflineCopy(id: String, title: String?, page: ChatEventPage, sendRevision: UInt64?) {
        guard let reference = currentReference, reference.itemID == id,
              !page.events.isEmpty || selected?.lastMessageAtMs == nil else { return }
        let title = title ?? L10n.text("apple.chatmodel.conversation.ccca1817")
        let backend = selected?.backend
        Task {
            await WorkCacheStore.shared.saveConversation(reference: reference, title: title, page: page, backend: backend, sendRevision: sendRevision)
        }
    }

    /// Open the sealed copy when the machine cannot be reached.
    ///
    /// Only with nothing on screen: a live conversation is never replaced by
    /// an older copy of itself. The copy's rows are read-only state, and the
    /// banner says when they were saved and what they do not contain.
    private func openSavedCopy(id: String, generation: UInt64) async {
        guard selectionMatches(id: id, generation: generation),
              let reference = currentReference, reference.itemID == id,
              let copy = await WorkCacheStore.shared.savedConversation(for: reference),
              selectionMatches(id: id, generation: generation)
        else { return }
        await applySavedCopy(copy)
    }

    private func applySavedCopy(_ copy: CachedRecordPayload) async {
        guard events.isEmpty || savedCopy != nil, let id = selected?.id else { return }
        let replacement = beginWindowReplacement()
        let requestedEpoch = eventsEpoch
        defer { finishWindowReplacement(replacement) }
        let generation = selectionGeneration
        contextRevision = copy.sendRevision
        guard await publishEvents(id: id, generation: generation, canPublish: { requestedEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in copy.page.events }) else { return }
        reconcileOutgoing()
        offset = copy.page.nextOffset
        tailCursor = nil
        historyTrimmed = copy.page.historyTrimmed
        earlierCursor = nil
        hasEarlier = false
        reachedStart = false
        conversationUsage = copy.page.usage
        usageThrough = copy.page.events.compactMap(\.seq).max()
        error = nil
        savedCopy = SavedCopyInfo(title: copy.title, savedAt: copy.savedAt,
                                  hasEarlier: copy.page.hasEarlier, revision: copy.revision)
        // A snapshot never reads instructions: the read is already settled,
        // and the disclosure says so instead of waiting on a host that is
        // not answering.
        instructionsLoaded = true
        warmMarkdown()
        settleNotifications()
        if let id = selected?.id {
            let generation = selectionGeneration
            Task { scheduleResponseAttachments(id: id, generation: generation) }
        }
    }

    /// Ask the machine again from the saved-copy banner. A live answer
    /// replaces the copy; another failure keeps it, with its saved time.
    func checkSavedCopyForUpdates(prepareConnection: (() async throws -> Void)? = nil, quiet: Bool = false) async {
        guard savedCopy != nil, !checkingSavedCopy, let chat = selected,
              let workspaceID, let reference = currentReference else { return }
        guard reference.scope == WorkSessionContext.shared.scope else {
            error = L10n.text("apple.chatmodel.verify_your_account_before_returning_to_th.a9d4a28a")
            return
        }
        let generation = selectionGeneration
        let targetPeer = peer
        func stillCurrent() -> Bool {
            !Task.isCancelled && reference.scope == WorkSessionContext.shared.scope
                && selectionMatches(id: chat.id, generation: generation)
                && currentReference == reference
        }
        savedCopyCheckGeneration = generation
        defer {
            if savedCopyCheckGeneration == generation { savedCopyCheckGeneration = nil }
        }
        do {
            try await prepareConnection?()
            guard stillCurrent() else { return }
            if let targetPeer {
                let allowed = try await Bridge.workspaceAccessAllowed(peer: targetPeer)
                guard stillCurrent() else { return }
                guard allowed else {
                    error = L10n.text("apple.chatmodel.allow_workspace_access_on_the_other_comput.4dacd28c")
                    return
                }
                let version = try await Bridge.peerProtocolVersion(targetPeer)
                guard stillCurrent() else { return }
                guard version >= RemoteHostFeature.chat.minimumProtocol else {
                    error = L10n.text("apple.chatmodel.update_tokenstat_on_the_other_computer_bef.4aa383e2")
                    return
                }
            }
            let listRead = beginChatListRead(workspaceID: workspaceID, peer: targetPeer)
            let answer = try await Bridge.chats(workspaceID: workspaceID, peer: targetPeer)
            guard stillCurrent() else { return }
            let liveChats = applyChatList(answer, read: listRead, current: chats)
            guard let live = liveChats.first(where: { $0.id == chat.id && $0.workspaceID == workspaceID }) else {
                error = L10n.text("apple.chatmodel.this_conversation_is_no_longer_on_the_mach.de283833")
                return
            }
            replace(live, preservePendingSteer: false)
            await select(live)
        } catch {
            guard stillCurrent() else { return }
            if !quiet { self.error = error.localizedDescription }
        }
    }

    func clearCachedAttachmentMemory() {
        attachmentCacheGeneration &+= 1
        responseAttachmentData = [:]
        attachmentPreviews = [:]
        loadingResponseAttachments = []
        responseAttachmentErrors = [:]
        // Also stop the remainder of a background page's download queue.
        attemptedResponseAttachments.formUnion(events.compactMap { timeline in
            guard timeline.event?.kind == "attachment" else { return nil }
            return timeline.event?.id
        })
    }

    func downloadResponseAttachment(_ attachment: ChatAttachment) async {
        // Saved previews load locally with the page. A missing preview never
        // starts a live download against a saved conversation.
        guard savedCopy == nil, let selected else { return }
        await loadResponseAttachment(
            attachment, id: selected.id, generation: selectionGeneration, userInitiated: true
        )
    }

    private func scheduleResponseAttachments(id: String, generation: UInt64) {
        guard !Task.isCancelled, let reference = currentReference, selectionMatches(id: id, generation: generation),
              responseAttachmentDescriptors.contains(where: { !attemptedResponseAttachments.contains($0.id) }) else { return }
        let owner = PollOwner(reference: reference, generation: generation)
        _ = attachmentPollLane.start(owner: owner) { [weak self] permitsPublication in
            guard let self else { return }
            while permitsPublication(), self.selectionMatches(id: id, generation: generation),
                  self.currentReference == reference {
                let revision = self.eventsRevision
                await self.loadResponseAttachments(id: id, generation: generation)
                if revision == self.eventsRevision { break }
            }
        }
    }

    /// Unchanged polls never walk the transcript again. Descriptors retain
    /// attempted files so cancellation can retry without rebuilding the index.
    private var responseAttachmentDescriptors: [ChatAttachment] {
        if attachmentDescriptorRevision != eventsRevision {
            attachmentDescriptors = events.compactMap { timeline in
                guard let event = timeline.event, event.kind == "attachment", let id = event.id else { return nil }
                return ChatAttachment(id: id, name: event.name ?? L10n.text("apple.chatmodel.attachment.040d2b36"),
                                      mediaType: event.mediaType, size: event.size)
            }
            attachmentDescriptorRevision = eventsRevision
        }
        return attachmentDescriptors
    }

    private func loadResponseAttachments(id: String, generation: UInt64) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
        let descriptors = responseAttachmentDescriptors.filter { !attemptedResponseAttachments.contains($0.id) }
        // Keep background downloads bounded instead of fetching a whole page
        // of files concurrently. Navigation stops the remaining queue.
        for descriptor in descriptors {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
            await loadResponseAttachment(descriptor, id: id, generation: generation, userInitiated: false)
        }
    }

    private func loadResponseAttachment(
        _ attachment: ChatAttachment, id: String, generation: UInt64, userInitiated: Bool
    ) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation),
              responseAttachmentData[attachment.id] == nil,
              !loadingResponseAttachments.contains(attachment.id),
              userInitiated || !attemptedResponseAttachments.contains(attachment.id)
        else { return }
        guard let previewReference = currentReference, WorkCacheAccess.canRead(previewReference) else { return }
        let targetPeer = peer
        let memoryGeneration = attachmentCacheGeneration
        attemptedResponseAttachments.insert(attachment.id)
        loadingResponseAttachments.insert(attachment.id)
        responseAttachmentErrors[attachment.id] = nil
        defer {
            if selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration {
                loadingResponseAttachments.remove(attachment.id)
                if Task.isCancelled { attemptedResponseAttachments.remove(attachment.id) }
            }
        }
        if let saved = await WorkSavedPreview.read(reference: previewReference, attachment: attachment.id) {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentData[attachment.id] = saved
            return
        }
        guard !Task.isCancelled, savedCopy == nil, selectionMatches(id: id, generation: generation),
              memoryGeneration == attachmentCacheGeneration else { return }
        let cacheEpoch = await ChatAttachmentCache.shared.epoch()
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
        if let cached = await ChatAttachmentCache.shared.read(reference: previewReference, attachment: attachment.id) {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentData[attachment.id] = cached
            if currentReference == previewReference, WorkCacheAccess.canSave(previewReference) {
                await WorkSavedPreview.save(reference: previewReference, attachment: attachment, data: cached)
            }
            return
        }
        guard !Task.isCancelled, savedCopy == nil,
              selectionMatches(id: id, generation: generation), currentReference == previewReference,
              memoryGeneration == attachmentCacheGeneration, WorkCacheAccess.canSave(previewReference),
              userInitiated || ChatAttachmentDownloadPolicy.permitsAutomaticDownload(size: attachment.size)
        else { return }
        do {
            let payload = try await Bridge.chatAttachment(id: id, attachmentID: attachment.id, peer: targetPeer)
            guard let data = Data(base64Encoded: payload.data), !data.isEmpty,
                  data.count <= ChatInbox.maxBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), currentReference == previewReference,
                  WorkCacheAccess.canSave(previewReference), memoryGeneration == attachmentCacheGeneration else { return }
            guard await ChatAttachmentCache.shared.write(data, reference: previewReference, attachment: attachment.id, epoch: cacheEpoch) else { return }
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentData[attachment.id] = data
            if currentReference == previewReference, WorkCacheAccess.canSave(previewReference) {
                await WorkSavedPreview.save(reference: previewReference, attachment: attachment, data: data)
            }
        } catch {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentErrors[attachment.id] = Self.downloadFailure(error)
        }
    }

    /// What the card says when a file does not arrive.
    ///
    /// A retry is only worth offering when trying again could work. The host
    /// refuses a file over its transfer cap and one it can no longer find,
    /// and both of those answers are the same every time they are asked, so
    /// they are reported as they are rather than as "Tap to retry".
    private static func downloadFailure(_ error: Error) -> String {
        let reason = error.localizedDescription
        if reason.contains("quota_exceeded") {
            return L10n.text("apple.chatmodel.relay_allowance_reached_a_direct_connectio.46be688f")
        }
        if reason.localizedCaseInsensitiveContains("too large") {
            return L10n.text("apple.chatmodel.this_file_is_too_large_to_transfer_open_it.a6327156")
        }
        if reason.localizedCaseInsensitiveContains("no longer available") {
            return L10n.text("apple.chatmodel.this_file_is_no_longer_on_the_computer_tha.00478114")
        }
        return L10n.text("apple.chatmodel.download_failed_tap_to_retry.c38f779d")
    }

    /// The brief and the one rule tokenstat adds. Reloaded whenever either
    /// could have moved: a different conversation, a new backend (which changes
    /// how the text travels), or an edited brief.
    private func loadInstructions(id: String, generation: UInt64) async {
        guard !Task.isCancelled, savedCopy == nil,
              selectionMatches(id: id, generation: generation) else { return }
        instructionsLoaded = false
        do {
            let loaded = try await Bridge.chatInstructions(id: id, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            instructions = loaded
        } catch {
            // Not worth an alert. The inspector simply shows nothing rather
            // than interrupting a conversation over a disclosure nobody opened.
            if selectionMatches(id: id, generation: generation) { instructions = nil }
        }
        // Settled either way: a nil answer after this is "not available",
        // not a read still in flight.
        if selectionMatches(id: id, generation: generation) { instructionsLoaded = true }
    }

    private func loadApprovals(id: String, generation: UInt64, quiet: Bool = false,
                               permitsPublication: () -> Bool = { true }) async {
        guard !Task.isCancelled, permitsPublication(), savedCopy == nil,
              selectionMatches(id: id, generation: generation) else { return }
        do {
            let loaded = try await Bridge.chatApprovals(id: id, peer: peer)
            guard !Task.isCancelled, permitsPublication(), selectionMatches(id: id, generation: generation) else { return }
            // Unchanged approvals must not write back: the write redraws the
            // transcript, and this runs on every poll of a running turn.
            if approvals != loaded { approvals = loaded }
            approvalsLoaded = true
            settleNotifications()
        } catch {
            // A background poll must not pop an alert over an idle screen;
            // the rows keep the answers they already had.
            if !Task.isCancelled, permitsPublication(), !quiet, selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    private func selectionMatches(id: String, generation: UInt64) -> Bool {
        selectionGeneration == generation && selected?.id == id
            && continuityScope == WorkSessionContext.shared.readingScope
    }

    private func advanceSelection(_ reason: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENSTAT_VIEWPORT_TRACE"] == "1" {
            print("chat-selection model=\(ObjectIdentifier(self)) cause=\(reason) chat=\(selected?.id ?? "none") workspace=\(workspaceID ?? "none") generation=\(selectionGeneration)->\(selectionGeneration &+ 1) events=\(events.count)")
        }
        #endif
        pollWatcher.cancel()
        cancelPollReads()
        attachmentPollLane.cancel()
        cadenceOwner = nil
        displayMetadataTask?.cancel()
        selectionGeneration &+= 1
    }

    private func replace(_ chat: ChatConversation, preservePendingSteer: Bool = true) {
        let chat = preservePendingSteer
            ? ChatSteerOverlay.preservingNote(in: chat, from: chats.first { $0.id == chat.id })
            : chat
        if selected?.id == chat.id {
            selected = chat
        }
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.insert(chat, at: 0)
        }
        chats.sort { $0.updatedAtMs > $1.updatedAtMs }
        if let folderID { storeChatListCache(chats, folderID: folderID) }
        saveLaunchChoice(from: chat)
        settleNotifications()
    }

    private func settleNotifications() {
        #if os(macOS)
        let done = events.reversed().lazy.compactMap { timeline -> String? in
            guard timeline.kind == "agent", timeline.event?.kind == "done" else { return nil }
            return timeline.event?.status
        }.first
        RunNotifications.shared.settle(
            chats: chats,
            approvals: approvals,
            selectedID: selected?.id,
            selectedDoneStatus: done
        )
        #endif
    }

    /// The persona a new chat should start with, or nil to take the
    /// workspace default.
    ///
    /// Every other setup control is carried over from the last conversation.
    /// The persona was not, so choosing no persona and then pressing plus
    /// handed you a persona again, and the choice looked like it had not
    /// saved.
    ///
    /// The remembered id is checked against this workspace's list before it is
    /// used. One choice is stored for the app rather than one per folder, and
    /// a persona belonging to another folder is not available here, so an
    /// unrecognised id falls back to this folder's own answer. "No persona"
    /// needs no such check: it is a choice about this person, not about a
    /// folder, and it travels.
    private func rememberedPersonaID(_ saved: LaunchChoice?) -> String? {
        guard let remembered = saved?.personaID else { return nil }
        if remembered.isEmpty { return "" }
        guard personas.contains(where: { $0.id == remembered }) else { return nil }
        return remembered
    }

    private var lastLaunchChoice: LaunchChoice? {
        guard let data = UserDefaults.standard.data(forKey: Self.launchChoiceKey) else { return nil }
        return try? JSONDecoder().decode(LaunchChoice.self, from: data)
    }

    private func loadQueue(for id: String?) {
        authorizedQueueItems = []
        queuedReference = currentReference
        queued = []
        guard let id, let reference = queuedReference, reference.itemID == id else { return }
        do {
            queued = try ChatOutboxStore.shared.items(for: reference)
            authorizedQueueItems = Set(queued.filter { $0.whenConnected && $0.delivery == .waiting }.map(\.id))
        }
        catch { self.error = L10n.text("apple.chatmodel.saved_pending_messages_could_not_be_opened.8bc6ad06") }
        // Legacy conversation-only queues have no provable host/account owner.
        // Recovery is explicit; opening this conversation never adopts them.
    }

    private func saveLaunchChoice(from chat: ChatConversation) {
        let choice = LaunchChoice(
            backend: chat.backend,
            model: chat.model,
            effort: chat.effort,
            mode: chat.mode,
            autonomy: chat.autonomy,
            // Empty, not nil: a conversation with no persona is a choice worth
            // carrying, and nil already means "nothing recorded".
            personaID: chat.personaID ?? ""
        )
        guard let data = try? JSONEncoder().encode(choice) else { return }
        UserDefaults.standard.set(data, forKey: Self.launchChoiceKey)
    }
}


enum ChatGateCopy {
    static func chip(_ tier: String?) -> String {
        switch tier {
        case "full": return L10n.text("apple.chatmodel.approvals.2bfc3471")
        case "rules": return L10n.text("apple.chatmodel.rules.4228aeb0")
        case "bypassOnly": return L10n.text("apple.chatmodel.bypass_only.6110acbf")
        default: return L10n.text("apple.chatmodel.checking.0dfe1d63")
        }
    }

    static func explanation(_ tier: String?, bypass: Bool) -> String {
        if bypass {
            return L10n.text("apple.chatmodel.this_agent_can_use_its_backend_s_bypass_mo.620f4900")
        }
        switch tier {
        case "full":
            return L10n.text("apple.chatmodel.tokenstat_asks_before_every_tool_action_an.0dbf3a6c")
        case "rules":
            return L10n.text("apple.chatmodel.saved_permission_rules_run_anything_else_i.ef7fb8c5")
        case "bypassOnly":
            return L10n.text("apple.chatmodel.this_backend_has_no_tokenstat_approval_gat.7c4924cd")
        default:
            return L10n.text("apple.chatmodel.checking_this_backend_s_permission_support.13f013cf")
        }
    }
}
