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
        didSet { noteRunningChats() }
    }
    var events: [ChatTimelineEvent] = []
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
    /// Async bridge calls may finish after navigation. Only the generation
    /// that started them may mutate the currently displayed workspace/chat.
    private var loadGeneration: UInt64 = 0
    private(set) var selectionGeneration: UInt64 = 0
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
            draftConversationID = nil
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
        guard savedCopy == nil, let selected, !sending, stagingAttachments == 0, heldSubmission == nil else { return false }
        saveDraftNow()
        if let pending = queued.first(where: { $0.id == draftMessageID && $0.needsReceipt }) {
            unconfirmedSend = .init(conversationID: selected.id, messageID: pending.id, checking: false)
            error = "Check delivery before sending this draft again. An unknown receipt does not prove it was never sent."
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
                self.error = "The pending message changed. Review Pending messages before sending this edit."
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
        sending = true
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
        defer { heldSubmission = nil; sending = false; deliveringFromComposer = nil }
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
                self.error = "This message could not be safely saved for sending. Your draft stays here. Review Pending messages before trying again."
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
                error = "Review the conversation before starting a new draft. The original delivery cannot be confirmed from this device."
                return
            }
            _ = await deliverQueued(item, stopCurrent: false)
        } catch { self.error = "Pending delivery could not be read. Your draft remains on this device." }
    }

    @ObservationIgnored private var recentMessages = ChatRecentMessages<ChatDisplayItem>()
    @ObservationIgnored private var previewWarmTask: Task<Void, Never>?
    private(set) var recentMessagePreview: [ChatDisplayItem] = []

    /// Opening a project's sessions also prepares its recent chat previews,
    /// without changing the active conversation or starting an agent.
    func warmWorkspacePreviews(_ folder: String) async {
        #if os(macOS)
        let scope = WorkSessionContext.shared.scope
        let route = Bridge.chatRoute(workspaceID: folder, peer: nil)
        if route.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
        guard let scope, let host = route.peer ?? WorkSessionContext.shared.localHostIdentity,
              !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
        do {
            let list = try await Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
            if continuityScope == nil { continuityScope = scope }
            guard continuityScope == scope else { return }
            storeChatListCache(Self.uniqued(list), folderID: folder)
            let prefix = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: route.workspaceID)
            for chat in list.prefix(5) {
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                let key = prefix + WorkReferenceKey.encode(chat.id)
                if !recentMessages.messages(for: key).isEmpty { continue }
                let page = try await Bridge.chatEventPage(id: chat.id, cursor: nil,
                    limit: Self.openPageEvents, peer: route.peer)
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return }
                let rows = ChatDisplayItem.coalesce(page.events,
                    defaultBackend: chat.backend, running: chat.running)
                recentMessages.store(rows, for: key) {
                    String(reflecting: $0).utf8.count
                }
                Self.warmMarkdown(recentMessages.messages(for: key))
            }
        } catch { /* A preview failure leaves normal opening available. */ }
        #endif
    }

    /// Speculative reads use the same small, memory-only preview as a chat
    /// just left. Never fall back to the legacy whole-conversation endpoint.
    private func warmRecentChats(limit: Int, after selection: String? = nil) {
        #if os(macOS)
        previewWarmTask?.cancel()
        guard !pagingUnavailable, let folderID,
              let owner = continuityOwner(folderID: folderID) else { return }
        let prefix = WorkReferenceKey.folder(scope: owner.scope,
            hostIdentity: owner.host, workspaceID: owner.workspace)
        let start = selection.flatMap { id in chats.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let candidates = Array(chats.dropFirst(start).filter { $0.id != selected?.id }.prefix(limit))
        let peer = self.peer
        previewWarmTask = Task { [weak self] in
            // Let the selected conversation and its first frame finish first.
            try? await Task.sleep(for: .milliseconds(250))
            for chat in candidates {
                guard !Task.isCancelled, let self,
                      self.folderID == folderID, self.continuityScope == owner.scope,
                      WorkSessionContext.shared.scope == owner.scope else { return }
                let key = prefix + WorkReferenceKey.encode(chat.id)
                guard self.recentMessages.messages(for: key).isEmpty else { continue }
                do {
                    let page = try await Bridge.chatEventPage(id: chat.id, cursor: nil,
                        limit: Self.openPageEvents, peer: peer)
                    guard !Task.isCancelled, self.folderID == folderID,
                          WorkSessionContext.shared.scope == owner.scope,
                          self.selected?.id != chat.id else { return }
                    let rows = ChatDisplayItem.coalesce(page.events,
                        defaultBackend: chat.backend, running: chat.running)
                    self.recentMessages.store(rows, for: key) { String(reflecting: $0).utf8.count }
                    Self.warmMarkdown(self.recentMessages.messages(for: key))
                } catch {
                    // Warming is optional. A failed read must not interrupt work.
                    return
                }
            }
        }
        #endif
    }

    var isShowingCachedTranscript: Bool { openingConversation && !recentMessagePreview.isEmpty }
    var transcriptItems: [ChatDisplayItem] { isShowingCachedTranscript ? recentMessagePreview : displayItems }

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
        recentMessagePreview = []
        guard let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope,
              let key = WorkReferenceKey.conversation(reference) else { return }
        recentMessagePreview = recentMessages.messages(for: key)
    }

    /// Adjacent conversation in the same order as the sidebar, without wrapping.
    func adjacentConversation(_ step: Int) -> ChatConversation? {
        guard let index = chats.firstIndex(where: { $0.id == selected?.id }),
              step == -1 || step == 1, chats.indices.contains(index + step) else { return nil }
        return chats[index + step]
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
    func sidebarChats(in folderID: String) -> [ChatConversation] {
        guard continuityScope == WorkSessionContext.shared.scope else { return [] }
        if self.folderID == folderID { return chats }
        return chatListCache[folderID] ?? []
    }

    private func storeChatListCache(_ list: [ChatConversation], folderID: String) {
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
        previewWarmTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        let probe = Logger(subsystem: "ai.tokenstat.tokenstat", category: "chatload")
        probe.error("load start ws=\(workspaceID) gen=\(generation) scope=\(String(describing: WorkSessionContext.shared.scope?.identity)) selectFirst=\(selectFirst)")
        let route = Bridge.chatRoute(workspaceID: workspaceID, peer: peer)
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        let scope = WorkSessionContext.shared.scope
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
            noteRunningChats()
            recentMessages.removeAll()
            recentMessagePreview = []
            chats = []
            selected = nil
            folderID = nil
            continuityScope = scope
        }
        let draftHost = route.peer ?? WorkSessionContext.shared.localHostIdentity
        if folderID != workspaceID || self.workspaceID != route.workspaceID || self.peer != route.peer {
            rememberRecentMessages()
            recentMessagePreview = []
            if self.peer != route.peer { pagingUnavailable = false }
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
            selectionGeneration &+= 1
        }
        folderID = workspaceID
        self.workspaceID = route.workspaceID
        self.peer = route.peer
        if events.isEmpty { restoreRecentMessages() }
        loadQueue(for: selected?.id)
        do {
            async let loadedBackends = Bridge.chatBackends(peer: route.peer)
            async let loadedPersonas = Bridge.chatPersonas(workspaceID: route.workspaceID, peer: route.peer)
            async let loadedChats = Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            let loaded = try await (loadedBackends, loadedPersonas, loadedChats)
            probe.error("load answered gen=\(generation)/\(self.loadGeneration) scopeThen=\(String(describing: scope?.identity)) scopeNow=\(String(describing: WorkSessionContext.shared.scope?.identity)) chats=\(loaded.2.count)")
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else {
                // A superseded load must not touch the opening flag: load N+1
                // may already have asserted opening=true in its folder-change
                // block, and clearing it here would clobber the newer load.
                return
            }
            backends = loaded.0
            personas = loaded.1.personas
            // The host says "" for a workspace that has chosen no persona.
            // Nil here means the same thing, and every reader already handles
            // it, so the empty string never gets past this line.
            defaultPersonaID = loaded.1.defaultId.isEmpty ? nil : loaded.1.defaultId
            chats = Self.uniqued(loaded.2)
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
                    error = "This conversation is no longer available in this folder. Choose another conversation from the sidebar."
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
            if generation == loadGeneration { warmRecentChats(limit: 5) }
        } catch {
            if generation == loadGeneration {
                self.error = error.localizedDescription
                // A primed folder otherwise keeps its opening state with
                // nothing coming to clear it.
                openingConversation = false
            }
        }
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
        previewWarmTask?.cancel()
        await select(chat, savedPage: nil)
        if selected?.id == chat?.id { warmRecentChats(limit: 3, after: chat?.id) }
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
        peer = reference.hostIdentity == WorkSessionContext.shared.localHostIdentity ? nil : reference.hostIdentity
        workspaceID = reference.workspaceID
        folderID = peer.map { "remote:\($0):\(reference.workspaceID)" } ?? reference.workspaceID
        var chat = ChatConversation(saved: reference, title: copy.title, backend: copy.backend)
        chat.sendRevision = copy.sendRevision
        chats = [chat]
        await select(chat, savedPage: copy)
        return savedCopy != nil
    }

    private func select(_ chat: ChatConversation?, savedPage: CachedRecordPayload?, fresh: Bool = false) async {
        if savedPage == nil, let chat, chat.id == selected?.id, !events.isEmpty {
            await refreshOpen(id: chat.id)
            return
        }
        rememberRecentMessages()
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selected = chat
        contextRevision = savedPage?.sendRevision
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
            applySavedCopy(savedPage)
            return
        }
        let openedLive = await openEvents(id: chat.id, generation: generation)
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
            await drainQueue()
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
        await drainQueue()
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
        selectionGeneration &+= 1
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
            let chosen = backends.first { $0.id == saved?.backend }
                ?? backends.first { $0.id == "codex" }
                ?? backends.first(where: { $0.id != "sh" })
                ?? backends.first
            let model = chosen?.models.contains(saved?.model ?? "") == true ? saved?.model : nil
            let effort = chosen?.efforts.contains(saved?.effort ?? "") == true ? saved?.effort : nil
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                // Execute, not plan, for a first chat on a machine. The
                // saved choice wins as soon as there is one, so this is only
                // ever the very first conversation somebody opens, and
                // planning at them is a turn that does nothing they asked
                // for. Autonomy stays standard: the agent acts, and a tool
                // that needs permission still stops and asks.
                mode: saved?.mode ?? "execute",
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
    /// Errors are swallowed on purpose: the list on screen is still the list,
    /// and an alert over a picker that already works would be worse than a
    /// button that changed nothing.
    func reloadBackends() async {
        let context = loadGeneration
        guard let loaded = try? await Bridge.chatBackends(peer: peer, refresh: true) else { return }
        guard context == loadGeneration else { return }
        backends = loaded
    }

    func update(
        title: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        effort: String? = nil,
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

    func remove(_ chat: ChatConversation) async {
        await remove(chat, in: folderID)
    }

    /// Delete one conversation shown in the sidebar.
    ///
    /// A row under another folder cannot use the live peer, which is the
    /// folder on screen and not the conversation's host. Routing by folder id
    /// deletes from the owning host and drops the row from the cache, leaving
    /// the open transcript alone.
    func remove(_ chat: ChatConversation, in folderID: String?) async {
        let targetPeer = WorkDestinationResolver.deletionPeer(folderID: folderID, currentFolderID: self.folderID, currentPeer: peer)
        let context = loadGeneration
        do {
            try await Bridge.removeChat(id: chat.id, peer: targetPeer)
            recentMessages.removeAll()
            recentMessagePreview = []
            guard context == loadGeneration else { return }
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
        } catch {
            if context == loadGeneration { self.error = error.localizedDescription }
        }
    }

    func removeAll(in folderID: String) async {
        let context = loadGeneration
        do {
            // `folderID` may encode a different remote peer than the chat
            // currently loaded in this model. Let the bridge route the folder
            // itself instead of borrowing the current conversation's peer.
            _ = try await Bridge.removeAllChats(workspaceID: folderID)
            recentMessages.removeAll()
            recentMessagePreview = []
            guard context == loadGeneration else { return }
            storeChatListCache([], folderID: folderID)
            forgetLastSelected(folderID: folderID)
            if self.folderID == folderID || workspaceID == folderID {
                chats = []
                await select(nil)
            }
        } catch {
            if context == loadGeneration { self.error = error.localizedDescription }
        }
    }

    /// A send is in flight. Set synchronously on entry (the main actor runs
    /// one task at a time, so a second tap cannot slip between the check and
    /// the set) and cleared when the bridge answers. The composer disables
    /// Send on this; without it a double-tap re-sent the same attachments,
    /// which image-only sends made reachable.
    private(set) var sending = false
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
        guard let deliveringFromComposer else { return queued }
        return queued.filter { $0.id != deliveringFromComposer }
    }
    private var queuedReference: WorkReference?
    @ObservationIgnored private var sendingNow = false
    private var authorizedQueueItems: Set<String> = []
    var queuePaused: Bool {
        guard let first = queued.first else { return false }
        return !authorizedQueueItems.contains(first.id) || first.delivery != .waiting
    }

    private var ownsQueue: Bool {
        guard let queuedReference else { return false }
        return currentReference == queuedReference && WorkCacheAccess.canRead(queuedReference)
    }

    @discardableResult
    func enqueue(_ text: String, atFront: Bool = false, whenConnected: Bool = false) -> ChatQueuedMessage? {
        guard stagingAttachments == 0, (savedCopy == nil || whenConnected), ownsQueue, let reference = queuedReference else { return nil }
        var item = ChatQueuedMessage(id: draftMessageID ?? UUID().uuidString, text: text, attachments: attachments)
        item.whenConnected = whenConnected
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
                self.error = "Check delivery in Pending messages before queuing this draft again."
                return nil
            }
            authorizedQueueItems.insert(item.id)
            attachments = []
            attachmentPreviews = [:]
            Task { await drainQueue() }
            return item
        } catch {
            self.error = "This message could not be saved to the queue. Your draft and attachments stay here. The queue holds 20 messages."
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
        } catch { self.error = "This queued message changed or could not be saved. Reopen Pending messages before editing it again." }
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
        } catch { self.error = "The queued copy could not be removed. Check its delivery first, then try again." }
    }

    func moveQueued(from offsets: IndexSet, to destination: Int, owner: WorkReference?) {
        guard let owner, owner == queuedReference, ownsQueue, let reference = queuedReference else { return }
        let expected = queued.map(\.id)
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                guard items.map(\.id) == expected else { throw ChatOutboxStore.Failure.conflict }
                items.move(fromOffsets: offsets, toOffset: destination)
            }
        } catch { self.error = "The queue changed or could not be saved. Reopen Pending messages to see its current order." }
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
        guard savedCopy == nil else {
            error = "Check for updates to return to the live conversation before sending or checking delivery. Your pending copy stays here."
            return
        }
        if item.delivery == .needsReview {
            guard let revision = contextRevision else {
                error = "Check for updates before using the latest conversation context. Your message stays here."
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
                error = "The message is ready with the conversation context you last opened. Choose Send now when you are ready."
            } catch { self.error = "The pending message changed. Reopen it before using the latest context." }
            return
        }
        guard !sendingNow else { return }
        sendingNow = true
        defer { sendingNow = false }
        _ = await deliverQueued(item, stopCurrent: true)
    }

    func drainQueue() async {
        guard !busy, !sending, !sendingNow, !queuePaused, let item = queued.first else { return }
        if await deliverQueued(item, stopCurrent: false), !busy {
            await drainQueue()
        }
    }

    /// A refusal with no words looks like a dead button: the message stays
    /// queued, the draft comes back, and nothing says why.
    private func busyTurnError() {
        error = "This conversation is still finishing its previous turn. Wait a moment, or press Stop and send again."
    }

    /// Acceptance updates the captured owner's disk record even if navigation
    /// changes. Nothing leaves the outbox before the host's acknowledgement.
    private func deliverQueued(_ candidate: ChatQueuedMessage, stopCurrent: Bool, reserved: Bool = false) async -> Bool {
        guard savedCopy == nil, ownsQueue, (!sending || reserved), let reference = queuedReference,
              WorkCacheAccess.canSave(reference), let conversationID = reference.itemID,
              ChatOutboxStore.shared.beginDelivery(reference) else { return false }
        sending = true
        defer { ChatOutboxStore.shared.endDelivery(reference); sending = false }
        let targetPeer = peer
        let generation = selectionGeneration
        func current() -> Bool {
            !Task.isCancelled && selectionMatches(id: conversationID, generation: generation)
                && currentReference == reference && WorkCacheAccess.canSave(reference) && savedCopy == nil
        }
        func publish(_ items: [ChatQueuedMessage]) {
            if currentReference == reference { queued = items }
        }
        do {
            guard try await machineConfirmsSends(peer: targetPeer, checkingReceipt: candidate.needsReceipt), current() else {
                if current() { error = candidate.needsReceipt
                    ? "Update this computer to check message delivery. Your pending copy stays here."
                    : "Update this computer before sending. It needs the latest message confirmation support. Your draft stays here." }
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
                error = "The pending message changed. Review its current copy before sending."
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
                    ? "The computer could not confirm whether this message started. Review the conversation before copying it into a new draft. Your pending copy stays here."
                    : "Delivery is not confirmed. Check the conversation before copying this message into a new draft. An unknown receipt is not proof it was never sent." }
                return false
            }
            guard item.delivery != .needsReview, item.expectedRevision != nil else {
                publish(try ChatOutboxStore.shared.update(reference) { items in
                    if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].delivery = .needsReview }
                })
                authorizedQueueItems.remove(item.id)
                if current() { error = "Review the live conversation, then choose Use latest context in Pending messages. Your message has not been sent." }
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
                    ? "The machine did not confirm delivery. Your queued copy stays here. Choose Check delivery before doing anything else."
                    : error.localizedDescription }
                return false
            }
        } catch {
            authorizedQueueItems.remove(candidate.id)
            if current() {
                self.error = candidate.needsReceipt
                    ? "Delivery could not be checked. The original stays pending; check delivery again before starting a new message."
                    : "This message stays pending. " + error.localizedDescription
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
            error = "That file could not be read."
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
            error = "A draft can include up to 20 files. Remove a file before adding another."
            return
        }
        if item.data.count > ChatInbox.maxBytes {
            error = "An attachment is limited to 12 MB."
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
        do {
            try await Bridge.stopChat(id: selected.id, peer: peer)
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
            return
        }
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        await loadEvents(id: selected.id, reset: false, generation: generation)
        await loadApprovals(id: selected.id, generation: generation)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
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

    /// An idle conversation can receive a turn from another device. Keep
    /// watching its event offset, then return to fast reads when work appears.
    var pollInterval: Duration {
        busy || hasPendingResponseAttachments ? .milliseconds(400) : .seconds(2)
    }

    func poll() async {
        guard !Task.isCancelled, !openingConversation, savedCopy == nil, let selected else { return }
        let generation = selectionGeneration
        await loadEvents(id: selected.id, reset: false, generation: generation, quiet: true)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        await loadApprovals(id: selected.id, generation: generation, quiet: true)
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        do {
            let latest = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            // A poll that found nothing new must not write anything back.
            // Same rule as the event chunk below: the write is what redraws
            // the transcript, and most polls of a running turn arrive with
            // an unchanged list.
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
        } catch {}
    }

    var busy: Bool {
        selected?.running == true
    }

    var hasRunningTool: Bool {
        // Memoized via the same DisplayKey as displayItems itself: scanning
        // displayItems on every poll (400ms) and on every onChange was the
        // second per-frame cost after coalescing.
        hasRunningToolCache(for: displayKey) ?? computeHasRunningTool()
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
        // Reading `events` here is also what tells Observation that a view
        // depends on it, so the cheap path must still touch it.
        let key = DisplayKey(
            epoch: eventsEpoch,
            count: events.count,
            firstSeq: events.first?.seq,
            lastSeq: events.last?.seq,
            backend: selected?.backend,
            running: selected?.running == true
        )
        let pending = outgoing
        let coalesced: [ChatDisplayItem]
        if key == displayKey {
            coalesced = displayCache
        } else {
            displayCache = ChatDisplayItem.coalesce(events, defaultBackend: key.backend, running: key.running)
            displayKey = key
            coalesced = displayCache
        }
        if pending.isEmpty { return coalesced }
        return coalesced + pending
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

    @ObservationIgnored private var displayCache: [ChatDisplayItem] = []
    @ObservationIgnored private var displayKey: DisplayKey?

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

    /// Everything a window of the timeline is, forgotten in one place.
    private func forgetWindow() {
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
        let requestedRevision = selected?.sendRevision
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: nil, limit: Self.openPageEvents, peer: peer
            )
            guard selectionMatches(id: id, generation: generation) else { return false }
            if let requestedRevision { contextRevision = max(contextRevision ?? 0, requestedRevision) }
            eventsEpoch &+= 1
            events = page.events
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
            warmMarkdown()
            settleNotifications()
            keepOfflineCopy(id: id, title: selected?.title, page: page, sendRevision: requestedRevision)
            await loadResponseAttachments(id: id, generation: generation)
            return true
        } catch {
            guard selectionMatches(id: id, generation: generation) else { return false }
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
        do {
            let page = try await Bridge.chatEventPage(
                id: id, cursor: cursor, limit: Self.pageEvents, peer: peer
            )
            guard selectionMatches(id: id, generation: generation) else { return }
            if page.reset {
                // The archive was trimmed while this was in flight, so the
                // offsets under the cursor no longer mean anything. This page
                // is the newest one: take it as the whole window rather than
                // putting it in front of records it now sits after.
                eventsEpoch &+= 1
                events = page.events
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
                let oldest = events.first?.seq ?? UInt64.max
                let fresh = page.events.filter { ($0.seq ?? 0) < oldest }
                events.insert(contentsOf: fresh, at: 0)
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
            await loadResponseAttachments(id: id, generation: generation)
        } catch {
            if selectionMatches(id: id, generation: generation), isUnknownMethod(error) {
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

    /// How many records a conversation opens on. Records, not rows: streamed
    /// text arrives in many pieces and becomes one paragraph.
    ///
    /// Large, and it used to be small for a reason that turned out to be
    /// backwards. The cost that hurts is not the number of rows, it is the
    /// number of *insertions*: each one changes the content height, and a
    /// changed content height makes the lazy stack resolve estimates for the
    /// rows in between, which means building them and measuring their text.
    /// So a page that reads four times as much history costs one of those
    /// walks where four small pages cost four. Five hundred is the host's own
    /// ceiling on `chat.eventPage`, so asking for more only asks for this.
    private static let openPageEvents = 500
    /// How many records each older page carries.
    ///
    /// Nearly as large as the opening page, for the same reason. A backend
    /// that streams spends hundreds of records on a handful of paragraphs,
    /// and pulling fifty of them at a time meant a chat of any length was
    /// read back in dozens of insertions, each one a walk over the rows and a
    /// correction of the reader's place.
    private static let pageEvents = 400
    @discardableResult
    private func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool = false) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        let requestedRevision = selected?.sendRevision
        let requestedOffset = reset ? 0 : offset
        let requestedCursor = reset ? nil : tailCursor
        do {
            let chunk = try await Bridge.chatEvents(id: id, offset: requestedOffset, tailCursor: requestedCursor, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return false }
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
            tailCursor = chunk.tailCursor
            // A poll that found nothing new must not write anything back. The
            // write is what redraws the transcript, and most polls of a
            // running turn arrive between records rather than on one.
            if !reset, chunk.events.isEmpty, chunk.nextOffset == offset {
                await loadResponseAttachments(id: id, generation: generation)
                return true
            }
            if reset {
                eventsEpoch &+= 1
                events = chunk.events
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
                events.append(contentsOf: chunk.events)
            }
            reconcileOutgoing()
            offset = chunk.nextOffset
            settleNotifications()
            await loadResponseAttachments(id: id, generation: generation)
            return true
        } catch {
            // Background polls must not pop an error banner on an idle
            // screen; user-initiated loads still surface.
            if !quiet, selectionMatches(id: id, generation: generation) {
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
        guard let reference = currentReference, reference.itemID == id else { return }
        let title = title ?? "Conversation"
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
        applySavedCopy(copy)
    }

    private func applySavedCopy(_ copy: CachedRecordPayload) {
        contextRevision = copy.sendRevision
        eventsEpoch &+= 1
        events = copy.page.events
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
            Task { await loadResponseAttachments(id: id, generation: generation) }
        }
    }

    /// Ask the machine again from the saved-copy banner. A live answer
    /// replaces the copy; another failure keeps it, with its saved time.
    func checkSavedCopyForUpdates(prepareConnection: (() async throws -> Void)? = nil, quiet: Bool = false) async {
        guard savedCopy != nil, !checkingSavedCopy, let chat = selected,
              let workspaceID, let reference = currentReference else { return }
        guard reference.scope == WorkSessionContext.shared.scope else {
            error = "Verify your account before returning to the live conversation. Your draft stays on this device."
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
                    error = "Allow workspace access on the other computer before returning to the live conversation. Your draft stays on this device."
                    return
                }
                let version = try await Bridge.peerProtocolVersion(targetPeer)
                guard stillCurrent() else { return }
                guard version >= RemoteHostFeature.chat.minimumProtocol else {
                    error = "Update tokenstat on the other computer before checking for live messages. You can still read this saved copy."
                    return
                }
            }
            let liveChats = try await Bridge.chats(workspaceID: workspaceID, peer: targetPeer)
            guard stillCurrent() else { return }
            guard let live = liveChats.first(where: { $0.id == chat.id && $0.workspaceID == workspaceID }) else {
                error = "This conversation is no longer on the machine. You can still read this saved copy."
                return
            }
            replace(live)
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

    private func loadResponseAttachments(id: String, generation: UInt64) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
        let descriptors = events.compactMap { timeline -> ChatAttachment? in
            guard let event = timeline.event,
                  event.kind == "attachment",
                  let attachmentID = event.id,
                  !attemptedResponseAttachments.contains(attachmentID)
            else { return nil }
            return ChatAttachment(
                id: attachmentID,
                name: event.name ?? "Attachment",
                mediaType: event.mediaType,
                size: event.size
            )
        }
        // Keep background downloads bounded instead of fetching a whole page
        // of files concurrently. Navigation stops the remaining queue.
        for descriptor in descriptors {
            guard selectionMatches(id: id, generation: generation) else { return }
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
            }
        }
        if let saved = await WorkSavedPreview.read(reference: previewReference, attachment: attachment.id) {
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentData[attachment.id] = saved
            return
        }
        guard savedCopy == nil, selectionMatches(id: id, generation: generation),
              memoryGeneration == attachmentCacheGeneration else { return }
        let cacheEpoch = await ChatAttachmentCache.shared.epoch()
        guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
        if let cached = await ChatAttachmentCache.shared.read(reference: previewReference, attachment: attachment.id) {
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
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
            guard selectionMatches(id: id, generation: generation), currentReference == previewReference,
                  WorkCacheAccess.canSave(previewReference), memoryGeneration == attachmentCacheGeneration else { return }
            guard await ChatAttachmentCache.shared.write(data, reference: previewReference, attachment: attachment.id, epoch: cacheEpoch) else { return }
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            responseAttachmentData[attachment.id] = data
            if currentReference == previewReference, WorkCacheAccess.canSave(previewReference) {
                await WorkSavedPreview.save(reference: previewReference, attachment: attachment, data: data)
            }
        } catch {
            guard selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
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
            return "Relay allowance reached. A direct connection can still transfer this file."
        }
        if reason.localizedCaseInsensitiveContains("too large") {
            return "This file is too large to transfer. Open it on the computer that made it."
        }
        if reason.localizedCaseInsensitiveContains("no longer available") {
            return "This file is no longer on the computer that made it."
        }
        return "Download failed. Tap to retry."
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

    private func loadApprovals(id: String, generation: UInt64, quiet: Bool = false) async {
        guard !Task.isCancelled, savedCopy == nil,
              selectionMatches(id: id, generation: generation) else { return }
        do {
            let loaded = try await Bridge.chatApprovals(id: id, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            // Unchanged approvals must not write back: the write redraws the
            // transcript, and this runs on every poll of a running turn.
            if approvals != loaded { approvals = loaded }
            approvalsLoaded = true
            settleNotifications()
        } catch {
            // A background poll must not pop an alert over an idle screen;
            // the rows keep the answers they already had.
            if !quiet, selectionMatches(id: id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    private func selectionMatches(id: String, generation: UInt64) -> Bool {
        selectionGeneration == generation && selected?.id == id
            && continuityScope == WorkSessionContext.shared.readingScope
    }

    private func replace(_ chat: ChatConversation) {
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
        catch { self.error = "Saved pending messages could not be opened. They have not been discarded. Try again after unlocking this device." }
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

struct ChatToolState: Equatable {
    var callId: String
    var verb: String
    var target: String
    var running: Bool
    var failed: Bool
    var detail: String?
    var startedAtMs: Int64
    var endedAtMs: Int64?
    /// Display lines, split once at construction. `snippet` used to split
    /// the whole detail on every read, and a row reads it half a dozen
    /// times per draw: Codex shell outputs reach megabytes, so one live
    /// row cost several full multi-megabyte splits per poll.
    var snippet: [String]

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    static func isFileEditVerb(_ verb: String) -> Bool {
        verb == "Edit" || verb == "NotebookEdit"
    }

    /// Display lines for one detail string, split once. See `snippet`.
    static func makeSnippet(verb: String, detail: String?) -> [String] {
        guard let detail, !detail.isEmpty else { return [] }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // An edit's red/green lines must reach the row unprefixed: a blanket
        // "| " is what made every Tool row read as grey output and broke the
        // Show edit label. This covers both the old/new rendering ("- old")
        // and unified patches ("-hello", "@@" hunks stay grey). Other verbs
        // keep the output marker on every line, so a shell trace like
        // "+ set -x" never poses as a diff.
        // Codex often exposes a unified patch through a command_execution
        // item. Treat Diff like a native edit so +/- lines remain visible and
        // receive the same semantic coloring as Edit/NotebookEdit cards.
        let diffVerbs = ["Edit", "NotebookEdit", "Diff"]
        let isDiff = diffVerbs.contains(verb)
        var out = lines.prefix(Self.snippetLineCap).map { line in
            let shown = Self.clip(line)
            if isDiff, Self.isDiffLine(shown) {
                return shown
            }
            return "| \(shown)"
        }
        if lines.count > Self.snippetLineCap {
            out.append("| … (\(lines.count - Self.snippetLineCap) more)")
        }
        return Array(out)
    }

    /// A unified or old/new diff body line. File headers ("--- a/…",
    /// "+++ b/…") are not changes and stay grey.
    static func isDiffLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        guard first == "+" || first == "-" else { return false }
        return !(line.hasPrefix("+++ ") || line.hasPrefix("--- "))
    }

    /// Cut one line down to what a row can draw.
    ///
    /// The line cap alone bounds the wrong half. A line is whatever sits
    /// between two newlines, and a tool that answers in JSON answers in one
    /// line however many kilobytes it is: a web search result arrives as a
    /// single forty-kilobyte string. Handing that to one `Text` in a stack
    /// that grows to fit means laying out forty thousand characters, with
    /// wrapping, on every measuring pass the lazy stack makes.
    ///
    /// That is the hang. It is per row and not per transcript, which is why
    /// it survived every bound put on the number of rows: thirty-seven rows
    /// took a second and a half, and a dozen took a third of one.
    ///
    /// The full text stays in `detail`, so copy still yields everything.
    static func clip(_ line: String) -> String {
        guard line.count > Self.snippetColumnCap else { return line }
        return String(line.prefix(Self.snippetColumnCap)) + "…"
    }

    /// A 500-line stdout must not become 500 rows. The full text stays in
    /// `detail` for copy; the row only ever draws this many.
    private static let snippetLineCap = 60
    /// And how much of one line is drawn.
    ///
    /// Roughly four wrapped lines of the row's monospace face in a full-width
    /// reading lane, so ordinary output, long shell commands and minified
    /// source all still read as themselves. What it stops is the single line
    /// that is really a document.
    private static let snippetColumnCap = 600
}

/// A file the agent changed. One card, not a tool row plus a second copy.
struct ChatEditState: Equatable {
    var path: String
    var added: UInt32
    var removed: UInt32
    var patch: String
    /// 1-based count of this path since the last user message. 2 means this
    /// file was already edited earlier in the same turn.
    var revision: Int
    var running: Bool
    var failed: Bool
    var startedAtMs: Int64
    var endedAtMs: Int64?

    var duration: String? {
        ChatClock.duration(from: startedAtMs, to: endedAtMs)
    }

    var fileName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Last two folders of the parent path, enough to tell two same-named
    /// files apart without drawing the whole absolute path as the title.
    var location: String {
        let folder = (path as NSString).deletingLastPathComponent
        let last = (folder as NSString).lastPathComponent
        let grand = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if last.isEmpty || last == "/" { return "" }
        if grand.isEmpty || grand == "/" { return last }
        return "\(grand)/\(last)"
    }

    /// Nil on the first change of a file in a turn. Later ones name themselves.
    var changeLabel: String? {
        guard revision >= 2 else { return nil }
        return "\(ChatClock.ordinal(revision)) change"
    }

    mutating func applyPatch(added: UInt32, removed: UInt32, patch: String) {
        if added > 0 { self.added = added }
        if removed > 0 { self.removed = removed }
        if !patch.isEmpty { self.patch = patch }
        recountIfNeeded()
    }

    mutating func applyDetail(_ detail: String?) {
        guard patch.isEmpty, let detail, !detail.isEmpty else { return }
        patch = detail
        recountIfNeeded()
    }

    mutating func recountIfNeeded() {
        guard added == 0, removed == 0, !patch.isEmpty else { return }
        var plus: UInt32 = 0
        var minus: UInt32 = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let shown = String(line)
            guard ChatToolState.isDiffLine(shown), let first = shown.first else { continue }
            if first == "+" { plus += 1 }
            if first == "-" { minus += 1 }
        }
        added = plus
        removed = minus
    }
}

enum ChatClock {
    static func duration(from startedAtMs: Int64, to endedAtMs: Int64?) -> String? {
        guard let endedAtMs else { return nil }
        let (elapsed, overflow) = endedAtMs.subtractingReportingOverflow(startedAtMs)
        guard !overflow else { return nil }
        let ms = max(0, elapsed)
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
    }

    static func ordinal(_ value: Int) -> String {
        let mod100 = value % 100
        let mod10 = value % 10
        if (11...13).contains(mod100) { return "\(value)th" }
        switch mod10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}

/// A message waiting for the current turn to finish.
/// Equatable so a transcript can skip the rows that did not move. A chat
/// redraws whenever anything about it changes, and without this every visible
/// row rebuilds itself because one of them grew by a word.
struct ChatDisplayItem: Identifiable, Equatable {
    let id: String
    let kind: Kind
    /// Inclusive end of a coalesced text/thinking block in the loaded archive.
    /// Lets a mark from a partial page resolve after earlier deltas arrive.
    var lastSequence: UInt64? = nil

    enum Kind: Equatable {
        case user(String)
        case assistant(String, backend: String?)
        case turnSeparator(String)
        /// A conversation changing hands, with the summary the incoming agent
        /// was given so the person can read exactly what it was told.
        case handoff(to: String, brief: String)
        case thinking(String)
        case tool(ChatToolState)
        case edit(ChatEditState)
        case attachment(ChatAttachment)
        case approval(ChatApproval)
        case usage(input: UInt64, output: UInt64, cost: Double?)
        case failed(String)
    }

    /// A name for a row that survives an older page arriving in front of it.
    ///
    /// The record's place in the archive when the host reports one, which is
    /// fixed for the life of that record. Without it the row is named by its
    /// position in the list, which is what it always was, and what makes a
    /// prepend re-identify every row below it.
    private static func stamp(_ event: ChatTimelineEvent, _ position: Int) -> String {
        if let seq = event.seq { return "s\(seq)" }
        return "\(event.atMs ?? 0)-\(position)"
    }

    static func coalesce(_ events: [ChatTimelineEvent], defaultBackend: String? = nil, running: Bool = true) -> [ChatDisplayItem] {
        var items: [ChatDisplayItem] = []
        // Every row a call id has started, oldest first. A call id is not
        // unique on every backend (Antigravity sends `call_id: "tool"` for
        // all of them), so an End has to close the oldest row still running
        // under that name rather than keep overwriting the newest start.
        var toolIndexes: [String: [Int]] = [:]
        // How many times each call id has already started a tool in this
        // conversation. An agent is supposed to name every call something of
        // its own, and most do, but Antigravity sends `call_id: "tool"` for
        // all of them.
        var toolStarts: [String: Int] = [:]
        // Same duplicate-id hazard as tools, for edits that carry a reused
        // call id (or none and the same path twice). Row ids feed ForEach.
        var editStarts: [String: Int] = [:]
        var approvalIndex: [String: Int] = [:]
        var text = ""
        var textID = ""
        var textBackend: String?
        var textLastSequence: UInt64?
        var thinkingLastSequence: UInt64?
        var thinking = ""
        var thinkingID = ""
        var lastBackend: String?
        var editRevisions: [String: Int] = [:]

        func flushText() {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(
                    ChatDisplayItem(
                        id: textID,
                        kind: .assistant(body, backend: textBackend ?? defaultBackend),
                        lastSequence: textLastSequence
                    )
                )
            }
            text = ""
            textID = ""
            textBackend = nil
            textLastSequence = nil
        }

        func flushThinking() {
            let body = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                items.append(ChatDisplayItem(id: thinkingID, kind: .thinking(body), lastSequence: thinkingLastSequence))
            }
            thinking = ""
            thinkingID = ""
            thinkingLastSequence = nil
        }

        func closeRunningTools(failed: Bool, at: Int64?, detail: String?) {
            for index in items.indices {
                switch items[index].kind {
                case .tool(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    if state.detail == nil {
                        state.detail = detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: detail)
                    }
                    state.endedAtMs = at
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                case .edit(var state) where state.running:
                    state.running = false
                    state.failed = failed
                    state.endedAtMs = at
                    state.applyDetail(detail)
                    items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                default:
                    continue
                }
            }
        }

        func nextEditRevision(_ path: String) -> Int {
            let key = path
            let n = (editRevisions[key] ?? 0) + 1
            editRevisions[key] = n
            return n
        }

        func matchingEditIndex(callId: String, path: String) -> Int? {
            if !callId.isEmpty, let indexes = toolIndexes[callId] {
                for index in indexes.reversed() where items.indices.contains(index) {
                    switch items[index].kind {
                    case let .edit(state) where path.isEmpty || state.path == path || state.path == "File":
                        return index
                    case let .tool(state)
                        where ChatToolState.isFileEditVerb(state.verb)
                            && (path.isEmpty || state.target == path || state.target.isEmpty):
                        return index
                    default:
                        continue
                    }
                }
            }
            for index in items.indices.reversed() {
                switch items[index].kind {
                case let .edit(state) where state.running && (path.isEmpty || state.path == path):
                    return index
                case let .tool(state)
                    where state.running
                        && ChatToolState.isFileEditVerb(state.verb)
                        && (path.isEmpty || state.target == path):
                    return index
                default:
                    continue
                }
            }
            return nil
        }

        /// Remember a row as the newest one this call id names. An id that
        /// already named the row is moved to the back rather than repeated.
        func noteToolIndex(_ index: Int, callId: String) {
            guard !callId.isEmpty else { return }
            var indexes = toolIndexes[callId] ?? []
            indexes.removeAll { $0 == index }
            indexes.append(index)
            toolIndexes[callId] = indexes
        }

        /// The row an End closes: the oldest one still running under this
        /// call id, or, for a repeat End with nothing left running, the
        /// newest row the id named.
        func toolEndIndex(callId: String) -> Int? {
            guard !callId.isEmpty, let indexes = toolIndexes[callId] else { return nil }
            let running = indexes.first { index in
                guard items.indices.contains(index) else { return false }
                switch items[index].kind {
                case let .tool(state): return state.running
                case let .edit(state): return state.running
                default: return false
                }
            }
            return running ?? indexes.last { items.indices.contains($0) }
        }

        for event in events {
            if event.kind == "user" {
                flushText()
                flushThinking()
                // A new user turn bounds any tools left open by an interrupted
                // older turn, including histories recorded by older hosts.
                closeRunningTools(failed: false, at: event.atMs, detail: "Interrupted")
                editRevisions = [:]
                items.append(
                    ChatDisplayItem(
                        id: "user-\(stamp(event, items.count))",
                        kind: .user(event.text ?? "")
                    )
                )
                continue
            }
            if event.kind == "handoff" {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "handoff-\(stamp(event, items.count))",
                        kind: .handoff(to: event.to ?? "", brief: event.brief ?? "")
                    )
                )
                // The separator would say the same thing twice, less well.
                lastBackend = event.to ?? lastBackend
                continue
            }
            if let approval = event.approval {
                flushText()
                flushThinking()
                // The timeline records an approval twice: once when the agent
                // paused, and again with the answer. Keep the row in the place
                // it happened and let the later state win, so a conversation
                // reopened tomorrow shows the outcome rather than a question
                // that looks like it is still waiting.
                let rowID = "approval-\(approval.id)"
                if let at = approvalIndex[rowID] {
                    items[at] = ChatDisplayItem(id: rowID, kind: .approval(approval))
                } else {
                    approvalIndex[rowID] = items.count
                    items.append(ChatDisplayItem(id: rowID, kind: .approval(approval)))
                }
                continue
            }
            guard let agent = event.event else { continue }
            let eventBackend = event.backend ?? defaultBackend
            if let eventBackend, let lastBackend, eventBackend != lastBackend {
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "turn-\(stamp(event, items.count))",
                        kind: .turnSeparator(eventBackend)
                    )
                )
            }
            if let eventBackend { lastBackend = eventBackend }
            switch agent.kind {
            case "text":
                flushThinking()
                if text.isEmpty {
                    textID = "text-\(stamp(event, items.count))"
                    textBackend = event.backend ?? defaultBackend
                }
                text += agent.delta ?? ""
                textLastSequence = event.seq
            case "thinking":
                flushText()
                if thinking.isEmpty { thinkingID = "think-\(stamp(event, items.count))" }
                thinking += agent.delta ?? ""
                thinkingLastSequence = event.seq
            case "toolStart":
                flushText()
                flushThinking()
                let callId = agent.callId ?? "tool-\(stamp(event, items.count))"
                // Archive positions keep a tool's row stable when older
                // pages bring another use of the same call ID. Legacy hosts
                // without positions keep the occurrence-based fallback.
                let occurrence = (toolStarts[callId] ?? 0) + 1
                toolStarts[callId] = occurrence
                let rowID = event.seq != nil ? "tool-\(stamp(event, items.count))"
                    : (occurrence == 1 ? "tool-\(callId)" : "tool-\(callId)#\(occurrence)")
                let verb = agent.verb ?? "Tool"
                let target = ChatToolState.clip(agent.target ?? "")
                noteToolIndex(items.count, callId: callId)
                if ChatToolState.isFileEditVerb(verb) {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .edit(
                                ChatEditState(
                                    path: target.isEmpty ? "File" : target,
                                    added: 0,
                                    removed: 0,
                                    patch: "",
                                    revision: nextEditRevision(target.isEmpty ? "File" : target),
                                    running: true,
                                    failed: false,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil
                                )
                            )
                        )
                    )
                } else {
                    items.append(
                        ChatDisplayItem(
                            id: rowID,
                            kind: .tool(
                                ChatToolState(
                                    callId: callId,
                                    verb: verb,
                                    // Same reason as the snippet: a shell "target"
                                    // is the whole command, and a heredoc makes
                                    // that a document. `lineLimit` bounds what
                                    // is drawn, not what is measured.
                                    target: target,
                                    running: true,
                                    failed: false,
                                    detail: nil,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: nil,
                                    snippet: []
                                )
                            )
                        )
                    )
                }
            case "toolEnd":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                if let index = toolEndIndex(callId: callId) {
                    switch items[index].kind {
                    case .tool(var state):
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.detail = agent.detail
                        state.snippet = ChatToolState.makeSnippet(verb: state.verb, detail: agent.detail)
                        state.endedAtMs = event.atMs
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .tool(state))
                    case .edit(var state):
                        state.running = false
                        state.failed = !(agent.ok ?? true)
                        state.endedAtMs = event.atMs
                        state.applyDetail(agent.detail)
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                } else if ChatToolState.isFileEditVerb(agent.verb ?? "") {
                    let path = {
                        let clipped = ChatToolState.clip(agent.target ?? "")
                        return clipped.isEmpty ? "File" : clipped
                    }()
                    var state = ChatEditState(
                        path: path,
                        added: 0,
                        removed: 0,
                        patch: "",
                        revision: nextEditRevision(path),
                        running: false,
                        failed: !(agent.ok ?? true),
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: event.atMs
                    )
                    state.applyDetail(agent.detail)
                    items.append(
                        ChatDisplayItem(
                            id: "edit-\(event.seq != nil || callId.isEmpty ? stamp(event, items.count) : callId)",
                            kind: .edit(state)
                        )
                    )
                } else {
                    let fallback = callId.isEmpty ? "end-\(stamp(event, items.count))" : callId
                    let fallbackVerb = agent.verb ?? "Tool"
                    items.append(
                        ChatDisplayItem(
                            id: "tool-\(event.seq != nil ? stamp(event, items.count) : fallback)",
                            kind: .tool(
                                ChatToolState(
                                    callId: fallback,
                                    verb: fallbackVerb,
                                    target: ChatToolState.clip(agent.target ?? ""),
                                    running: false,
                                    failed: !(agent.ok ?? true),
                                    detail: agent.detail,
                                    startedAtMs: event.atMs ?? 0,
                                    endedAtMs: event.atMs,
                                    snippet: ChatToolState.makeSnippet(verb: fallbackVerb, detail: agent.detail)
                                )
                            )
                        )
                    )
                }
            case "edit":
                flushText()
                flushThinking()
                let callId = agent.callId ?? ""
                let path = agent.path ?? "File"
                let added = agent.added ?? 0
                let removed = agent.removed ?? 0
                let patch = agent.patch ?? ""
                if let index = matchingEditIndex(callId: callId, path: path) {
                    switch items[index].kind {
                    case .edit(var state):
                        state.applyPatch(added: added, removed: removed, patch: patch)
                        if state.path == "File", !path.isEmpty { state.path = path }
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    case .tool(let toolState):
                        var state = ChatEditState(
                            path: path,
                            added: added,
                            removed: removed,
                            patch: patch,
                            revision: nextEditRevision(path),
                            running: toolState.running,
                            failed: false,
                            startedAtMs: toolState.startedAtMs,
                            endedAtMs: toolState.running ? nil : (event.atMs ?? toolState.endedAtMs)
                        )
                        state.recountIfNeeded()
                        items[index] = ChatDisplayItem(id: items[index].id, kind: .edit(state))
                    default:
                        break
                    }
                    if !callId.isEmpty { noteToolIndex(index, callId: callId) }
                } else {
                    var state = ChatEditState(
                        path: path,
                        added: added,
                        removed: removed,
                        patch: patch,
                        revision: nextEditRevision(path),
                        running: false,
                        failed: false,
                        startedAtMs: event.atMs ?? 0,
                        endedAtMs: nil
                    )
                    state.recountIfNeeded()
                    let rowID: String = {
                        if event.seq != nil || callId.isEmpty { return "edit-\(stamp(event, items.count))" }
                        let occurrence = (editStarts[callId] ?? 0) + 1
                        editStarts[callId] = occurrence
                        return occurrence == 1 ? "edit-\(callId)" : "edit-\(callId)#\(occurrence)"
                    }()
                    if !callId.isEmpty { noteToolIndex(items.count, callId: callId) }
                    items.append(ChatDisplayItem(id: rowID, kind: .edit(state)))
                }
            case "attachment":
                flushText()
                flushThinking()
                guard let id = agent.id else { continue }
                items.append(
                    ChatDisplayItem(
                        id: "attachment-\(id)",
                        kind: .attachment(
                            ChatAttachment(
                                id: id,
                                name: agent.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment",
                                mediaType: agent.mediaType,
                                size: agent.size
                            )
                        )
                    )
                )
            case "usage":
                flushText()
                flushThinking()
                items.append(
                    ChatDisplayItem(
                        id: "usage-\(stamp(event, items.count))",
                        kind: .usage(
                            input: agent.input ?? 0,
                            output: agent.output ?? 0,
                            cost: agent.costUsd
                        )
                    )
                )
            case "failed":
                flushText()
                flushThinking()
                closeRunningTools(failed: true, at: event.atMs, detail: agent.text)
                items.append(
                    ChatDisplayItem(
                        id: "failed-\(stamp(event, items.count))",
                        kind: .failed(agent.text ?? "The turn failed")
                    )
                )
            case "done":
                flushText()
                flushThinking()
                let status = agent.status ?? ""
                // Only the host's process outcome can fail a turn. Older hosts
                // may still carry a backend-level "cancelled" marker from
                // grok; that describes its tool stream, not the person
                // pressing Stop and not a failed process.
                let failed = status == "error"
                closeRunningTools(failed: failed, at: event.atMs, detail: failed ? status : nil)
            default:
                continue
            }
        }
        flushText()
        flushThinking()
        // Tool logs are history; only the host knows whether a process lives.
        if !running {
            closeRunningTools(failed: false, at: nil, detail: "Ended without a tool result")
        }
        for (callId, indexes) in toolIndexes {
            let live = Set(indexes.filter { items.indices.contains($0) })
            if live.isEmpty { toolIndexes.removeValue(forKey: callId) }
            else { toolIndexes[callId] = live.sorted() }
        }
        return items
    }
}

enum ChatGateCopy {
    static func chip(_ tier: String?) -> String {
        switch tier {
        case "full": return "Approvals"
        case "rules": return "Rules"
        case "bypassOnly": return "Bypass only"
        default: return "Checking"
        }
    }

    static func explanation(_ tier: String?, bypass: Bool) -> String {
        if bypass {
            return "This agent can use its backend's bypass mode in this folder."
        }
        switch tier {
        case "full":
            return "tokenstat asks before every tool action, and the agent waits for your answer."
        case "rules":
            return "Saved permission rules run. Anything else is denied."
        case "bypassOnly":
            return "This backend has no tokenstat approval gate, so this chat can only run without asking."
        default:
            return "Checking this backend's permission support."
        }
    }
}
