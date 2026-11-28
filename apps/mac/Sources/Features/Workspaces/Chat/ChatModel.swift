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
        var personaID: String?
    }

    private static let launchChoiceKey = "chat.lastLaunchChoice.v1"
    var newChatChoice: ChatStartDraft.AgentChoice?
    weak var landingDraft: ChatStartDraft?
    var landingCanSubmit = false
    var landingBlockReason: String?

    private let profileCatalog = AgentProfileCatalog.shared
    private var profileSignIn: [String: [String: AgentSetupStatus]] = [:]

    private var remoteProfileCatalog: (peer: String, profiles: AgentProfiles)?
    var agentProfiles: AgentProfiles? {
        guard let peer else { return profileCatalog.value }
        return remoteProfileCatalog?.peer == peer ? remoteProfileCatalog?.profiles : nil
    }

    func refreshAgentProfiles() async {
        guard let peer else { try? await profileCatalog.refresh(); return }
        let scope = WorkSessionContext.shared.generation
        guard await RemoteHostFeature.agentProfiles.isSupported(peer: peer),
              let profiles = try? await Bridge.agentProfiles(peer: peer),
              !Task.isCancelled, self.peer == peer, WorkSessionContext.shared.generation == scope else { return }
        remoteProfileCatalog = (peer, profiles)
        profileCatalog.remember(profiles, peer: peer, account: scope)
    }

    var workspaceProfileLock: String? {
        workspaceID.flatMap { agentProfiles?.workspaceLocks?[WorkDestinationResolver.route(folderID: $0).workspaceID] }
    }

    func setWorkspaceProfileLock(_ profile: String?) async {
        guard peer == nil, let workspaceID else { return }
        do {
            profileCatalog.replace(try await Bridge.setWorkspaceAgentProfile(workspaceID: workspaceID, profileID: profile))
        } catch {
            if self.workspaceID == workspaceID, peer == nil { self.error = error.localizedDescription }
        }
    }

    func profileID(for chat: ChatConversation?) -> String? {
        if landingDraft != nil {
            return workspaceProfileLock ?? chat?.profileId ?? agentProfiles?.default
        }
        return chat?.profileId
    }

    func profileTitle(_ chat: ChatConversation?) -> String? {
        guard let id = profileID(for: chat), id != AgentProfiles.system else { return nil }
        return agentProfiles?.profile(id)?.title
    }

    func usesOwnLogin(_ backend: ChatBackend, chat: ChatConversation?) -> Bool {
        guard let id = profileID(for: chat), id != AgentProfiles.system else { return false }
        guard let profile = agentProfiles?.profile(id) else { return true }
        return backend.launcherID.map(profile.own.contains) ?? false
    }

    func limitsProfileID(for chat: ChatConversation) -> String? {
        guard let backend = backend(for: chat.backend) else { return profileID(for: chat) }
        guard usesOwnLogin(backend, chat: chat) else { return nil }
        return profileID(for: chat)
    }

    func signInReadiness(for backend: ChatBackend, chat: ChatConversation? = nil) -> String? {
        let chat = chat ?? selected
        if peer != nil && usesOwnLogin(backend, chat: chat) { return nil }
        guard usesOwnLogin(backend, chat: chat), let id = profileID(for: chat) else { return backend.readiness }
        return profileSignIn[id]?[backend.id]?.readiness
    }

    func configureLanding(_ state: ChatStartDraft, backends: [ChatBackend], peer: String?) {
        landingDraft = state
        self.backends = backends
        self.peer = peer
        folderID = state.repositoryID
        workspaceID = state.repositoryID
        continuityScope = state.owner?.scope
        let reference = state.attachmentReference ?? WorkReference(scope: state.owner?.scope ?? .local(installationID: "unbound"),
            hostIdentity: "new-chat-local", workspaceID: "unbound", kind: .conversation, itemID: "unbound")
        var chat = ChatConversation(saved: reference, title: "", backend: state.agent?.backend)
        chat.model = state.agent?.model; chat.effort = state.agent?.effort
        chat.mode = state.agent?.mode ?? "execute"; chat.autonomy = state.agent?.autonomy ?? Self.newChatInitialAutonomy
        chat.fastMode = state.agent?.fastMode ?? false
        chat.profileId = state.agent?.profileID
        chat.id += reference.anchor ?? ""
        if selected?.id != chat.id { loadGeneration &+= 1 }
        selected = chat
        draft = state.text
        attachments = state.attachments; attachmentPreviews = state.previews
        stagingAttachments = state.stagingAttachments
    }

    private func updateLanding(backend: String?, model: String?, effort: String?, fastMode: Bool?, mode: String?, autonomy: String?, profileID: String?) {
        guard let state = landingDraft, !state.isSubmitting, let owner = state.owner,
              owner.scope == WorkSessionContext.shared.scope, owner.session == WorkSessionContext.shared.generation else { return }
        var choice = state.agent ?? .init(backend: backend ?? "", model: nil, effort: nil)
        if let backend, backend != choice.backend { choice.backend = backend; choice.model = nil; choice.effort = nil; choice.fastMode = false }
        if let profileID { choice.profileID = profileID }
        if let model { choice.model = model.isEmpty ? nil : model }
        if let effort { choice.effort = effort.isEmpty ? nil : effort }
        if let fastMode { choice.fastMode = fastMode }
        if let mode { choice.mode = mode }
        if let autonomy { choice.autonomy = autonomy }
        if let descriptor = self.backend(for: choice.backend) {
            if descriptor.gateTier == "bypassOnly" { choice.autonomy = "bypass" }
            if !ChatFastMode.available(model: choice.model, models: descriptor.fastModeModels, backend: choice.backend) { choice.fastMode = false }
        }
        state.agent = choice
        configureLanding(state, backends: backends, peer: peer)
    }

    private func stageLandingAttachment(_ item: ChatInboxItem, reference: WorkReference, state: ChatStartDraft) async {
        defer { if let file = item.file { try? FileManager.default.removeItem(at: file) } }
        guard let owner = state.owner, owner.scope == WorkSessionContext.shared.scope,
              owner.session == WorkSessionContext.shared.generation, state.beginImport(reference) else { return }
        stagingAttachments = state.stagingAttachments
        var staged: ChatAttachment?
        var preview: Data?
        defer {
            state.finishImport(reference, attachment: staged, preview: preview)
            if landingDraft === state, currentReference == reference {
                attachments = state.attachments; attachmentPreviews = state.previews
                stagingAttachments = state.stagingAttachments
            }
        }
        if let failure = item.importFailure { state.error = failure; return }
        do {
            if let file = item.file { staged = try await ChatLocalAttachmentStore.shared.stage(file: file, name: item.name, mediaType: item.mediaType, reference: reference) }
            else { staged = try await ChatLocalAttachmentStore.shared.stage(data: item.data, name: item.name, mediaType: item.mediaType, reference: reference) }
            if let staged { preview = try? await Self.draftPreview(staged, reference: reference) }
        } catch { if state.attachmentReference == reference { state.error = error.localizedDescription } }
    }

    func installLandingDraft(_ submission: ChatStartDraft.Submission, permits: () -> Bool) async -> Bool {
        guard permits(), let reference = currentReference, reference.scope == submission.owner.scope else { return false }
        draft = submission.text
        saveDraftNow()
        for file in submission.attachments {
            guard permits(), currentReference == reference else { return false }
            do {
                let original = try await ChatLocalAttachmentStore.shared.exportURL(file, reference: submission.attachmentReference)
                defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
                guard permits(), currentReference == reference else { return false }
                let before = attachments.count
                await attach(ChatInboxItem(data: Data(), name: file.name, mediaType: file.mediaType, file: original), to: reference)
                guard attachments.count == before + 1 else { return false }
            } catch { self.error = error.localizedDescription; return false }
        }
        return permits() && currentReference == reference
    }

    static func newChatDefaults(backends: [ChatBackend]) -> ChatStartDraft.AgentChoice? {
        let saved = UserDefaults.standard.data(forKey: launchChoiceKey)
            .flatMap { try? JSONDecoder().decode(LaunchChoice.self, from: $0) }
        let available = backends.filter { $0.installed != false && $0.id != "sh" }
        guard let chosen = available.first(where: { $0.id == saved?.backend })
            ?? available.first(where: { $0.id == "codex" }) ?? available.first else { return nil }
        return .init(backend: chosen.id,
                     model: chosen.models.contains(saved?.model ?? "") ? saved?.model : nil,
                     effort: chosen.efforts.contains(saved?.effort ?? "") ? saved?.effort : nil,
                     autonomy: "bypass")
    }

    static let newChatInitialAutonomy = "bypass"
    var chats: [ChatConversation] = [] {
        didSet { noteRunningChats() }
    }
    private var runningSince: [String: Date] = [:]
    func turnStartedAt(for conversationID: String) -> Date? {
        runningSince[conversationID]
    }
    var selected: ChatConversation? {
        didSet {
            noteRunningChats()
            if selected?.teamShare != nil { authorizedQueueItems.removeAll(); sharingRecoveryNotice = nil }
            if oldValue?.backend != selected?.backend || oldValue?.running != selected?.running {
                refreshDisplayMetadata()
            }
        }
    }
    var isSharedSource: Bool { selected?.teamShare != nil }
    private(set) var sharingRecoveryNotice: String?

    private(set) var events: [ChatTimelineEvent] = [] {
        didSet {
            eventsRevision &+= 1
            if !events.isEmpty, holdsPreviewOffline { holdsPreviewOffline = false }
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
    private(set) var outgoing: [ChatDisplayItem] = [] {
        didSet { outgoingRevision &+= 1 }
    }
    var approvals: [ChatApproval] = []
    private(set) var approvalsLoaded = false
    var instructions: ChatInstructions?
    private(set) var instructionsLoaded = false
    var offset: UInt64 = 0
    @ObservationIgnored private var tailCursor: String?
    private(set) var earlierCursor: String?
    private(set) var hasEarlier = false
    private(set) var loadingEarlier = false
    private var earlierInFlight = false
    @ObservationIgnored private var hasPagedBack = false
    private(set) var reachedStart = false
    private(set) var historyTrimmed = false
    private(set) var conversationUsage: ChatUsageTotals?
    private var usageThrough: UInt64?
    private var pagingUnavailable = false
    var attachments: [ChatAttachment] = []
    var attachmentPreviews: [String: Data] = [:]
    private(set) var stagingAttachments = 0
    private(set) var missingDraftAttachments: Set<String> = []
    private var draftAttachmentLoadGeneration = UUID()
    /// Agent-returned file bytes, loaded lazily from the chat's owning host.
    /// The transcript only persists descriptors, so remote files work exactly
    /// like local ones without exposing a host filesystem path to SwiftUI.
    var responseAttachmentData: [String: Data] = [:]
    var responseAttachmentFiles: [String: URL] = [:]
    var fileRelayName: String?
    var fileRelayRemaining: UInt64?
    var fileRelaySize: UInt64?
    var fileRelayPresenter: UUID?
    @ObservationIgnored var fileRelayAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored var fileRelayTicket: UUID?
    var fileTransferName: String?
    var fileTransferProgress: Double = 0
    var fileTransferCancelled = false
    @ObservationIgnored var fileTransferInFlight = false
    var backends: [ChatBackend] = []
    var backendRefreshError: String?
    private var signInRecovery: ChatAuthenticationFailure.Recovery? {
        guard let selected else { return nil }
        _ = displayRevision
        _ = displayCache
        _ = outgoing
        let key = SignInRecoveryKey(display: displayKey, outgoing: outgoingRevision,
                                    conversation: selected.id, backend: selected.backend)
        if let cached = signInRecoveryCache, cached.key == key { return cached.value }
        let value = ChatAuthenticationFailure.latestRecovery(in: displayItems, backend: selected.backend)
        signInRecoveryCache = (key, value)
        return value
    }
    private struct SignInRecoveryKey: Equatable {
        var display: DisplayKey?
        var outgoing: UInt64
        var conversation: String
        var backend: String
    }
    @ObservationIgnored private var outgoingRevision: UInt64 = 0
    @ObservationIgnored private var signInRecoveryCache: (key: SignInRecoveryKey, value: ChatAuthenticationFailure.Recovery?)?
    var signInQueuedMessage: ChatQueuedMessage? {
        guard savedCopy == nil, let selected,
              let item = queued.first(where: { $0.signInBackend == selected.backend && $0.delivery == .waiting }),
              ownsQueue else { return nil }
        return item
    }
    var signInGateRowID: String? {
        guard !isSharedSource else { return nil }
        if let item = signInQueuedMessage { return "signin-gate-\(item.id)" }
        return signInRecovery?.failureID
    }
    var signInFailureID: String? {
        guard let selected, let gate = signInGateRowID else { return nil }
        return "\(selected.id):\(gate)"
    }

    func needsSignIn(_ backendID: String) -> Bool {
        if let chat = selected, chat.backend == backendID, let model = chat.model,
           LocalChatModel.parse(model) != nil { return false }
        guard let backend = backend(for: backendID) else { return false }
        if peer != nil && usesOwnLogin(backend, chat: selected) { return false }
        if usesOwnLogin(backend, chat: selected), let id = profileID(for: selected) {
            guard let status = profileSignIn[id]?[backendID], status.checked == true else { return false }
            return status.outcome == .needsSignIn
        }
        return backend.signInVerified && ["needsSignIn", "expired"].contains(backend.readiness ?? "")
    }

    enum SignInHold { case notNeeded, held, refused }

    func holdForSignIn(_ text: String, backend backendID: String) -> SignInHold {
        guard !isSharedSource else { return .refused }
        if busy && selected?.nativeSteer == true && ChatCommandRules.canSteer(text,
            attachments: !attachments.isEmpty, acceptsAttachments: nativeSteerAcceptsAttachments) { return .notNeeded }
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
    var defaultPersonaID: String?
    var isLoading = false
    private(set) var openingConversation = false
    var error: String?
    private(set) var savedCopy: SavedCopyInfo?
    private var savedCopyCheckGeneration: UInt64?
    var checkingSavedCopy: Bool {
        savedCopyCheckGeneration == selectionGeneration
            && continuityScope == WorkSessionContext.shared.scope
    }
    private(set) var folderID: String?
    private(set) var workspaceID: String?
    private(set) var peer: String?
    private var remoteSteer: Bool?

    private func adoptPeer(_ next: String?) {
        if peer != next {
            remoteSteer = nil
            steerProbeStarted = false
            steerProbeTicket = nil
            steerProbeOwner = nil
        }
        peer = next
    }
    private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var setupLoadTask: Task<Void, Never>?
    private(set) var selectionGeneration: UInt64 = 0
    @ObservationIgnored let viewportContinuity = ChatViewportContinuity()
    private var pendingRevealID: String?
    private var pendingRevealFolderID: String?
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

    private func forgetDraft(chatID: String, folderID: String) {
        guard let owner = continuityOwner(folderID: folderID) else { return }
        let reference = WorkReference(scope: owner.scope, hostIdentity: owner.host,
            workspaceID: owner.workspace, kind: .conversation, itemID: chatID)
        if draftReference == reference {
            draftReference = nil
            draftSaveTask?.cancel()
            draftSaveTask = nil
        }
        ChatDraftStore.shared.clear(for: reference)
        ChatReadingStore.shared.forget(for: reference)
    }


    var agentPickerRequest: UInt64 = 0

    var draft = "" {
        didSet {
            guard !restoringDraft, draft != oldValue else { return }
            if let landingDraft { landingDraft.text = draft; return }
            scheduleDraftSave()
        }
    }
    private var draftReference: WorkReference?
    private var draftConversationID: String?
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDraft = false
    private var heldSubmission: ChatDraftSubmission?
    private var contextRevision: UInt64?
    private static let draftSaveDelay = Duration.milliseconds(300)

    var draftSaveFailed: Bool { ChatDraftStore.shared.saveFailed }

    func draftReference(for conversationID: String, in folderID: String) -> WorkReference? {
        guard let owner = continuityOwner(folderID: folderID) else { return nil }
        return WorkReference(scope: owner.scope, hostIdentity: owner.host,
            workspaceID: owner.workspace, kind: .conversation, itemID: conversationID)
    }

    var currentReference: WorkReference? {
        if let landingDraft { return landingDraft.attachmentReference }
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

    func importHandoffDraft(_ shared: WorkSharedDraft, files: [ChatAttachment],
                            replacing expected: WorkSharedDraft, reference: WorkReference) -> Bool {
        guard currentReference == reference, draftReference == reference,
              reference.scope == WorkSessionContext.shared.scope, savedCopy == nil,
              !sending, stagingAttachments == 0, heldSubmission == nil, unconfirmedSend == nil,
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

    @discardableResult
    func restoreSearchReadingPosition(_ reference: WorkReference) -> Bool {
        guard WorkDestinationResolver.sameConversation(reference, currentReference),
              reference.scope == WorkSessionContext.shared.readingScope,
              let anchor = reference.anchor, ChatReadingMark.isStable(eventID: anchor) else { return false }
        ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date(), revealTarget: true), for: reference)
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

    func saveDraftNow() {
        if landingDraft != nil { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        guard let reference = draftReference else { return }
        guard heldSubmission?.owns(reference: draftReference, conversationID: draftConversationID,
                                   peer: peer, scope: continuityScope) != true else { return }
        ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference)
    }

    func retryDraftSave() {
        ChatDraftStore.shared.retryFailedSave()
        saveDraftNow()
    }

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
                    let preview: Data?
                    let available: Bool
                    do {
                        preview = try await Self.draftPreview(attachment, reference: reference)
                        available = true
                    } catch { preview = nil; available = false }
                    guard self.draftAttachmentLoadGeneration == attachmentLoadGeneration,
                          self.draftReference == reference, self.attachments.contains(attachment) else { return }
                    if let preview { self.attachmentPreviews[attachment.id] = preview }
                    else if !available { self.missingDraftAttachments.insert(attachment.id) }
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

    private func setDraft(_ text: String) {
        restoringDraft = true
        draft = text
        restoringDraft = false
    }

    @discardableResult
    func holdDraftForSending(_ text: String) -> Bool {
        guard !isSharedSource, !selectedBackendMissing, savedCopy == nil, let selected, !sending, stagingAttachments == 0, heldSubmission == nil else { return false }
        saveDraftNow()
        let draftID = draftMessageID
        if let pending = queued.first(where: { $0.belongsToDraft(draftID) && $0.needsReceipt }) {
            unconfirmedSend = .init(conversationID: selected.id, messageID: pending.id, checking: false)
            error = L10n.text("apple.chatmodel.check_delivery_before_sending_this_draft_a.7ce8d3db")
            return false
        }
        if let previous = queued.first(where: { $0.belongsToDraft(draftID) }),
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
            messageID: deliveryID(forDraft: draftMessageID, text: text, attachments: attachments) ?? draftMessageID,
            expectedRevision: contextRevision
        )
        composerSendToken = noteSendStarted()
        setDraft("")
        return true
    }

    func clearDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        setDraft("")
        if let reference = draftReference { ChatDraftStore.shared.clear(for: reference) }
    }

    func returnDraft(_ text: String) {
        guard draft.isEmpty else { return }
        setDraft(text)
    }

    private var draftMessageID: String? {
        guard let draftReference else { return nil }
        return ChatDraftStore.shared.draft(for: draftReference)?.messageID
    }

    private func queuedDeliveries(forDraft messageID: String?) -> [ChatQueuedMessage] {
        guard let messageID else { return [] }
        return queued.filter { $0.belongsToDraft(messageID) }
    }

    private func deliveryID(forDraft messageID: String?, text: String,
                            attachments: [ChatAttachment]) -> String? {
        guard let messageID else { return nil }
        let related = queuedDeliveries(forDraft: messageID)
        if let same = related.first(where: { $0.text == text && $0.attachments == attachments }) {
            return same.id
        }
        return related.isEmpty ? messageID : nil
    }


    struct UnconfirmedSend: Equatable, Sendable {
        let conversationID: String
        let messageID: String
        var checking: Bool
    }

    private(set) var unconfirmedSend: UnconfirmedSend?

    func startNewMessage() {
        guard let pending = unconfirmedSend, let reference = currentReference,
              reference.itemID == pending.conversationID, !pending.checking, !sending,
              let original = queued.first(where: { $0.id == pending.messageID && $0.needsReceipt }) else { return }
        if draft == (original.sourceDraftText ?? original.text), attachments == original.attachments {
            clearDraft()
            attachments = []
            attachmentPreviews = [:]
            missingDraftAttachments = []
        } else {
            ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference, newMessage: true)
        }
        unconfirmedSend = nil
        error = L10n.text("common.chat_original_pending")
    }
    private func machineConfirmsSends(peer: String?, checkingReceipt: Bool) async throws -> Bool {
        guard let peer, !peer.isEmpty else { return true }
        let version = try await Bridge.peerProtocolVersion(peer)
        return version >= (checkingReceipt ? 10 : RemoteHostFeature.confirmedSend.minimumProtocol)
    }


    var showingCommandStats = false
    var showingUsageStats = false
    var showingActivity = false
    var activitySection: ChatActivitySection?
    var activityRead: ChatActivityRead?
    var chatCommandSelection = 0
    var chatCommandsDismissed = false

    func handleChatCommandKey(_ code: UInt16) -> Bool {
        let matches = ChatCommandRules.matches(draft)
        guard !chatCommandsDismissed, !matches.isEmpty else { return false }
        if code == 53 { chatCommandsDismissed = true; return true }
        guard code == 125 || code == 126 else { return false }
        chatCommandSelection = (chatCommandSelection + (code == 125 ? 1 : matches.count - 1)) % matches.count
        return true
    }

    var canHandleChatCommandLocally: Bool {
        switch ChatCommandRules.action(draft, backend: selected?.backend, running: busy, attachments: !attachments.isEmpty) {
        case .inspect, .complete, .refused: return true
        case .stop: return savedCopy == nil
        case .message, .compact: return false
        }
    }

    func consumeChatCommand() -> Bool {
        switch ChatCommandRules.action(draft, backend: selected?.backend, running: busy, attachments: !attachments.isEmpty, selection: chatCommandSelection) {
        case .message, .compact: return false
        case .complete(let command): draft = command
        case .inspect:
            let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let section = ChatActivitySection(command: command)
            showingUsageStats = command == "/usage"
            clearDraft()
            if let section { activitySection = section; showingActivity = true }
            else { showingCommandStats = true }
        case .stop:
            guard savedCopy == nil, let reference = currentReference else { return true }
            let generation = selectionGeneration
            clearDraft()
            Task {
                guard currentReference == reference, selectionGeneration == generation else { return }
                await stop()
            }
        case .refused(.attachments): error = L10n.text("common.chat.command.no_attachments")
        case .refused(.arguments): error = L10n.text("common.chat.command.no_arguments")
        case .refused(.unsupported): error = L10n.text("common.chat.command.unsupported")
        case .refused(.running): error = L10n.text("common.chat.command.idle")
        }
        return true
    }

    func sendInitialDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSharedSource, !text.isEmpty || !attachments.isEmpty, let selected, !busy, !sending else { return }
        if consumeChatCommand() { return }
        switch holdForSignIn(text, backend: selected.backend) {
        case .notNeeded: break
        case .held, .refused: return
        }
        guard holdDraftForSending(text) else { return }
        await sendFromComposer()
    }

    @ObservationIgnored private var preparedInitialPresentation: (reference: WorkReference, session: UInt64, epoch: UInt64, consumed: Bool)?

    func prepareInitialPresentation() {
        guard liveWindowLoaded, let reference = currentReference else { return }
        preparedInitialPresentation = (reference, WorkSessionContext.shared.generation, eventsEpoch, false)
        _ = transcriptItems
    }

    func consumePreparedInitialPresentation(workspaceID: String, conversationID: String? = nil) -> Bool {
        guard isReady(for: workspaceID), let preparedInitialPresentation,
              !preparedInitialPresentation.consumed, hasPreparedInitialTranscript,
              conversationID == nil || preparedInitialPresentation.reference.itemID == conversationID else { return false }
        self.preparedInitialPresentation?.consumed = true
        return true
    }

    var hasPreparedInitialTranscript: Bool {
        guard liveWindowLoaded, let preparedInitialPresentation else { return false }
        return preparedInitialPresentation.reference == currentReference
            && preparedInitialPresentation.reference.scope == WorkSessionContext.shared.scope
            && preparedInitialPresentation.session == WorkSessionContext.shared.generation
            && preparedInitialPresentation.epoch == eventsEpoch
    }

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
        guard !isSharedSource else { restoreSubmission(submission); return }
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
                   let pending = queued.first(where: { $0.belongsToDraft(messageID) && $0.needsReceipt }) {
                    unconfirmedSend = .init(conversationID: submission.conversationID, messageID: pending.id, checking: false)
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
        let ownsDraft = item.belongsToDraft(stored?.messageID)
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

    func checkUnconfirmedSend() async {
        guard savedCopy == nil, let pending = unconfirmedSend, !pending.checking,
              let reference = currentReference, reference.itemID == pending.conversationID,
              WorkCacheAccess.canSave(reference) else { return }
        unconfirmedSend?.checking = true
        defer { if unconfirmedSend?.messageID == pending.messageID { unconfirmedSend?.checking = false } }
        do {
            guard let item = try ChatOutboxStore.shared.items(for: reference).first(where: { $0.id == pending.messageID }) else {
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
    @ObservationIgnored private let previewProjector = ChatTranscriptProjector()
    @ObservationIgnored private var warmQueue: [ChatConversation] = []
    @ObservationIgnored private var warmQueueOwner: String?
    @ObservationIgnored private var warmGeneration: UInt64 = 0
    @ObservationIgnored private var previewCacheEpoch: UInt64 = 0
    private(set) var recentMessagePreview: [ChatDisplayItem] = [] {
        didSet { previewRevision &+= 1 }
    }
    /// The last rows seen stay up, read-only, when opening fails with nothing
    /// live or saved to replace them, rather than the chat going blank.
    private(set) var holdsPreviewOffline = false
    @ObservationIgnored private var previewRevision: UInt64 = 0
    private struct PreviewFoldKey: Equatable {
        var revision: UInt64
        var detail: ChatDetail
        var open: Bool
        var toggled: Set<String>
    }
    @ObservationIgnored private var previewFoldCache: [ChatDisplayItem] = []
    @ObservationIgnored private var previewFoldKey: PreviewFoldKey?

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
                limit: ChatPaging.previewPageEvents, peer: route.peer, includeUsage: false)
            guard !Task.isCancelled, WorkSessionContext.shared.scope == owner.scope,
                  continuityScope == owner.scope, previewCacheEpoch == epoch,
                  !recentMessages.contains(key),
                  !(folderID == folder && selected?.id == conversation.id) else { return }
            let rows = try await previewProjector.project(page.events,
                backend: conversation.backend, running: conversation.running)
            guard !Task.isCancelled, WorkSessionContext.shared.scope == owner.scope,
                  continuityScope == owner.scope, previewCacheEpoch == epoch,
                  !recentMessages.contains(key),
                  !(folderID == folder && selected?.id == conversation.id) else { return }
            recentMessages.store(rows, for: key, speculative: true) { $0.estimatedBytes }
            DiagnosticsLog.note("chat preview prepared source=hover rows=\(rows.count) held=\(recentMessages.contains(key))")
            Self.warmMarkdown(recentMessages.peek(key))
        } catch { }
        #endif
    }

    @discardableResult
    func warmWorkspacePreviews(_ folder: String, includeMessages: Bool = true) async -> Bool {
        #if os(macOS)
        let scope = WorkSessionContext.shared.scope
        let epoch = previewCacheEpoch
        let route = Bridge.chatRoute(workspaceID: folder, peer: nil)
        if route.peer == nil { await WorkSessionContext.shared.resolveLocalHostIdentity() }
        guard let scope, let host = route.peer ?? WorkSessionContext.shared.localHostIdentity,
              !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return true }
        let listRead = beginChatListRead(workspaceID: route.workspaceID, peer: route.peer, scope: scope)
        do {
            let answer = try await Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return true }
            if continuityScope == nil { continuityScope = scope }
            guard continuityScope == scope else { return true }
            let list = applyChatList(answer, read: listRead, current: sidebarChats(in: folder))
            storeChatListCache(Self.uniqued(list), folderID: folder)
            guard includeMessages, previewCacheEpoch == epoch else { return true }
            let prefix = WorkReferenceKey.folder(scope: scope, hostIdentity: host, workspaceID: route.workspaceID)
            let worth = Self.uniqued(list).filter { !isUnused($0, in: folder) }
            let candidates = ChatHistoryWindow.previews(in: worth,
                limit: ChatRecentMessages<ChatDisplayItem>.perFolderLimit) {
                    folderID == folder && selected?.id == $0.id
                }
            for chat in candidates {
                guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                      previewCacheEpoch == epoch else { return true }
                if folderID == folder && selected?.id == chat.id { continue }
                let key = prefix + WorkReferenceKey.encode(chat.id)
                if recentMessages.contains(key) { continue }
                while previewReads.count >= 2 {
                    try await Task.sleep(for: .milliseconds(40))
                    guard scope == WorkSessionContext.shared.scope,
                          previewCacheEpoch == epoch else { return true }
                }
                if recentMessages.contains(key) || (folderID == folder && selected?.id == chat.id) { continue }
                guard previewReads.insert(key).inserted else { continue }
                defer { previewReads.remove(key) }
                do {
                    let page = try await Bridge.chatEventPage(id: chat.id, cursor: nil,
                        limit: ChatPaging.previewPageEvents, peer: route.peer, includeUsage: false)
                    guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                          previewCacheEpoch == epoch else { return true }
                    if recentMessages.contains(key) || (folderID == folder && selected?.id == chat.id) { continue }
                    let rows = try await previewProjector.project(page.events,
                        backend: chat.backend, running: chat.running)
                    guard !Task.isCancelled, scope == WorkSessionContext.shared.scope,
                          previewCacheEpoch == epoch else { return true }
                    if recentMessages.contains(key) || (folderID == folder && selected?.id == chat.id) { continue }
                    recentMessages.store(rows, for: key, speculative: true) { $0.estimatedBytes }
                    DiagnosticsLog.note("chat preview prepared source=workspace rows=\(rows.count) held=\(recentMessages.contains(key))")
                    Self.warmMarkdown(recentMessages.peek(key))
                } catch {
                    continue
                }
            }
            return true
        } catch {
            guard !Task.isCancelled, scope == WorkSessionContext.shared.scope else { return true }
            guard chatListCache[folder] == nil else { return false }
            sidebarListErrors[folder] = (scope, error.localizedDescription)
            if sidebarListErrors.count > Self.chatListCacheCap,
               let drop = sidebarListErrors.keys.first(where: { $0 != folder }) {
                sidebarListErrors.removeValue(forKey: drop)
            }
            return false
        }
        #else
        return true
        #endif
    }

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
                        limit: ChatPaging.previewPageEvents, peer: peer, includeUsage: false)
                    guard !Task.isCancelled, self.folderID == folderID,
                          self.warmGeneration == generation,
                          WorkSessionContext.shared.scope == owner.scope else { break }
                    guard self.selected?.id != chat.id,
                          !self.recentMessages.contains(key),
                          self.previewCacheEpoch == epoch else { continue }
                    let rows = try await self.previewProjector.project(page.events,
                        backend: chat.backend, running: chat.running)
                    guard !Task.isCancelled, self.folderID == folderID,
                          self.warmGeneration == generation,
                          WorkSessionContext.shared.scope == owner.scope else { break }
                    guard self.selected?.id != chat.id,
                          !self.recentMessages.contains(key),
                          self.previewCacheEpoch == epoch else { continue }
                    self.recentMessages.store(rows, for: key, speculative: true) { $0.estimatedBytes }
                    DiagnosticsLog.note("chat preview prepared source=recent rows=\(rows.count) held=\(self.recentMessages.contains(key))")
                    Self.warmMarkdown(self.recentMessages.peek(key))
                } catch {
                    continue
                }
            }
        }
        #endif
    }

    var isShowingCachedTranscript: Bool {
        (openingConversation || holdsPreviewOffline) && !recentMessagePreview.isEmpty
    }
    var transcriptItems: [ChatDisplayItem] {
        let detail = ChatDetailPreference.shared.level
        let open = groupsOpen
        let toggled = toggledGroups
        if isShowingCachedTranscript {
            let preview = recentMessagePreview
            let key = PreviewFoldKey(revision: previewRevision, detail: detail, open: open, toggled: toggled)
            if key != previewFoldKey {
                previewFoldCache = ChatReplySplit.split(
                    ChatTranscriptFold.fold(ChatImageGrouping.prepare(ChatAuthenticationFailure.presented(preview)), detail: detail, running: false) { open != toggled.contains($0) },
                    cache: replySplitCache
                )
                previewFoldKey = key
            }
            return previewFoldCache
        }
        let pending = outgoing
        let rows = coalescedItems
        let key = FoldKey(display: displayKey, detail: detail, open: open, toggled: toggled)
        if key != foldKey {
            if foldContinuityOwner != selectionGeneration {
                foldContinuity.reset()
                foldContinuityOwner = selectionGeneration
            }
            let running = selected?.running == true
            foldCache = ChatFoldContinuity.$current.withValue(foldContinuity) {
                ChatTranscriptFold.fold(ChatImageGrouping.prepare(ChatAuthenticationFailure.presented(rows)),
                                        detail: detail, running: running) {
                    open != toggled.contains($0)
                }
            }
            foldContinuity.finish()
            if replySplitOwner != selectionGeneration {
                replySplitCache.reset()
                replySplitOwner = selectionGeneration
            }
            foldCache = ChatReplySplit.split(foldCache, cache: replySplitCache)
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

    @ObservationIgnored private let replySplitCache = ChatReplySplit.Cache()
    @ObservationIgnored private var replySplitOwner: UInt64?

    private(set) var groupsOpen = false
    private(set) var toggledGroups: Set<String> = []

    func toggleGroup(_ id: String) {
        if toggledGroups.contains(id) { toggledGroups.remove(id) } else { toggledGroups.insert(id) }
    }

    func setAllGroups(open: Bool) {
        groupsOpen = open
        toggledGroups = []
    }

    var anyGroupOpen: Bool { groupsOpen || !toggledGroups.isEmpty }

    func rowExtendedAtStart(_ id: String) -> Bool {
        if rowsExtendedAtStart.contains(id) { return true }
        guard let cut = id.range(of: "~") else { return false }
        return rowsExtendedAtStart.contains(String(id[..<cut.lowerBound]))
    }

    func transcriptRow(holding id: String) -> String? {
        let rows = transcriptItems
        if rows.contains(where: { $0.id == id }) { return id }
        let member = id.hasPrefix("g:") ? String(id.dropFirst(2)) : id
        for row in rows {
            if case let .group(group) = row.kind, group.memberIDs.contains(member) { return row.id }
            if row.imageRowIDs.contains(member) { return row.id }
        }
        if rows.contains(where: { $0.id == member }) { return member }
        if rowsExtendedAtStart.contains(member), rows.contains(where: { $0.id == member + "~end" }) {
            return member + "~end"
        }
        if let piece = ChatReplySplit.rowID(for: member, in: rows) { return piece }
        if let cut = member.range(of: "~") {
            if rows.contains(where: { $0.id == member[..<cut.lowerBound] }) {
                return String(member[..<cut.lowerBound])
            }
            let end = member[cut.lowerBound...]
            if let piece = rows.first(where: { $0.part != nil && $0.id.hasSuffix(end) }) {
                return piece.id
            }
        }
        return ChatReadingAnchor.resolve(member, items: rows, events: events)
    }

    @discardableResult
    func revealRow(_ id: String) -> String {
        if let owner = ChatTranscriptFold.owner(of: id, in: transcriptItems) { toggleGroup(owner) }
        let rows = transcriptItems
        let row = ChatImageGrouping.rowID(for: id, in: rows)
        return ChatReplySplit.rowID(for: row, in: rows) ?? row
    }

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
        let rows = Array(displayItems.suffix(ChatRecentMessages<ChatDisplayItem>.messageLimit))
        recentMessages.store(rows, for: key) { $0.estimatedBytes }
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

    @ObservationIgnored var sidebarStep: ((Int) -> Bool)?

    func stepConversation(_ step: Int) -> Bool {
        if sidebarStep?(step) == true { return true }
        guard let target = adjacentConversation(step) else { return false }
        Task { await select(target) }
        return true
    }

    func adjacentConversation(_ step: Int) -> ChatConversation? {
        let rows = folderID.map { folder in chats.filter { !isUntouched($0, in: folder) } } ?? chats
        guard !rows.isEmpty, step == -1 || step == 1 else { return nil }
        let current = rows.firstIndex(where: { $0.id == selected?.id })
        guard let next = ChatHistoryWindow.looped(count: rows.count, current: current, step: step),
              rows.indices.contains(next) else {
            return nil
        }
        return rows[next]
    }

    private var chatListCache: [String: [ChatConversation]] = [:]
    private var sidebarListErrors: [String: (scope: WorkReference.Scope, message: String)] = [:]
    private static let chatListCacheCap = 30
    @ObservationIgnored private var sidebarWorkspaceIDs: Set<String> = []

    func retainSidebarWorkspaceLists(_ ids: [String]) {
        sidebarWorkspaceIDs = Set(ids)
        trimChatListCache(keeping: nil)
    }

    func hasSidebarList(for folderID: String) -> Bool {
        chatListCache[folderID] != nil
    }

    private func trimChatListCache(keeping: String?) {
        while chatListCache.count > Self.chatListCacheCap,
              let drop = chatListCache.keys.first(where: { $0 != keeping && !sidebarWorkspaceIDs.contains($0) }) {
            chatListCache.removeValue(forKey: drop)
        }
    }

    func isUntouched(_ conversation: ChatConversation, in folderID: String) -> Bool {
        conversation.id != selected?.id && isUnused(conversation, in: folderID)
    }

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

    func sidebarDirectoryPresentation(in folderID: String) -> WorkspaceDirectoryPresentation {
        let scopedError = sidebarListErrors[folderID].flatMap {
            $0.scope == WorkSessionContext.shared.scope ? $0.message : nil
        }
        guard continuityScope == WorkSessionContext.shared.scope else {
            return .resolve(hasContent: false, hasLoaded: false, isLoading: false, error: scopedError)
        }
        return .resolve(hasContent: !sidebarChats(in: folderID).isEmpty,
                        hasLoaded: chatListCache[folderID] != nil,
                        isLoading: self.folderID == folderID && isLoading,
                        error: chatListCache[folderID] == nil
                            ? (scopedError ?? (self.folderID == folderID ? error : nil)) : nil)
    }

    private func storeChatListCache(_ list: [ChatConversation], folderID: String) {
        sidebarListErrors[folderID] = nil
        guard chatListCache[folderID] != list else { return }
        chatListCache[folderID] = list
        trimChatListCache(keeping: folderID)
        noteRunningChats()
    }

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
        scheduleSidebarRunningRefresh()
    }

    @ObservationIgnored private var sidebarRunningRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarRunningRefreshGeneration: UInt64 = 0

    private func foldersNeedingRunningRefresh() -> [String] {
        chatListCache.compactMap { folderID, list in
            guard list.contains(where: \.running) else { return nil }
            if folderID == self.folderID, pollingIdentity != nil { return nil }
            return folderID
        }
    }

    private func scheduleSidebarRunningRefresh() {
        #if os(macOS)
        let targets = foldersNeedingRunningRefresh()
        guard !targets.isEmpty else {
            sidebarRunningRefreshGeneration &+= 1
            sidebarRunningRefreshTask?.cancel()
            sidebarRunningRefreshTask = nil
            return
        }
        guard sidebarRunningRefreshTask == nil else { return }
        sidebarRunningRefreshGeneration &+= 1
        let generation = sidebarRunningRefreshGeneration
        sidebarRunningRefreshTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    guard let self else { return }
                    guard self.sidebarRunningRefreshGeneration == generation else { return }
                    self.sidebarRunningRefreshTask = nil
                    self.scheduleSidebarRunningRefresh()
                }
            }
            var backoff: [String: (wait: Duration, next: ContinuousClock.Instant)] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                guard self.sidebarRunningRefreshGeneration == generation else { return }
                let folders = self.foldersNeedingRunningRefresh()
                if folders.isEmpty { return }
                for folder in folders {
                    guard !Task.isCancelled else { return }
                    guard self.sidebarRunningRefreshGeneration == generation else { return }
                    if let held = backoff[folder], held.next > .now { continue }
                    if await self.warmWorkspacePreviews(folder, includeMessages: false) {
                        backoff[folder] = nil
                    } else {
                        let wait = min((backoff[folder]?.wait ?? .seconds(2)) * 2, .seconds(60))
                        backoff[folder] = (wait, .now + wait)
                    }
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
        #endif
    }

    private var attachmentCacheGeneration: UInt64 = 0
    private var attemptedResponseAttachments: Set<String> = []
    @ObservationIgnored private var attachmentDescriptorRevision: UInt64?
    @ObservationIgnored private var attachmentDescriptors: [ChatAttachment] = []
    @ObservationIgnored private var attachmentScan: (count: Int, first: UInt64?, last: UInt64?)?
    private(set) var loadingResponseAttachments: Set<String> = []
    private(set) var responseAttachmentErrors: [String: String] = [:]

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
        if folderID != workspaceID || self.workspaceID != route.workspaceID
            || self.peer != route.peer || continuityScope != scope {
            rememberRecentMessages()
            cancelPreviewWarmup()
        }
        loadGeneration &+= 1
        isCreating = false
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
            if let previous = continuityScope, let scope, previous != scope {
                loadDraft(for: nil, scope: nil, hostIdentity: nil, workspaceID: nil)
            }
            chatListCache = [:]
            sidebarListErrors = [:]
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
        let loadStarted = ProcessInfo.processInfo.systemUptime
        var primedFromCache = false
        if folderID != workspaceID || self.workspaceID != route.workspaceID || self.peer != route.peer {
            clearRecentMessagePreview()
            personas = []
            defaultPersonaID = nil
            if self.peer != route.peer {
                pagingUnavailable = false
                backends = []
                backendRefreshError = nil
            }
            if let selected, let old = folderID {
                rememberLastSelected(chatID: selected.id, folderID: old)
            }
            if let old = folderID, !chats.isEmpty {
                storeChatListCache(chats, folderID: old)
            }
            if selectFirst, let cached = chatListCache[workspaceID] {
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
        responseAttachmentFiles = [:]
                attemptedResponseAttachments = []
                loadingResponseAttachments = []
                responseAttachmentErrors = [:]
                forgetWindow()
                loadQueue(for: selected?.id)
                loadDraft(for: selected?.id, scope: scope, hostIdentity: draftHost,
                          workspaceID: route.workspaceID)
                openingConversation = selected != nil
                primedFromCache = selected != nil
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
        var earlyOpen: Task<Void, Never>?
        if primedFromCache, let early = selected, events.isEmpty, savedCopy == nil {
            let openGeneration = selectionGeneration
            earlyOpen = Task { [weak self] in
                guard let self else { return }
                let opened = await self.openEvents(id: early.id, generation: openGeneration)
                #if DEBUG
                if opened, self.selectionMatches(id: early.id, generation: openGeneration) {
                    TranscriptProbe.shared.noteOpen(milliseconds: (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000,
                        preview: true, phase: "folder-early-page")
                }
                #endif
                if opened, self.selectionGeneration == openGeneration { self.openingConversation = false }
            }
        }
        setupLoadTask?.cancel()
        setupLoadTask = Task { [weak self] in
            await self?.loadSetup(workspaceID: route.workspaceID, peer: route.peer,
                                  generation: generation, scope: scope)
        }
        let listRead = beginChatListRead(workspaceID: route.workspaceID, peer: route.peer, scope: scope)
        do {
            let loaded = try await Bridge.chats(workspaceID: route.workspaceID, peer: route.peer)
            probe.error("load answered gen=\(generation)/\(self.loadGeneration) scopeThen=\(String(describing: scope?.identity)) scopeNow=\(String(describing: WorkSessionContext.shared.scope?.identity)) chats=\(loaded.count)")
            guard generation == loadGeneration, scope == WorkSessionContext.shared.scope else {
                return
            }
            let fresh = Self.uniqued(applyChatList(loaded, read: listRead, current: chats))
            if fresh != chats { chats = fresh }
            storeChatListCache(chats, folderID: workspaceID)
            await earlyOpen?.value
            guard generation == loadGeneration else { return }
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
                    if pendingRevealFolderID == nil || pendingRevealFolderID == workspaceID {
                        pendingRevealID = nil
                        pendingRevealFolderID = nil
                    }
                    await select(nil)
                    error = L10n.text("apple.chatmodel.this_conversation_is_no_longer_available_i.d930b486")
                }
            } else if let selected, let fresh = chats.first(where: { $0.id == selected.id }) {
                if fresh != selected { self.selected = fresh }
                await refreshOpen(id: fresh.id)
            } else if selectFirst {
                probe.error("selecting remembered=\(String(describing: rememberedID)) of \(self.chats.count)")
                if let remembered = rememberedID,
                   let found = chats.first(where: { $0.id == remembered }) {
                    await select(found)
                } else {
                    await select(chats.first)
                }
            } else {
                await select(nil)
            }
            if generation == loadGeneration {
                warmRecentChats()
            }
        } catch {
            if generation == loadGeneration {
                if !Task.isCancelled, !(error is CancellationError), scope == WorkSessionContext.shared.scope {
                    self.error = error.localizedDescription
                }
                openingConversation = false
            }
        }
    }

    private func loadSetup(workspaceID: String, peer: String?, generation: UInt64,
                           scope: WorkReference.Scope?) async {
        async let catalog: Void = loadBackendCatalog(peer: peer, generation: generation, scope: scope)
        async let voices: Void = loadPersonaCatalog(workspaceID: workspaceID, peer: peer,
                                                   generation: generation, scope: scope)
        async let profiles: Void = refreshAgentProfiles()
        _ = await (catalog, voices, profiles)
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
        } catch { }
    }

    private static func uniqued(_ chats: [ChatConversation]) -> [ChatConversation] {
        var seen = Set<String>()
        return chats.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    func reveal(id: String, in folderID: String? = nil) {
        guard !id.isEmpty else { return }
        pendingRevealID = id
        pendingRevealFolderID = folderID
    }

    func select(_ chat: ChatConversation?) async {
        await select(chat, savedPage: nil)
        if selected?.id == chat?.id { warmRecentChats() }
    }

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
            ChatReadingStore.shared.request(.init(eventID: anchor, offset: 0, updatedAt: Date(), revealTarget: true), for: reference)
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
        holdsPreviewOffline = false
        advanceSelection("select")
        discardSteerReservations()
        let generation = selectionGeneration
        #if DEBUG
        let openingStarted = ProcessInfo.processInfo.systemUptime
        #endif
        selected = chat
        groupsOpen = false
        toggledGroups = []
        if let chat, let folderID {
            rememberLastSelected(chatID: chat.id, folderID: folderID)
        }
        responseAttachmentData = [:]
        responseAttachmentFiles = [:]
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
            openingConversation = false
            liveWindowLoaded = true
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
            await openSavedCopy(id: chat.id, generation: generation)
        }
        if selectionMatches(id: chat.id, generation: generation) {
            holdsPreviewOffline = events.isEmpty && savedCopy == nil && !recentMessagePreview.isEmpty
            openingConversation = false
        }
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

    private func refreshOpen(id: String) async {
        let generation = selectionGeneration
        let wasSavedCopy = savedCopy != nil
        if wasSavedCopy {
            savedCopy = nil
            events = []
            outgoing = []
            outgoingWatermark = [:]
            forgetWindow()
        }
        if events.isEmpty {
            openingConversation = true
            defer {
                if selectionGeneration == generation { openingConversation = false }
            }
            let openedLive = await openEvents(id: id, generation: generation, quiet: wasSavedCopy)
            if !openedLive, events.isEmpty, selectionMatches(id: id, generation: generation) {
                await openSavedCopy(id: id, generation: generation)
            }
            if selectionMatches(id: id, generation: generation) {
                holdsPreviewOffline = events.isEmpty && savedCopy == nil && !recentMessagePreview.isEmpty
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

    var canDiscardPagedHistory: Bool {
        hasPagedBack && !openingConversation && !sending && !sendingNow && savedCopy == nil
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
        guard !Task.isCancelled, !openingConversation, !sending, !sendingNow, let selected else { return }
        advanceSelection("explicit-latest")
        earlierInFlight = false
        loadingEarlier = false
        discardSteerReservations()
        let generation = selectionGeneration
        openingConversation = true
        defer {
            if selectionGeneration == generation { openingConversation = false }
        }
        await openEvents(id: selected.id, generation: generation)
    }

    /// One creation at a time: a second tap while the backend answers awaits
    /// the same conversation instead of doubling the sidebar.
    private var createSingleflight = Singleflight<ChatConversation?>()
    private var createContext: UInt64?
    private var createTicket = UUID()

    @discardableResult
    func create() async -> ChatConversation? {
        guard !Task.isCancelled else { return nil }
        let context = loadGeneration
        if createContext != context {
            createSingleflight = Singleflight<ChatConversation?>()
            createContext = context
        }
        let flight = createSingleflight
        if !flight.isRunning { createTicket = UUID() }
        let ticket = createTicket
        isCreating = true
        defer { if createTicket == ticket, context == loadGeneration { isCreating = false } }
        return await flight.run { await self.performCreate(expectedGeneration: context) }
    }

    private(set) var isCreating = false

    private func performCreate(expectedGeneration: UInt64) async -> ChatConversation? {
        let requestedChoice = newChatChoice
        newChatChoice = nil
        guard !Task.isCancelled, expectedGeneration == loadGeneration, let workspaceID, let scope = continuityScope,
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
            let chosen: ChatBackend?
            if let requested = requestedChoice {
                guard let explicit = available.first(where: { $0.id == requested.backend }),
                      requested.model == nil || explicit.models.contains(requested.model!),
                      requested.effort == nil || explicit.efforts.contains(requested.effort!),
                      !requested.fastMode || ChatFastMode.available(model: requested.model, models: explicit.fastModeModels, backend: explicit.id) else {
                    error = L10n.text("apple.chatmodel.that_agent_setup_is_not_available_on_this.b1407fd7")
                    return nil
                }
                chosen = explicit
            } else {
                chosen = available.first { $0.id == saved?.backend }
                    ?? available.first { $0.id == "codex" }
                    ?? available.first
                    ?? backends.first { $0.id != "sh" }
            }
            let model = requestedChoice != nil ? requestedChoice?.model
                : (chosen?.models.contains(saved?.model ?? "") == true ? saved?.model : nil)
            let effort = requestedChoice != nil ? requestedChoice?.effort
                : (chosen?.efforts.contains(saved?.effort ?? "") == true ? saved?.effort : nil)
            let chat = try await Bridge.createChat(
                workspaceID: workspaceID,
                backend: chosen?.id ?? "claude",
                mode: requestedChoice?.mode ?? "execute",
                autonomy: chosen?.gateTier == "bypassOnly"
                    ? "bypass"
                    : (requestedChoice?.autonomy ?? "bypass"),
                model: model,
                effort: effort,
                personaID: rememberedPersonaID(saved),
                profileID: workspaceProfileLock ?? requestedChoice?.profileID,
                peer: targetPeer
            )
            guard !Task.isCancelled, context == loadGeneration, scope == WorkSessionContext.shared.scope else {
                if scope == WorkSessionContext.shared.scope {
                    try await Bridge.removeChat(id: chat.id, peer: targetPeer)
                }
                return nil
            }
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
        guard backend.canCheckSignIn else { await reloadBackends(refreshModels: false); return nil }
        let context = loadGeneration
        let owner = peer
        let selection = selectionGeneration
        let profile = profileID(for: selected)
        if owner != nil && usesOwnLogin(backend, chat: selected) { return nil }
        do {
            let status = try await Bridge.agentSetupCheck(peer: owner, id: id, profile: profile)
            guard !Task.isCancelled, context == loadGeneration, peer == owner,
                  selection == selectionGeneration, profile == profileID(for: selected),
                  let index = backends.firstIndex(where: { $0.id == backend.id }) else { return nil }
            if usesOwnLogin(backend, chat: selected), let profile {
                profileSignIn[profile, default: [:]][backend.id] = status
            } else {
                backends[index].readiness = status.readiness
                backends[index].signInVerified = status.checked == true
            }
            backendRefreshError = nil
            return status
        } catch {
            guard context == loadGeneration else { return nil }
            backendRefreshError = error.localizedDescription
            return nil
        }
    }

    func routing(policy: ChatRoutingPolicy? = nil, action: String? = nil) async -> Bool {
        guard !isSharedSource, savedCopy == nil, let selected, let revision = selected.sendRevision else { return false }
        let generation = selectionGeneration
        do {
            let state = try await Bridge.chatRouting(id: selected.id, revision: revision, policy: policy, action: action, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return false }
            var updated = self.selected ?? selected
            updated.routing = state
            replace(updated)
            return true
        } catch {
            if selectionMatches(id: selected.id, generation: generation) { self.error = error.localizedDescription }
            return false
        }
    }

    var cacheWarning: ChatCacheWarning?

    var agentUpdatePrompt: AgentUpdatePrompt?

    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private(set) var updatingAgentID: String?
    private var agentUpdateNotice: String? {
        get { AgentUpdateNotice.shared.message }
        set { AgentUpdateNotice.shared.message = newValue }
    }
    private var agentUpdateSeverity: Banner.Severity {
        get { AgentUpdateNotice.shared.severity }
        set { AgentUpdateNotice.shared.severity = newValue }
    }

    @discardableResult
    func updateAgent(id: String, label: String) async -> AgentUpdateResult? {
        guard updatingAgentID == nil else { return nil }
        let peer = self.peer
        updatingAgentID = id
        agentUpdateSeverity = .info
        agentUpdateNotice = L10n.text("common.agent_updates.toast_updating", label)
        defer { updatingAgentID = nil }
        do {
            let result = try await Bridge.agentUpdate(id: id, peer: peer)
            guard self.peer == peer else { return result }
            if result.ok {
                agentUpdateSeverity = .success
                switch (result.before, result.after) {
                case let (before?, after?) where before != after:
                    agentUpdateNotice = L10n.text("common.agent_updates.toast_updated", label, before, after)
                case let (_, after?):
                    agentUpdateNotice = L10n.text("common.agent_updates.toast_current", label, after)
                default:
                    agentUpdateNotice = L10n.text("common.agent_updates.toast_finished", label)
                }
            } else {
                agentUpdateSeverity = .warning
                agentUpdateNotice = L10n.text("common.agent_updates.toast_failed", label)
            }
            await reloadBackends(refreshModels: false)
            return result
        } catch {
            guard self.peer == peer else { return nil }
            agentUpdateSeverity = .warning
            agentUpdateNotice = L10n.text("common.agent_updates.toast_failed", label)
            return nil
        }
    }

    func requestModelChange(_ next: String) async {
        guard landingDraft == nil, let selected,
              !ChatPromptCacheRule.isSuppressed(ChatPromptCacheRule.modelSuppressedKey),
              ChatPromptCacheRule.switching(selected, to: next, nowMs: Self.nowMs),
              let cache = ChatPromptCacheRule.cache(selected) else {
            await update(model: next)
            return
        }
        let id = selected.id
        cacheWarning = ChatCacheWarning(
            kind: .modelSwitch(from: cache.model ?? cache.selection, to: next),
            tokens: cache.tokens
        ) { [weak self] in
            guard let self, self.selected?.id == id, self.selected?.running == false else { return }
            Task { await self.update(model: next) }
        }
    }

    func continueInNew(_ conversation: ChatConversation, expectedDraft: String, profileID: String? = nil) async -> ChatConversation? {
        guard let folderID else { return nil }
        let scope = WorkSessionContext.shared.scope
        do {
            let created = try await Bridge.continueChatInNew(id: conversation.id, profileID: profileID, peer: peer)
            guard scope == WorkSessionContext.shared.scope, self.folderID == folderID,
                  selected?.id == conversation.id, draft == expectedDraft,
                  attachments.isEmpty else { return nil }
            publishSidebarConversation(created, in: folderID)
            await select(created)
            return selected?.id == created.id ? created : nil
        } catch {
            self.error = error.localizedDescription
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
        allowedShellPrefixes: [String]? = nil,
        profileID: String? = nil
    ) async {
        if landingDraft != nil {
            updateLanding(backend: backend, model: model, effort: effort, fastMode: fastMode, mode: mode, autonomy: autonomy, profileID: profileID)
            return
        }
        guard !isSharedSource, savedCopy == nil, let selected else { return }
        let generation = selectionGeneration
        do {
            let updated = try await Bridge.updateChat(
                id: selected.id,
                title: title,
                backend: backend,
                model: model,
                effort: effort,
                fastMode: fastMode,
                expectedRevision: fastMode != nil || profileID != nil ? selected.sendRevision : nil,
                mode: mode,
                autonomy: autonomy,
                personaID: personaID,
                systemPrompt: systemPrompt,
                allowedTools: allowedTools,
                allowedShellPrefixes: allowedShellPrefixes,
                profileID: profileID,
                peer: peer
            )
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            contextRevision = ChatSendContext.afterOwnEdit(contextRevision,
                previous: selected.sendRevision, updated: updated.sendRevision)
            replace(updated)
            if backend != nil || systemPrompt != nil || personaID != nil {
                await loadInstructions(id: selected.id, generation: generation)
            }
        } catch {
            if selectionMatches(id: selected.id, generation: generation) {
                self.error = error.localizedDescription
            }
        }
    }

    func applyPersona(_ persona: ChatPersona?) async {
        guard let persona else {
            await update(personaID: "", systemPrompt: "")
            return
        }
        await update(personaID: persona.id, systemPrompt: persona.systemPrompt)
    }

    func draftPersona(brief: String, backend: String, name: String? = nil,
                      owner: PersonaContext) async throws -> ChatPersonaDraft {
        try requirePersonaContext(owner)
        let result = try await Bridge.draftChatPersona(
            brief: brief, backend: backend, name: name, peer: owner.peer
        )
        try requirePersonaContext(owner)
        return result
    }

    func rename(_ conversation: ChatConversation, in folderID: String, to title: String, peer: String? = nil) async throws {
        let scope = WorkSessionContext.shared.scope
        let generation = selectionGeneration
        let ownRevision = self.folderID == folderID && selected?.id == conversation.id ? selected?.sendRevision : nil
        let updated = try await Bridge.updateChat(id: conversation.id, title: title,
                                                  peer: Bridge.chatRoute(workspaceID: folderID, peer: peer).peer)
        guard scope == WorkSessionContext.shared.scope else { return }
        if self.folderID == folderID, selectionMatches(id: conversation.id, generation: generation) {
            contextRevision = ChatSendContext.afterOwnEdit(contextRevision,
                previous: ownRevision, updated: updated.sendRevision)
        }
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
        var remaining = sidebarChats(in: folderID).filter { $0.teamShare != nil }
        do {
            _ = try await Bridge.removeAllChats(workspaceID: folderID, peer: peer)
            guard context == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
            if let current = try? await Bridge.chats(workspaceID: folderID, peer: peer) { remaining = current }
            guard context == loadGeneration, scope == WorkSessionContext.shared.scope else { return }
            previewCacheEpoch &+= 1
            if let cachePrefix { recentMessages.retain(Set(remaining.map { cachePrefix + WorkReferenceKey.encode($0.id) }), in: cachePrefix) }
            if self.folderID == folderID { clearRecentMessagePreview() }
            error = nil
            storeChatListCache(remaining, folderID: folderID)
            if !remaining.contains(where: { $0.id == rememberedChat(in: folderID) }) { forgetLastSelected(folderID: folderID) }
            if self.folderID == folderID || workspaceID == folderID {
                chats = remaining
                if let selected, let kept = remaining.first(where: { $0.id == selected.id }) {
                    self.selected = kept
                } else { await select(remaining.first) }
            }
        } catch {
            if context == loadGeneration, scope == WorkSessionContext.shared.scope { self.error = error.localizedDescription }
        }
    }

    private(set) var sending = false
    @ObservationIgnored private var sendToken: UInt64 = 0
    @ObservationIgnored private var composerSendToken: UInt64?
    @ObservationIgnored private var busyNoteToken: UInt64?
    @ObservationIgnored private var busyNoteSubmission: ChatDraftSubmission?
    @ObservationIgnored private var steerProbeStarted = false
    @ObservationIgnored private var steerProbeTicket: UUID?
    @ObservationIgnored private var steerProbeOwner: PollOwner?
    @ObservationIgnored private var deliveringSteer: ChatSteerContext?
    @ObservationIgnored private var deliveringSteerToken: UInt64?
    @ObservationIgnored private var clearingSteer: ChatSteerContext?
    @ObservationIgnored private var clearingSteerToken: UInt64?
    private(set) var queued: [ChatQueuedMessage] = []
    private var deliveringFromComposer: String?
    var pendingQueue: [ChatQueuedMessage] {
        let signInID = signInQueuedMessage?.id
        return queued.filter { $0.id != deliveringFromComposer && $0.id != signInID }
    }
    private var queuedReference: WorkReference?
    @ObservationIgnored private var sendingNow = false
    private var authorizedQueueItems: Set<String> = []
    private var queueHead: ChatQueuedMessage? {
        queued.first { item in
            guard let held = item.signInBackend else { return true }
            return held == selected?.backend
        }
    }

    var queuePaused: Bool {
        if isSharedSource { return true }
        guard let first = queueHead else { return false }
        return first.signInBackend != nil || !authorizedQueueItems.contains(first.id) || first.delivery != .waiting
    }

    private var ownsQueue: Bool {
        guard let queuedReference else { return false }
        return currentReference == queuedReference && WorkCacheAccess.canRead(queuedReference)
    }

    @discardableResult
    func enqueue(_ text: String, atFront: Bool = false, whenConnected: Bool = false, awaitingSignIn: Bool = false) -> ChatQueuedMessage? {
        guard !isSharedSource, stagingAttachments == 0, (savedCopy == nil || whenConnected), ownsQueue, let reference = queuedReference else { return nil }
        let draftID = draftMessageID
        if queuedDeliveries(forDraft: draftID).contains(where: \.needsReceipt) {
            error = L10n.text("apple.chatmodel.check_delivery_in_pending_messages_before.af602276")
            return nil
        }
        var item = ChatQueuedMessage(
            id: deliveryID(forDraft: draftID, text: text, attachments: attachments) ?? UUID().uuidString,
            text: text, attachments: attachments
        )
        item.whenConnected = whenConnected
        item.signInBackend = awaitingSignIn ? selected?.backend : nil
        item.expectedRevision = contextRevision
        do {
            queued = try ChatOutboxStore.shared.update(reference) { items in
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    guard items[index].text == item.text, items[index].attachments == item.attachments else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                    if item.whenConnected { items[index].whenConnected = true }
                    if let backend = item.signInBackend { items[index].signInBackend = backend }
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
                guard let index = items.firstIndex(where: { $0.id == item.id }), items[index].hasSameWriting(as: item),
                      items[index].canEdit else { throw ChatOutboxStore.Failure.conflict }
                guard items[index].text != text else { return }
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
            if unconfirmedSend?.messageID == item.id {
                if draft == (item.sourceDraftText ?? item.text), attachments == item.attachments {
                    clearDraft()
                    attachments = []
                    attachmentPreviews = [:]
                    missingDraftAttachments = []
                } else {
                    ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference, newMessage: true)
                }
                unconfirmedSend = nil
            }
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

    func sendNow(_ item: ChatQueuedMessage, owner: WorkReference?, forceStop: Bool = false, steerOnly: Bool = false) async {
        guard let owner, owner == queuedReference, ownsQueue else { return }
        if let backend = item.signInBackend {
            error = L10n.text("apple.agentsetup.pending_other_agent", self.backend(for: backend)?.label ?? backend.capitalized)
            return
        }
        guard savedCopy == nil else {
            error = L10n.text("apple.chatmodel.check_for_updates_to_return_to_the_live_co.3b041e43")
            return
        }
        guard !sendingNow else { return }
        sendingNow = true
        defer { sendingNow = false }
        var candidate = item
        if item.delivery == .needsReview {
            let generation = selectionGeneration
            guard let selected else { return }
            let id = selected.id
            do {
                let answer = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
                guard selectionMatches(id: id, generation: generation), owner == currentReference,
                      let latest = answer.first(where: { $0.id == id }), let revision = latest.sendRevision else { return }
                replace(latest)
                contextRevision = latest.sendRevision
                await loadEvents(id: id, reset: false, generation: generation)
                guard selectionMatches(id: id, generation: generation), owner == currentReference else { return }
                candidate = try ChatOutboxStore.shared.prepare(item, revision: revision, for: owner)
                queued = try ChatOutboxStore.shared.items(for: owner)
            } catch { self.error = L10n.text("apple.chatmodel.the_pending_message_changed_reopen_it_befo.3d158d7b"); return }
        }
        let steer = steerOnly || (!forceStop && busy && selected?.nativeSteer == true
            && ChatCommandRules.canSteer(candidate.text, attachments: !candidate.attachments.isEmpty,
                                         acceptsAttachments: nativeSteerAcceptsAttachments))
        _ = await deliverQueued(candidate, stopCurrent: !steer, steerCurrent: steer)
    }

    func drainQueue() async {
        if deliveringSteer != nil || clearingSteer != nil { return }
        if let note = selected?.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return
        }
        guard !busy, !sending, !sendingNow, !queuePaused, let item = queueHead else { return }
        if await deliverQueued(item, stopCurrent: false), !busy {
            await drainQueue()
        }
    }

    private func busyTurnError() {
        error = L10n.text("apple.chatmodel.this_conversation_is_still_finishing_its_p.01b9e26a")
    }

    private func deliverQueued(_ candidate: ChatQueuedMessage, stopCurrent: Bool, reserved: Bool = false, steerCurrent: Bool = false, retryUnavailableSteer: Bool = true) async -> Bool {
        guard !isSharedSource, candidate.signInBackend == nil, savedCopy == nil, ownsQueue, (!sending || reserved), let reference = queuedReference,
              WorkCacheAccess.canSave(reference), let conversationID = reference.itemID,
              ChatOutboxStore.shared.beginDelivery(reference) else { return false }
        let token = noteSendStarted()
        defer { ChatOutboxStore.shared.endDelivery(reference); noteSendFinished(token) }
        let targetPeer = peer
        let generation = selectionGeneration
        @MainActor func current() -> Bool {
            !Task.isCancelled && selectionMatches(id: conversationID, generation: generation)
                && currentReference == reference && WorkCacheAccess.canSave(reference) && savedCopy == nil && !isSharedSource
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
            guard let item = stored.first(where: { $0.id == candidate.id }), item.hasSameWriting(as: candidate),
                  item.expectedRevision == candidate.expectedRevision else {
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
            guard current(), !busy || steerCurrent else {
                if current() { busyTurnError() }
                return false
            }
            if !steerCurrent, let backend = backend(for: selected?.backend ?? ""),
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
            guard current(), !busy || steerCurrent else {
                if current() { busyTurnError() }
                return false
            }
            let rotatesDelivery = item.attemptedAt != nil && item.delivery == .waiting
            var deliveryItem = item
            if rotatesDelivery {
                deliveryItem.sourceDraftMessageID = item.sourceDraftMessageID ?? item.id
                deliveryItem.id = UUID().uuidString
            }
            let firstAttemptAt = rotatesDelivery
                ? Date()
                : (item.firstAttemptAt ?? item.attemptedAt ?? Date())
            publish(try ChatOutboxStore.shared.update(reference) { items in
                guard let index = items.firstIndex(where: { $0.id == item.id }),
                      items[index].hasSameWriting(as: item), items[index].canEdit,
                      items[index].expectedRevision == item.expectedRevision else {
                    throw ChatOutboxStore.Failure.conflict
                }
                items[index].id = deliveryItem.id
                items[index].sourceDraftMessageID = deliveryItem.sourceDraftMessageID
                items[index].delivery = .sending
                items[index].firstAttemptAt = firstAttemptAt
                items[index].attemptedAt = Date()
            })
            if deliveringFromComposer == item.id { deliveringFromComposer = deliveryItem.id }
            let staged = stageOutgoing(item.text, steer: steerCurrent)
            var accepted = false
            do {
                let updated = try await Bridge.sendChat(id: conversationID, text: item.text,
                    attachmentIDs: resolved.map(\.id), clientMessageID: deliveryItem.id,
                    clientMessageCreatedAt: firstAttemptAt, expectedRevision: item.expectedRevision, steer: steerCurrent, peer: targetPeer)
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
                if !accepted, steerCurrent,
                   case BridgeError.core(code: "steer_unavailable", message: _) = error {
                    publish(try ChatOutboxStore.shared.update(reference) { items in
                        guard let index = items.firstIndex(where: { $0.id == deliveryItem.id }),
                              items[index].hasSameWriting(as: deliveryItem),
                              items[index].expectedRevision == item.expectedRevision,
                              items[index].delivery == .sending else {
                            throw ChatOutboxStore.Failure.conflict
                        }
                        items[index].delivery = .waiting
                        items[index].attemptedAt = nil
                    })
                    if current() {
                        authorizedQueueItems.remove(item.id)
                        authorizedQueueItems.insert(deliveryItem.id)
                        self.error = nil
                        Task {
                            guard current() else { return }
                            let read = beginChatListRead(workspaceID: reference.workspaceID, peer: targetPeer)
                            guard let answer = try? await Bridge.chats(workspaceID: reference.workspaceID, peer: targetPeer),
                                  current() else { return }
                            let latest = applyChatList(answer, read: read, current: chats)
                            guard let fresh = latest.first(where: { $0.id == conversationID }) else { return }
                            replace(fresh)
                            if retryUnavailableSteer, busy, selected?.nativeSteer == true,
                               selected?.sendRevision == item.expectedRevision,
                               let waiting = queued.first(where: { $0.id == deliveryItem.id }),
                               authorizedQueueItems.contains(waiting.id),
                               ChatCommandRules.canSteer(waiting.text, attachments: !waiting.attachments.isEmpty,
                                                         acceptsAttachments: nativeSteerAcceptsAttachments) {
                                _ = await deliverQueued(waiting, stopCurrent: false, steerCurrent: true,
                                                        retryUnavailableSteer: false)
                            } else {
                                await drainQueue()
                            }
                        }
                    }
                    return false
                }
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
                    : error is CancellationError
                        ? L10n.text("apple.chatmodel.send_interrupted")
                        : L10n.text("apple.chatmodel.this_message_stays_pending.eada83a6") + error.localizedDescription
            }
            return false
        }
    }

    private func resolveDraftAttachments(_ files: [ChatAttachment], reference: WorkReference, peer: String?) async throws -> [ChatAttachment] {
        if files.isEmpty {
            try Task.checkCancellation()
            guard reference.itemID != nil, currentReference == reference,
                  WorkCacheAccess.canSave(reference), savedCopy == nil else { throw CancellationError() }
            return []
        }
        guard let conversationID = reference.itemID else { throw CancellationError() }
        guard !fileTransferInFlight else { throw BridgeError.core(code: "file_transfer_busy", message: L10n.text("common.chat_files_busy")) }
        fileTransferInFlight = true
        fileTransferCancelled = false
        defer { fileTransferName = nil; fileTransferInFlight = false }
        var resolved: [ChatAttachment] = []
        for file in files {
            try Task.checkCancellation()
            guard currentReference == reference, WorkCacheAccess.canSave(reference), savedCopy == nil else { throw CancellationError() }
            if ChatLocalAttachmentStore.isLocal(file) {
                let uploaded = try await ChatLocalAttachmentStore.shared.resolveStream(file, reference: reference) { [weak self] url in
                    guard await MainActor.run(body: { WorkCacheAccess.canSave(reference) }) else { throw CancellationError() }
                    return try await Bridge.uploadChatFile(id: conversationID, file: url, name: file.name, mediaType: file.mediaType, peer: peer, confirmRelay: { [weak self] remaining in await self?.confirmFileRelay(name: file.name, size: file.size, remaining: remaining) ?? false }, progress: { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try await self.updateFileProgress(value, name: file.name, reference: reference)
                    })
                }
                resolved.append(uploaded)
            } else { resolved.append(file) }
        }
        try Task.checkCancellation()
        guard currentReference == reference, WorkCacheAccess.canSave(reference) else { throw CancellationError() }
        return resolved
    }

    func keepImportedDraftFiles(_ files: [ChatAttachment], reference: WorkReference, expected: WorkSharedDraft) async throws {
        guard let conversationID = reference.itemID else { throw CancellationError() }
        let targetPeer = peer
        func requireCurrent() throws {
            try Task.checkCancellation()
            guard currentReference == reference, handoffDraft == expected, WorkCacheAccess.canSave(reference) else { throw CancellationError() }
        }
        for file in files {
            try requireCurrent()
            let cached = await ChatLocalAttachmentStore.shared.contains(file, reference: reference)
            try requireCurrent()
            if cached { continue }
            if (file.size ?? 0) > UInt64(ChatInbox.maxBytes) {
                let url = try await Bridge.downloadChatFile(id: conversationID, attachmentID: file.id, peer: targetPeer,
                    confirmRelay: { [weak self] remaining in await self?.confirmFileRelay(name: file.name, size: file.size, remaining: remaining) ?? false })
                defer { try? FileManager.default.removeItem(at: url) }
                try requireCurrent()
                try await ChatLocalAttachmentStore.shared.keep(file, file: url, reference: reference)
            } else {
                let payload = try await Bridge.chatAttachment(id: conversationID, attachmentID: file.id, peer: targetPeer, confirmRelay: { [weak self] in await self?.confirmFileRelay(name: file.name, size: file.size) ?? false })
                try requireCurrent()
                guard payload.attachment == file, let data = Data(base64Encoded: payload.data) else { throw ChatLocalAttachmentStore.Failure.missing }
                try await ChatLocalAttachmentStore.shared.keep(file, data: data, reference: reference)
            }
        }
    }

    func prepareHandoffDraft(_ expected: WorkSharedDraft) async throws -> WorkSharedDraft {
        guard !isSharedSource, let reference = currentReference, handoffDraft == expected, !sending, stagingAttachments == 0 else { throw CancellationError() }
        let files = try await resolveDraftAttachments(attachments, reference: reference, peer: peer)
        guard currentReference == reference, handoffDraft == expected else { throw CancellationError() }
        return WorkSharedDraft(text: expected.text, attachmentIDs: files.map(\.id))
    }

    private static func draftPreview(_ attachment: ChatAttachment, reference: WorkReference) async throws -> Data? {
        try await ChatLocalAttachmentStore.shared.preview(attachment, reference: reference) { data, file in
            if let file { return ChatThumbnail.make(from: file) }
            if let data { return ChatThumbnail.make(from: data) }
            return nil
        }
    }

    func attach(_ file: URL) async {
        guard let item = ChatInbox.item(from: file) else {
            error = L10n.text("apple.chatmodel.that_file_could_not_be_read.e9fe8433")
            return
        }
        await attach(item)
    }

    func attach(_ item: ChatInboxItem) async {
        guard let reference = currentReference else {
            if let file = item.file { try? FileManager.default.removeItem(at: file) }
            return
        }
        await attach(item, to: reference)
    }

    func attach(_ item: ChatInboxItem, to reference: WorkReference) async {
        if let landingDraft { await stageLandingAttachment(item, reference: reference, state: landingDraft); return }
        defer { if let file = item.file { try? FileManager.default.removeItem(at: file) } }
        guard WorkReferenceKey.conversation(reference) != nil,
              WorkCacheAccess.canRead(reference) else { return }
        if let failure = item.importFailure { error = failure; return }
        let isCurrent = currentReference == reference
        guard !isCurrent || !sending else { return }
        let existing = isCurrent ? attachments : (ChatDraftStore.shared.draft(for: reference)?.attachments ?? [])
        guard existing.count + stagingAttachments < 20 else {
            error = L10n.text("apple.chatmodel.a_draft_can_include_up_to_20_files_remove.14221a45")
            return
        }
        if UInt64(item.data.count) > ChatFileIO.maximumBytes {
            error = L10n.text("common.chat_files_too_large")
            return
        }
        if isCurrent { saveDraftNow() }
        stagingAttachments += 1
        defer { stagingAttachments -= 1 }
        do {
            let attachment: ChatAttachment
            if let file = item.file {
                attachment = try await ChatLocalAttachmentStore.shared.stage(file: file, name: item.name, mediaType: item.mediaType, reference: reference)
            } else {
                attachment = try await ChatLocalAttachmentStore.shared.stage(data: item.data, name: item.name, mediaType: item.mediaType, reference: reference)
            }
            let preview = try? await Self.draftPreview(attachment, reference: reference)
            guard currentReference == reference, WorkCacheAccess.canRead(reference) else {
                let original = ChatDraftStore.shared.draft(for: reference)
                ChatDraftStore.shared.save(text: original?.text ?? "", attachments: (original?.attachments ?? []) + [attachment], for: reference)
                return
            }
            attachments.append(attachment)
            if let preview { attachmentPreviews[attachment.id] = preview }
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
        if let landingDraft {
            landingDraft.removeAttachment(attachment)
            attachments = landingDraft.attachments; attachmentPreviews = landingDraft.previews
            return
        }
        attachments.removeAll { $0.id == attachment.id }
        attachmentPreviews.removeValue(forKey: attachment.id)
        missingDraftAttachments.remove(attachment.id)
        saveDraftNow()
    }

    func stop() async {
        guard savedCopy == nil else { return }
        guard let selected else { return }
        let generation = selectionGeneration
        do {
            try await Bridge.stopChat(id: selected.id, expectedRevision: selected.sendRevision, peer: peer)
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
        let listRead = beginChatListRead(workspaceID: selected.workspaceID, peer: peer)
        do {
            let answer = try await Bridge.chats(workspaceID: selected.workspaceID, peer: peer)
            guard selectionMatches(id: selected.id, generation: generation) else { return }
            let latest = applyChatList(answer, read: listRead, current: chats)
            if chats != latest {
                chats = latest
                if let folderID { storeChatListCache(chats, folderID: folderID) }
            }
            if let current = latest.first(where: { $0.id == selected.id }),
               current != self.selected {
                self.selected = current
                if selected.running && !current.running {
                    await refreshUsage(id: selected.id, generation: generation)
                    guard selectionMatches(id: selected.id, generation: generation) else { return }
                }
            }
            settleNotifications()
        } catch {}
        guard selectionMatches(id: selected.id, generation: generation) else { return }
        if let delivery = claimSteerDelivery() {
            await performSteerDelivery(delivery)
        } else {
            await drainQueue()
        }
    }

    func resolve(_ approval: ChatApproval, choice: String, owner: WorkReference?) async {
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

    func approvalIsPending(_ approval: ChatApproval) -> Bool {
        guard !isSharedSource, savedCopy == nil, !approval.readOnly, approval.decision == nil else { return false }
        guard approvalsLoaded else { return false }
        return approvals.contains { $0.id == approval.id }
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

    private(set) var answeringQuestions: Set<String> = []

    func answerQuestion(_ question: ChatQuestion, answer: String) async {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSharedSource, !answer.isEmpty, savedCopy == nil, let id = selected?.id,
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
            var success = false
            while self.pollIsCurrent(owner), permitsPublication() {
                var more = false
                success = await self.loadEvents(id: id, reset: false, generation: owner.generation,
                    quiet: true, onFreshEvents: { records in
                        guard self.pollIsCurrent(owner), permitsPublication() else { return }
                        if records.contains(where: { record in
                            ["approval", "question", "answer", "answerWithdrawn"].contains(record.kind)
                                || ["done", "failed"].contains(record.event?.kind ?? "")
                        }) {
                            _ = self.startStatusPoll(owner: owner, refresh: true)
                            _ = self.startApprovalPoll(owner: owner, refresh: true)
                        }
                    }, onMoreEvents: { more = $0 })
                guard self.pollIsCurrent(owner), permitsPublication() else { return }
                if !success || !more { break }
                await Task.yield()
            }
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
        } else if pollIsCurrent(owner), permitsPublication(), !busy {
            await drainQueue()
        }
    }

    var busy: Bool {
        selected?.running == true
    }

    var nativeSteerAcceptsAttachments: Bool {
        selected?.nativeSteer == true && selected?.nativeSteerAttachments == true
    }

    var sendsAsNote: Bool {
        guard busy, (attachments.isEmpty || nativeSteerAcceptsAttachments), stagingAttachments == 0, savedCopy == nil else { return false }
        guard steerAutonomy, steerBackend else { return false }
        if selected?.nativeSteer == true {
            return ChatCommandRules.canSteer(draft, attachments: !attachments.isEmpty,
                                             acceptsAttachments: nativeSteerAcceptsAttachments)
        }
        if let peer, !peer.isEmpty { return remoteSteer == true }
        return true
    }

    private var steerBackend: Bool {
        if selected?.backend == "cursor", selected?.mode == "plan" { return false }
        return ["claude", "codex", "cursor", "muse"].contains(selected?.backend ?? "")
    }

    private var steerAutonomy: Bool {
        if selected?.nativeSteer == true { return true }
        if selected?.backend == "muse" { return true }
        return selected?.autonomy == "standard"
    }

    enum BusyNoteStart { case steering(UInt64), queue }

    func beginBusyNote(_ text: String) -> BusyNoteStart {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSharedSource || (trimmed.isEmpty && attachments.isEmpty) || (!attachments.isEmpty && !nativeSteerAcceptsAttachments) || savedCopy != nil
            || stagingAttachments > 0 || sending
            || !steerAutonomy || !steerBackend
            || (remoteSteer == false && selected?.nativeSteer != true) {
            return .queue
        }
        if selected?.nativeSteer == true && !ChatCommandRules.canSteer(trimmed,
            attachments: !attachments.isEmpty, acceptsAttachments: nativeSteerAcceptsAttachments) { return .queue }
        guard let selected, let reference = currentReference,
              reference.scope == WorkSessionContext.shared.scope else { return .queue }
        saveDraftNow()
        let draftID = draftMessageID
        guard !queuedDeliveries(forDraft: draftID).contains(where: \.needsReceipt) else { return .queue }
        busyNoteSubmission = ChatDraftSubmission(
            conversationID: selected.id, peer: peer, scope: reference.scope,
            reference: reference, generation: selectionGeneration,
            text: trimmed, draftText: draft, attachments: attachments,
            messageID: deliveryID(forDraft: draftID, text: trimmed, attachments: attachments) ?? UUID().uuidString,
            expectedRevision: contextRevision
        )
        let token = noteSendStarted()
        busyNoteToken = token
        return .steering(token)
    }

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
        if isSharedSource { restoreSubmission(submission); return }
        let context = ChatSteerContext(reference: reference,
            generation: submission.generation, peer: submission.peer)
        @MainActor func current() -> Bool {
            !Task.isCancelled && context.matches(reference: currentReference,
                generation: selectionGeneration, peer: peer, scope: WorkSessionContext.shared.scope)
        }
        guard current() else {
            queueBusyNote(submission)
            return
        }
        let id = submission.conversationID
        let asked = submission.peer
        if let parked = selected?.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parked.isEmpty, parked != submission.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            queueBusyNote(submission, deliverAsSteer: selected?.nativeSteer == true
                && ChatCommandRules.canSteer(submission.text, attachments: !submission.attachments.isEmpty,
                                             acceptsAttachments: nativeSteerAcceptsAttachments))
            return
        }
        do {
            if selected?.nativeSteer == true || !submission.attachments.isEmpty {
                let native = selected?.nativeSteer == true
                    && ChatCommandRules.canSteer(submission.text, attachments: !submission.attachments.isEmpty,
                                                  acceptsAttachments: nativeSteerAcceptsAttachments)
                queueBusyNote(submission, deliverAsSteer: native)
                return
            }
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

    private func queueBusyNote(_ submission: ChatDraftSubmission, deliverAsSteer: Bool = false) {
        guard let reference = submission.reference, let messageID = submission.messageID,
              submission.owns(reference: reference, conversationID: submission.conversationID,
                              peer: submission.peer, scope: WorkSessionContext.shared.scope),
              WorkCacheAccess.canSave(reference) else { return }
        let onScreen = currentReference == reference && selectionGeneration == submission.generation && ownsQueue
        var item = ChatQueuedMessage(id: messageID, text: submission.text, attachments: submission.attachments)
        item.sourceDraftText = submission.draftText
        item.expectedRevision = submission.expectedRevision
        do {
            let items = try ChatOutboxStore.shared.update(reference) { items in
                if let existing = items.first(where: { $0.id == item.id }) {
                    guard existing.text == item.text, existing.attachments == item.attachments else {
                        throw ChatOutboxStore.Failure.conflict
                    }
                    return
                }
                guard items.count < ChatOutboxStore.capacity else { throw ChatOutboxStore.Failure.full }
                items.append(item)
            }
            if let held = ChatDraftStore.shared.draft(for: reference),
               held.text == submission.draftText,
               held.attachments == submission.attachments {
                ChatDraftStore.shared.clear(held)
            }
            guard onScreen else { return }
            queued = items
            guard let stored = queued.first(where: { $0.id == messageID }), !stored.needsReceipt else {
                error = L10n.text("apple.chatmodel.check_delivery_in_pending_messages_before.af602276")
                return
            }
            authorizedQueueItems.insert(messageID)
            if draft == submission.draftText && attachments == submission.attachments {
                attachments = []
                attachmentPreviews = [:]
                missingDraftAttachments = []
                clearDraft()
            } else {
                ChatDraftStore.shared.save(text: draft, attachments: attachments, for: reference, newMessage: true)
            }
            Task {
                guard currentReference == reference, selectionGeneration == submission.generation else { return }
                if deliverAsSteer { _ = await deliverQueued(stored, stopCurrent: false, steerCurrent: true) }
                else { await drainQueue() }
            }
        } catch {
            self.error = L10n.text("apple.chatmodel.this_message_could_not_be_saved_to_the_que.342364f9")
        }
    }

    func deliverParkedSteerNow() async {
        guard savedCopy == nil, !isSharedSource else { return }
        if busy {
            error = L10n.text("apple.chatmodel.this_conversation_is_still_finishing_its_p.01b9e26a")
            return
        }
        guard let delivery = claimSteerDelivery() else { return }
        await performSteerDelivery(delivery)
        guard selectionMatches(id: selected?.id ?? "", generation: selectionGeneration) else { return }
        await drainQueue()
    }

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

    private func claimSteerDelivery() -> ChatSteerContext? {
        if isSharedSource || deliveringSteer != nil || clearingSteer != nil || sending || sendingNow || savedCopy != nil || busy { return nil }
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
            _ = await reloadOpenChats()
            guard current() else { return }
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

    func refreshSharingSource(reference: WorkReference, generation: UInt64, notice: String? = nil) async {
        guard currentReference == reference, selectionGeneration == generation else { return }
        let refreshed = await reloadOpenChats()
        guard currentReference == reference, selectionGeneration == generation else { return }
        if refreshed, !isSharedSource, let id = reference.itemID {
            if events.isEmpty { _ = await openEvents(id: id, generation: generation, quiet: true) }
            else { _ = await loadEvents(id: id, reset: false, generation: generation, quiet: true) }
        }
        guard currentReference == reference, selectionGeneration == generation else { return }
        sharingRecoveryNotice = notice
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

    var faceSeed: UInt64 {
        selected.map(faceSeed(for:)) ?? personaSeed(for: "chat")
    }

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

    func faceSeed(for chat: ChatConversation) -> UInt64 {
        if let personaID = chat.personaID,
           let persona = personas.first(where: { $0.id == personaID }) {
            return persona.seed
        }
        return personaSeed(for: chat.id)
    }

    var mostRecent: ChatConversation? {
        chats.max { lhs, rhs in lhs.updatedAtMs < rhs.updatedAtMs }
    }

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

    var turnUsage: ChatUsageSummary {
        let key = UsageKey(
            epoch: eventsEpoch,
            count: events.count,
            firstSeq: events.first?.seq,
            lastSeq: events.last?.seq,
            through: usageThrough,
            base: conversationUsage
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

    private struct UsageKey: Equatable {
        var epoch: UInt64
        var count: Int
        var firstSeq: UInt64?
        var lastSeq: UInt64?
        var through: UInt64?
        var base: ChatUsageTotals?
    }

    @ObservationIgnored private var turnUsageCache: ChatUsageSummary = .empty
    @ObservationIgnored private var turnUsageKey: UsageKey?

    var hasStarted: Bool {
        !events.isEmpty || selected?.resumeToken != nil
    }

    var displayItems: [ChatDisplayItem] {
        let pending = outgoing
        let coalesced = coalescedItems
        if pending.isEmpty { return coalesced }
        return coalesced + pending
    }

    @ObservationIgnored private(set) var rowsExtendedAtStart: Set<String> = []
    @ObservationIgnored private var displayOwner: UInt64?

    private var coalescedItems: [ChatDisplayItem] {
        _ = displayRevision
        return displayCache
    }

    @discardableResult
    private func publishEvents(id: String, generation: UInt64,
                               canPublish: () -> Bool = { true },
                               rebasesWindow: Bool = true, recordsChanged: Bool = true,
                               waitToCommit: (() async -> Bool)? = nil,
                               beforeCommit: (() -> Void)? = nil,
                               afterCommit: (() -> Void)? = nil,
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
            if let waitToCommit, displayCache != rows {
                guard await waitToCommit(), !Task.isCancelled,
                      selectionMatches(id: id, generation: generation), canPublish() else { return false }
            }
            guard rebasesWindow || eventsRevision == initialRevision else { return false }
            guard revision == eventsRevision, backend == selected?.backend,
                  running == (selected?.running == true) else { continue }
            let changesRows = displayCache != rows
            if let beforeCommit, changesRows { beforeCommit() }
            if recordsChanged { events = next }
            commitDisplay(rows)
            if let afterCommit, changesRows { afterCommit() }
            return true
        }
        return false
    }

    private func commitDisplay(_ projected: [ChatDisplayItem]) {
        let sameReader = displayOwner == selectionGeneration
        displayOwner = selectionGeneration
        let carried = ChatRowContinuity.carrying(projected, from: sameReader ? displayCache : [])
        let rows = carried.rows
        if !carried.extendedAtStart.isEmpty { rowsExtendedAtStart = carried.extendedAtStart }
        let nextKey = DisplayKey(epoch: eventsRevision, count: events.count,
            firstSeq: events.first?.seq, lastSeq: events.last?.seq,
            backend: selected?.backend, running: selected?.running == true)
        if displayKey != nextKey { displayRevision &+= 1 }
        displayKey = nextKey
        foldKey = nil
        hasRunningToolCacheKey = nil
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

    private struct FoldKey: Equatable {
        var display: DisplayKey?
        var detail: ChatDetail
        var open: Bool
        var toggled: Set<String>
    }

    @ObservationIgnored private var foldCache: [ChatDisplayItem] = []
    @ObservationIgnored private let foldContinuity = ChatFoldContinuity()
    @ObservationIgnored private var foldContinuityOwner: UInt64?
    @ObservationIgnored private var foldKey: FoldKey?

    @discardableResult
    private func stageOutgoing(_ text: String, steer: Bool = false) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = "outgoing-\(UUID().uuidString)"
        outgoing.append(ChatDisplayItem(isSteer: steer, id: id, kind: .user(trimmed)))
        outgoingWatermark[id] = events.compactMap(\.seq).max()
        return id
    }

    private func dropOutgoing(_ id: String?) {
        guard let id else { return }
        outgoing.removeAll { $0.id == id }
        outgoingWatermark.removeValue(forKey: id)
    }

    @ObservationIgnored private var outgoingWatermark: [String: UInt64?] = [:]

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
                if let seq = event.seq, let watermark { return seq > watermark }
                return true
            }
            let movedPast = userSeqs.contains { seq in
                guard let seq, let watermark else { return false }
                return seq > watermark
            }
            if matched || movedPast { outgoingWatermark.removeValue(forKey: item.id) }
            return matched || movedPast
        }
    }

    @ObservationIgnored private var eventsEpoch: UInt64 = 0
    @ObservationIgnored private var windowReplacementTicket: UUID?
    @ObservationIgnored private var liveWindowLoaded = false
    #if os(macOS)
    @ObservationIgnored private let openingRead = ChatOpeningRead<UInt64>()
    #endif

    private func beginWindowReplacement() -> UUID {
        let ticket = UUID()
        windowReplacementTicket = ticket
        eventsEpoch &+= 1
        return ticket
    }

    private func finishWindowReplacement(_ ticket: UUID) {
        if windowReplacementTicket == ticket { windowReplacementTicket = nil }
    }

    private func forgetWindow() {
        contextRevision = nil
        liveWindowLoaded = false
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
        hasPagedBack = false
        reachedStart = false
        historyTrimmed = false
    }

    @discardableResult
    private func openEvents(id: String, generation: UInt64, quiet: Bool = false) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        #if os(macOS)
        return await openingRead.run(owner: generation) { [weak self] in
            guard let self else { return false }
            return await self.readOpeningEvents(id: id, generation: generation, quiet: quiet)
        }
        #else
        return await readOpeningEvents(id: id, generation: generation, quiet: quiet)
        #endif
    }

    private func readOpeningEvents(id: String, generation: UInt64, quiet: Bool = false) async -> Bool {
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
            savedCopy = nil
            reconcileOutgoing()
            offset = page.nextOffset
            tailCursor = page.tailCursor
            earlierCursor = page.cursor
            hasPagedBack = false
            hasEarlier = ChatPaging.hasEarlier(page.hasEarlier, cursor: page.cursor)
            historyTrimmed = page.historyTrimmed
            conversationUsage = page.usage
            usageThrough = page.events.compactMap(\.seq).max()
            reachedStart = !page.hasEarlier && !page.events.isEmpty
            liveWindowLoaded = true
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
            return await loadEvents(id: id, reset: true, generation: generation, quiet: quiet)
        }
    }

    @discardableResult
    func loadEarlier(waitToPrepend: (() async -> Bool)? = nil, beforePrepend: (() -> Void)? = nil,
                     afterPrepend: (() -> Void)? = nil) async -> Bool {
        guard savedCopy == nil, !openingConversation, let selected else { return false }
        return await loadEarlier(id: selected.id, generation: selectionGeneration, quiet: false,
                          waitToPrepend: waitToPrepend, beforePrepend: beforePrepend, afterPrepend: afterPrepend)
    }

    private func loadEarlier(id: String, generation: UInt64, quiet: Bool,
                             waitToPrepend: (() async -> Bool)? = nil, beforePrepend: (() -> Void)? = nil,
                             afterPrepend: (() -> Void)? = nil) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        guard !pagingUnavailable, hasEarlier, !earlierInFlight,
              let cursor = earlierCursor
        else { return false }
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
                  requestedEpoch == eventsEpoch, cursor == earlierCursor else { return false }
            #if DEBUG
            TranscriptHoldTrace.note("earlier page reset=\(page.reset) got=\(page.events.count) seqs=\(page.events.first?.seq ?? 0)...\(page.events.last?.seq ?? 0) window=\(events.count) first=\(events.first?.seq ?? 0) last=\(events.last?.seq ?? 0)")
            defer { TranscriptHoldTrace.note("after page window=\(events.count) first=\(events.first?.seq ?? 0) last=\(events.last?.seq ?? 0) rows=\(displayItems.count)") }
            #endif
            if page.reset {
                let replacement = beginWindowReplacement()
                let replacementEpoch = eventsEpoch
                defer { finishWindowReplacement(replacement) }
                guard await publishEvents(id: id, generation: generation, canPublish: { replacementEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in page.events }) else { return false }
                reconcileOutgoing()
                offset = page.nextOffset
                tailCursor = page.tailCursor
                conversationUsage = page.usage
                usageThrough = page.events.compactMap(\.seq).max()
                warmMarkdown()
            } else {
                rowsExtendedAtStart = []
                guard await publishEvents(id: id, generation: generation, canPublish: {
                    requestedEpoch == self.eventsEpoch && cursor == self.earlierCursor
                }, waitToCommit: waitToPrepend, beforeCommit: beforePrepend,
                   afterCommit: afterPrepend, transform: { held in
                    let oldest = held.first?.seq ?? UInt64.max
                    let fresh = page.events.filter { ($0.seq ?? 0) < oldest }
                    return fresh + held
                }) else { return false }
                warmMarkdown()
            }
            earlierCursor = page.cursor
            hasPagedBack = !page.reset
            hasEarlier = ChatPaging.hasEarlier(page.hasEarlier, cursor: page.cursor, after: cursor)
            historyTrimmed = page.reset ? page.historyTrimmed : historyTrimmed || page.historyTrimmed
            if page.reset {
                reachedStart = !page.hasEarlier && !page.events.isEmpty
                restoreAfterReplacement = true
            } else if !page.hasEarlier {
                reachedStart = true
            }
            scheduleResponseAttachments(id: id, generation: generation)
            return !page.reset
        } catch {
            if !Task.isCancelled, selectionMatches(id: id, generation: generation),
               requestedEpoch == eventsEpoch, isUnknownMethod(error) {
                pagingUnavailable = true
                hasEarlier = false
            }
            return false
        }
    }

    private func isUnknownMethod(_ error: Error) -> Bool {
        if case let BridgeError.core(code, message) = error {
            return code == "unknown_method" || message.hasPrefix("unknown ")
        }
        return false
    }

    @discardableResult
    private func loadEvents(id: String, reset: Bool, generation: UInt64, quiet: Bool = false,
                            onFreshEvents: (([ChatTimelineEvent]) -> Void)? = nil,
                            onMoreEvents: ((Bool) -> Void)? = nil) async -> Bool {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return false }
        if !reset, !liveWindowLoaded {
            openingConversation = true
            defer { if selectionGeneration == generation { openingConversation = false } }
            return await openEvents(id: id, generation: generation, quiet: quiet)
        }
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
                #if os(macOS)
                guard !reset else { return false }
                #endif
                let opened = await openEvents(id: id, generation: generation, quiet: quiet)
                if opened, selectionMatches(id: id, generation: generation) {
                    if let reference = currentReference, let mark = ChatReadingStore.shared.mark(for: reference) {
                        ChatReadingStore.shared.request(mark, for: reference)
                    }
                    readingRestorationPulse &+= 1
                }
                return opened
            }
            if let requestedRevision { contextRevision = max(contextRevision ?? 0, requestedRevision) }
            if !reset, chunk.events.isEmpty, chunk.nextOffset == offset {
                tailCursor = chunk.tailCursor
                scheduleResponseAttachments(id: id, generation: generation)
                return true
            }
            if !reset { onFreshEvents?(chunk.events) }
            if reset {
                guard await publishEvents(id: id, generation: generation,
                    canPublish: { requestedEpoch == self.eventsEpoch }, rebasesWindow: false, transform: { _ in chunk.events }) else { return false }
                savedCopy = nil
                liveWindowLoaded = true
                earlierCursor = nil
                hasPagedBack = false
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
            onMoreEvents?(chunk.hasMore && chunk.nextOffset > requestedOffset)
            if let replacement { finishWindowReplacement(replacement) }
            settleNotifications()
            scheduleResponseAttachments(id: id, generation: generation)
            return true
        } catch {
            if !Task.isCancelled, !quiet, selectionMatches(id: id, generation: generation),
               requestedEpoch == eventsEpoch {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    private func keepOfflineCopy(id: String, title: String?, page: ChatEventPage, sendRevision: UInt64?) {
        guard let reference = currentReference, reference.itemID == id,
              !page.events.isEmpty || selected?.lastMessageAtMs == nil else { return }
        let title = title ?? L10n.text("apple.chatmodel.conversation.ccca1817")
        let backend = selected?.backend
        Task {
            await WorkCacheStore.shared.saveConversation(reference: reference, title: title, page: page, backend: backend, sendRevision: sendRevision)
        }
    }

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
        instructionsLoaded = true
        warmMarkdown()
        settleNotifications()
        if let id = selected?.id {
            let generation = selectionGeneration
            Task { scheduleResponseAttachments(id: id, generation: generation) }
        }
    }

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
        responseAttachmentFiles = [:]
        attachmentPreviews = [:]
        loadingResponseAttachments = []
        responseAttachmentErrors = [:]
        attemptedResponseAttachments.formUnion(events.compactMap { timeline in
            guard timeline.event?.kind == "attachment" else { return nil }
            return timeline.event?.id
        })
    }

    func downloadResponseAttachment(_ attachment: ChatAttachment) async {
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

    private var responseAttachmentDescriptors: [ChatAttachment] {
        if attachmentDescriptorRevision != eventsRevision {
            func descriptor(_ timeline: ChatTimelineEvent) -> ChatAttachment? {
                guard let event = timeline.event, event.kind == "attachment", let id = event.id else { return nil }
                return ChatAttachment(id: id, name: event.name ?? L10n.text("apple.chatmodel.attachment.040d2b36"),
                                      mediaType: event.mediaType, size: event.size)
            }
            let records = events
            if let scan = attachmentScan, scan.count > 0, records.count >= scan.count,
               scan.first != nil, records.first?.seq == scan.first, records[scan.count - 1].seq == scan.last {
                attachmentDescriptors += records[scan.count...].compactMap(descriptor)
            } else {
                attachmentDescriptors = records.compactMap(descriptor)
            }
            attachmentScan = (records.count, records.first?.seq, records.last?.seq)
            attachmentDescriptorRevision = eventsRevision
        }
        return attachmentDescriptors
    }

    private func loadResponseAttachments(id: String, generation: UInt64) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
        let descriptors = responseAttachmentDescriptors.filter { !attemptedResponseAttachments.contains($0.id) }
        for descriptor in descriptors {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation) else { return }
            await loadResponseAttachment(descriptor, id: id, generation: generation, userInitiated: false)
        }
    }

    private func loadResponseAttachment(
        _ attachment: ChatAttachment, id: String, generation: UInt64, userInitiated: Bool
    ) async {
        guard !Task.isCancelled, selectionMatches(id: id, generation: generation),
              responseAttachmentData[attachment.id] == nil, responseAttachmentFiles[attachment.id] == nil,
              !loadingResponseAttachments.contains(attachment.id),
              userInitiated || !attemptedResponseAttachments.contains(attachment.id)
        else { return }
        guard let previewReference = currentReference, WorkCacheAccess.canRead(previewReference) else { return }
        guard !userInitiated || !fileTransferInFlight else { return }
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
        if let cachedFile = await ChatAttachmentCache.shared.readFile(reference: previewReference, attachment: attachment.id, size: attachment.size) {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), currentReference == previewReference, WorkCacheAccess.canRead(previewReference), memoryGeneration == attachmentCacheGeneration else { return }
            responseAttachmentFiles[attachment.id] = cachedFile
            return
        }
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
              userInitiated || ChatAttachmentDownloadPolicy.permitsAutomaticDownload(
                size: attachment.size,
                isLocalImage: targetPeer == nil && attachment.mediaType?.hasPrefix("image/") == true,
                isImage: attachment.mediaType?.hasPrefix("image/") == true)
        else { return }
        do {
            let data: Data
            if await RemoteHostFeature.chatRecovery.isSupported(peer: targetPeer) {
                if userInitiated {
                    guard !fileTransferInFlight else {
                        attemptedResponseAttachments.remove(attachment.id)
                        return
                    }
                    fileTransferInFlight = true
                    fileTransferCancelled = false
                }
                defer {
                    if userInitiated { fileTransferName = nil; fileTransferInFlight = false }
                }
                let url = try await Bridge.downloadChatFile(id: id, attachmentID: attachment.id, peer: targetPeer,
                    confirmRelay: { [weak self] remaining in guard userInitiated else { return false }; return await self?.confirmFileRelay(name: attachment.name, size: attachment.size, remaining: remaining) ?? false },
                    progress: { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try await self.updateFileProgress(value, name: attachment.name, reference: previewReference, generation: generation, foreground: userInitiated)
                    })
                defer { try? FileManager.default.removeItem(at: url) }
                guard !Task.isCancelled, selectionMatches(id: id, generation: generation), currentReference == previewReference, WorkCacheAccess.canSave(previewReference), memoryGeneration == attachmentCacheGeneration else { return }
                let downloadedSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let downloadedSize, downloadedSize > 0 else { throw CocoaError(.fileReadCorruptFile) }
                if downloadedSize > ChatInbox.maxBytes {
                    let cached = try await ChatAttachmentCache.shared.writeFile(url, reference: previewReference, attachment: attachment.id, epoch: cacheEpoch)
                    guard !Task.isCancelled, selectionMatches(id: id, generation: generation),
                          currentReference == previewReference, WorkCacheAccess.canRead(previewReference),
                          memoryGeneration == attachmentCacheGeneration else { return }
                    responseAttachmentFiles[attachment.id] = cached
                    return
                }
                data = try await ChatFileIO.data(from: .file(url), maximum: ChatInbox.maxBytes)
            } else {
                let payload = try await Bridge.chatAttachment(id: id, attachmentID: attachment.id, peer: targetPeer, confirmRelay: { [weak self] in guard userInitiated else { return false }; return await self?.confirmFileRelay(name: attachment.name, size: attachment.size) ?? false })
                data = try await ChatFileIO.data(from: .base64(payload.data), maximum: ChatInbox.maxBytes)
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
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, selectionMatches(id: id, generation: generation), memoryGeneration == attachmentCacheGeneration,
                  currentReference == previewReference, WorkCacheAccess.canRead(previewReference) else { return }
            if case BridgeError.core(code: "file_transfer_busy", message: _) = error {
                attemptedResponseAttachments.remove(attachment.id)
                return
            }
            responseAttachmentErrors[attachment.id] = Self.downloadFailure(error)
        }
    }

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

    private func loadInstructions(id: String, generation: UInt64) async {
        guard !Task.isCancelled, savedCopy == nil,
              selectionMatches(id: id, generation: generation) else { return }
        instructionsLoaded = false
        do {
            let loaded = try await Bridge.chatInstructions(id: id, peer: peer)
            guard selectionMatches(id: id, generation: generation) else { return }
            instructions = loaded
        } catch {
            if selectionMatches(id: id, generation: generation) { instructions = nil }
        }
        if selectionMatches(id: id, generation: generation) { instructionsLoaded = true }
    }

    private func loadApprovals(id: String, generation: UInt64, quiet: Bool = false,
                               permitsPublication: () -> Bool = { true }) async {
        guard !Task.isCancelled, permitsPublication(), savedCopy == nil,
              selectionMatches(id: id, generation: generation) else { return }
        do {
            let loaded = try await Bridge.chatApprovals(id: id, peer: peer)
            guard !Task.isCancelled, permitsPublication(), selectionMatches(id: id, generation: generation) else { return }
            if approvals != loaded { approvals = loaded }
            approvalsLoaded = true
            settleNotifications()
        } catch {
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
        sharingRecoveryNotice = nil
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENSTAT_VIEWPORT_TRACE"] == "1" {
            let line = "chat-selection model=\(ObjectIdentifier(self)) cause=\(reason) chat=\(selected?.id ?? "none") workspace=\(workspaceID ?? "none") generation=\(selectionGeneration)->\(selectionGeneration &+ 1) events=\(events.count)"
            print(line)
            #if !os(macOS)
            ClientViewportTrace.append(line)
            #endif
        }
        #endif
        pollWatcher.cancel()
        #if os(macOS)
        openingRead.cancel()
        #endif
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
    }

    private func saveLaunchChoice(from chat: ChatConversation) {
        let choice = LaunchChoice(
            backend: chat.backend,
            model: chat.model,
            effort: chat.effort,
            mode: chat.mode,
            autonomy: chat.autonomy,
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

@MainActor @Observable
final class AgentUpdateNotice {
    static let shared = AgentUpdateNotice()
    var message: String?
    var severity: Banner.Severity = .info
}
