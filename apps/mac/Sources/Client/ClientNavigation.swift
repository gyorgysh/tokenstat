// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

struct ClientPullHandoff {
    let id: UUID
    var owner: UUID
    let reference: WorkReference
    let sessionGeneration: UInt64
    let availability: PullAvailability?
    let summary: PullSummary
    let model: PullDetailModel
    let listScope: PullScope
    let listState: PullStateFilter
}

@MainActor
@Observable
final class ClientNavigationModel {
    let chatHandoff = ClientChatLayoutHandoff()
    var pullHandoff: ClientPullHandoff?
    private(set) var chatSwitchInProgress = false
    var restoredChatReader: ClientChatLayoutHandoff.Reader?
    var sidebarVisible = true
    var sidebarLayoutActive = true
    var sidebarChatReconciled = false
    var sidebarCollapsedForChat = false
    @ObservationIgnored private var restoringLayout = false

    struct ChatActionTicket {
        let scope: WorkReference.Scope?
        let intent: UInt64
        let layout: UInt64
    }

    func chatActionTicket() -> ChatActionTicket {
        ChatActionTicket(scope: WorkSessionContext.shared.scope,
            intent: chatHandoff.intent, layout: stackGeneration)
    }

    func acceptsChatAction(_ ticket: ChatActionTicket) -> Bool {
        ticket.scope != nil && ticket.scope == WorkSessionContext.shared.scope
            && ticket.intent == chatHandoff.intent && ticket.layout == stackGeneration
    }

    func chooseNavigation() {
        guard !restoringLayout else { return }
        chatHandoff.navigate()
        chatSwitchInProgress = false
        pullHandoff = nil
        showingNewChat = false
        newChatDraft.retire()
        pushedChat = nil
        restoredChatReader = nil
        visibleChat = nil
        visibleChatOwner = nil
        visibleChatSessionKey = nil
    }

    func restoreLayout(_ operation: () -> Void) {
        let previous = restoringLayout
        restoringLayout = true
        defer { restoringLayout = previous }
        operation()
    }

    func chooseWithinChat(session: ClientChatSession, presentationID: UUID?, preserveChatSpace: Bool = false) {
        let pushes = presentationID != nil && pushedChat?.id == presentationID ? pushedChats : []
        let fallback = restoredChatReader.flatMap { $0.session === session && $0.key.conversation == nil ? $0 : nil }
        chooseNavigation()
        chatSwitchInProgress = preserveChatSpace
        pushedChats = pushes
        restoredChatReader = fallback
    }
    var showingNewChat = false
    let newChatDraft = ChatStartDraft()
    var requestedNewChatRepositoryID: String?
    var requestedNewChatHostKey: String?
    func openNewChat(repositoryID: String? = nil, hostPeer: String? = nil) {
        requestedNewChatRepositoryID = repositoryID
        requestedNewChatHostKey = hostPeer
        newChatDraft.activate(scope: WorkSessionContext.shared.scope,
                              session: WorkSessionContext.shared.generation, repositoryID: repositoryID)
        showingNewChat = true
    }

    enum NewChatRequest: Hashable {
        case machineSetup
    }

    var pendingNewChatRequest: NewChatRequest?

    var showWorkSearch = false
    var ecosystemSearchTerm = ""

    var pendingPlace: ClientAppDestination?

    var accountRequest: ClientAccountRequest?

    var homeEditorRequested = false
    var workspacesEditorRequested = false
    var destination: ClientTab = .home {
        didSet {
            if destination != oldValue {
                chooseNavigation()
                restoredRoute = nil
                routeLaunch.navigationChanged()
            }
        }
    }
    private(set) var restoredRouteGeneration: UInt64 = 0
    var restoredRoute: WorkMobileRoute? {
        didSet {
            if restoredRoute != nil || oldValue != nil { restoredRouteGeneration &+= 1 }
            if restoredRoute != nil && restoredRoute != oldValue {
                visibleChat = nil
                visibleChatOwner = nil
                visibleChatSessionKey = nil
                visibleTerminal = nil
                rememberedWorkspace = nil
                rememberedWorkspaceOwner = nil
            }
        }
    }
    func dismissRestoredRoute(generation: UInt64) {
        guard restoredRoute != nil, generation == restoredRouteGeneration else { return }
        chooseNavigation()
        restoredRoute = nil
    }

    var rememberedWorkspace: WorkReference?
    private var rememberedWorkspaceOwner: UUID?
    private(set) var visibleTerminal: WorkReference? {
        didSet { if visibleTerminal == nil { visibleTerminalOwner = nil } }
    }
    @ObservationIgnored private var visibleTerminalOwner: String?
    var rememberedSection: WorkspaceSection?
    private let routeLaunch = WorkMobileRouteLaunch()
    private var restorationFinished = false

    func restoreRoute(visibleTabs: [ClientTab], notificationPending: Bool) {
        guard !restorationFinished, let scope = WorkSessionContext.shared.scope,
              scope.kind == .account else { return }
        restorationFinished = true
        guard LaunchPreferences.restoresLocation, !notificationPending, routeLaunch.claim(ticket: 0),
              let route = WorkMobileRouteStore.shared.route(for: scope) else { return }
        let tab = ClientTab(rawValue: route.tab) ?? .home
        destination = visibleTabs.contains(tab) ? tab : (visibleTabs.first ?? .home)
        if route.reference != nil { restoredRoute = route }
    }

    var currentRoute: WorkMobileRoute? {
        guard let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return nil }
        if let chat = presentedChat?.reference, chat.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue, reference: chat, section: "chat")
        }
        if let terminal = visibleTerminal, terminal.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue,
                                   reference: terminal, section: "sessions")
        }
        if let reader = chatHandoff.reader, reader.reference.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue,
                reference: reader.reference, section: "chat")
        }
        if let chat = visibleChat, chat.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue, reference: chat, section: "chat")
        }
        if let pull = pullHandoff, pull.reference.scope == scope,
           pull.sessionGeneration == WorkSessionContext.shared.generation {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue, reference: pull.reference, section: "pulls")
        }
        if let restoredRoute, restoredRoute.scope == scope,
           restoredChatReader?.matches(restoredRoute) == true { return restoredRoute }
        if destination == .workspaces,
           let folder = rememberedWorkspace, folder.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue,
                                   reference: folder, section: rememberedSection?.rawValue)
        }
        if let restoredRoute, restoredRoute.scope == scope { return restoredRoute }
        return WorkMobileRoute(scope: scope, tab: destination.rawValue)
    }

    func saveRoute() {
        guard restorationFinished, let route = currentRoute else { return }
        WorkMobileRouteStore.shared.save(route)
    }

    func rememberWorkspace(peer: String, workspaceID: String, section: WorkspaceSection?, owner: UUID) {
        guard let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        rememberedWorkspaceOwner = owner
        rememberedWorkspace = WorkReference(scope: scope, hostIdentity: peer,
            workspaceID: workspaceID, kind: .workspace, itemID: nil)
        rememberedSection = section
    }

    func leaveWorkspace(owner: UUID) {
        guard rememberedWorkspaceOwner == owner else { return }
        rememberedWorkspaceOwner = nil
        rememberedWorkspace = nil
    }

    func showTerminal(_ reference: WorkReference, owner: String) {
        guard reference.scope == WorkSessionContext.shared.scope, reference.kind == .terminal else { return }
        visibleTerminalOwner = owner
        visibleTerminal = reference
    }

    func leaveTerminal(owner: String) {
        guard visibleTerminalOwner == owner else { return }
        visibleTerminal = nil
    }


    private(set) var sidebarFolderID: String?

    var folderID: String? {
        didSet {
            if let folderID { sidebarFolderID = folderID }
            if folderID != oldValue {
                chooseNavigation()
                restoredRoute = nil
                routeLaunch.navigationChanged()
            }
        }
    }

    var section: WorkspaceSection = .sessions {
        didSet { if section != oldValue { chooseNavigation(); restoredRoute = nil } }
    }
    var projectSections: [ClientProjectChats.Key: WorkspaceSection] = [:]
    private(set) var projectOpenGeneration: UInt64 = 0
    var layoutGeneration: UInt64 = 0
    var stackGeneration: UInt64 = 0
    private(set) var pushedChatGeneration: UInt64 = 0
    private(set) var pushedChats: [ClientOwnedPush] = [] {
        didSet { pushedChatGeneration &+= 1 }
    }
    var pushedChat: ClientOwnedPush? {
        get { pushedChats.last }
        set { pushedChats = newValue.map { [$0] } ?? [] }
    }

    func pushOwned(_ push: ClientOwnedPush, from parent: UUID?) {
        let prefix: [ClientOwnedPush]
        if let parent, let index = pushedChats.firstIndex(where: { $0.id == parent }) {
            prefix = Array(pushedChats.prefix(index + 1))
        } else { prefix = [] }
        let fallback: ClientChatLayoutHandoff.Reader? = restoredChatReader.flatMap { reader in
            guard let parent, let route = restoredRoute, reader.matches(route),
                  !prefix.isEmpty || parent == (reader.presentationID ?? reader.id) else { return nil }
            return reader
        }
        chooseNavigation()
        restoredChatReader = fallback
        if prefix.isEmpty && fallback == nil { restoredRoute = nil }
        pushedChats = prefix + [push]
    }

    func dismissPushedChat(generation: UInt64, layout: UInt64, depth: Int = 0) {
        guard pushedChats.indices.contains(depth), generation == pushedChatGeneration,
              layout == stackGeneration else { return }
        let prefix = Array(pushedChats.prefix(depth))
        let fallback = restoredChatReader
        chooseNavigation()
        restoredChatReader = fallback
        pushedChats = prefix
        if prefix.isEmpty && fallback == nil { restoredRoute = nil }
    }

    private(set) var requestedChatGeneration: UInt64 = 0
    var requestedChat: WorkReference? {
        didSet {
            requestedChatGeneration &+= 1
            if requestedChat != nil { chooseNavigation() }
        }
    }
    var projectChatAction: ClientProjectChatAction?

    var visibleChat: WorkReference? { didSet { if visibleChat != oldValue { routeLaunch.navigationChanged() } } }
    @ObservationIgnored private var visibleChatOwner: UUID?
    private(set) var visibleChatSessionKey: ClientChatSessions.Key?

    func showChat(_ reference: WorkReference?, owner: UUID, sessionKey: ClientChatSessions.Key,
                  session: ClientChatSession, folderName: String, hostName: String,
                  presentationID: UUID?, intent: UInt64, handoffID: UUID?, layout: UInt64) {
        guard layout == stackGeneration, let reference, reference.scope == WorkSessionContext.shared.scope,
              chatHandoff.show(session: session, key: sessionKey, reference: reference, owner: owner,
                folderName: folderName, hostName: hostName, presentationID: presentationID,
                intent: intent, handoffID: handoffID) else { return }
        visibleChat = reference
        visibleChatOwner = owner
        visibleChatSessionKey = sessionKey
    }

    func leaveChat(owner: UUID) {
        guard visibleChatOwner == owner else { return }
        visibleChatOwner = nil
        visibleChat = nil
        visibleChatSessionKey = nil
        chatSwitchInProgress = false
    }

    func leaveThread(session: ClientChatSession, presentationID: UUID? = nil) {
        let fallback = restoredChatReader.flatMap { reader in
            reader.session === session && reader.key.conversation == nil ? reader : nil
        }
        chooseWithinChat(session: session, presentationID: presentationID)
        if let fallback {
            restoredChatReader = fallback
            let reference = WorkReference(scope: fallback.reference.scope, hostIdentity: fallback.key.peer,
                workspaceID: fallback.key.workspace, kind: .workspace, itemID: nil)
            restoredRoute = WorkMobileRoute(scope: reference.scope, tab: destination.rawValue,
                reference: reference, section: "chat")
        }
    }

    var presentedChat: PresentedChat? { didSet { if presentedChat != oldValue { chatHandoff.suspend(); routeLaunch.navigationChanged() } } }
    var presentedTaskBoard: PresentedTaskBoard?

    func isShowing(peer: String, workspaceID: String, chatID: String) -> Bool {
        guard let target = reference(peer: peer, workspaceID: workspaceID, chatID: chatID) else { return false }
        return WorkDestinationResolver.sameConversation(presentedChat?.reference, target)
            || WorkDestinationResolver.sameConversation(visibleChat, target)
            || (presentedChat == nil && WorkDestinationResolver.sameConversation(chatHandoff.reader?.reference, target))
    }

    func reference(peer: String, workspaceID: String, chatID: String) -> WorkReference? {
        guard let scope = WorkSessionContext.shared.scope, scope.kind == .account,
              !peer.isEmpty, !workspaceID.isEmpty, !chatID.isEmpty else { return nil }
        return WorkReference(scope: scope, hostIdentity: peer, workspaceID: workspaceID,
                             kind: .conversation, itemID: chatID)
    }

    func reset() {
        chooseNavigation()
        sidebarVisible = true
        sidebarLayoutActive = true
        sidebarChatReconciled = false
        sidebarCollapsedForChat = false
        pendingPlace = nil
        accountRequest = nil
        homeEditorRequested = false
        workspacesEditorRequested = false
        restoredRoute = nil
        visibleTerminal = nil
        rememberedWorkspaceOwner = nil
        rememberedWorkspace = nil
        WorkMobileRouteStore.shared.clear()
        destination = .home
        folderID = nil
        sidebarFolderID = nil
        section = .sessions
        projectSections = [:]
        requestedChat = nil
        projectChatAction = nil
        visibleChat = nil
        visibleChatOwner = nil
        visibleChatSessionKey = nil
        presentedChat = nil
        presentedTaskBoard = nil
        suggestedPrompt = nil
        deviceMachineID = nil
        workspacesDeviceMachineID = nil
        workspacesPath = []
    }

    var suggestedPrompt: (folderID: String, text: String)?

    func takeSuggestedPrompt(for folderID: String) -> String? {
        guard let offered = suggestedPrompt, offered.folderID == folderID else { return nil }
        suggestedPrompt = nil
        return offered.text
    }

    func takeSuggestedPrompt() -> String? {
        defer { suggestedPrompt = nil }
        return suggestedPrompt?.text
    }

    var deviceMachineID: String?
    var workspacesDeviceMachineID: String?

    func open(folderID: String?, section: WorkspaceSection = .sessions) {
        chooseNavigation()
        projectOpenGeneration &+= 1
        requestedChat = nil
        restoredRoute = nil
        self.folderID = folderID
        self.section = section
        if folderID != nil { destination = .workspaces }
    }

    var workspacesPath: [ClientFolderPush] = []

    func updateWorkspacesPath(_ path: [ClientFolderPush], layout: UInt64) {
        guard layout == stackGeneration, path != workspacesPath else { return }
        chooseNavigation()
        workspacesPath = path
    }

    func pushFolder(peerKey: String, hostName: String, folder: WorkspaceFolder, section: WorkspaceSection,
                    restoringLayout: Bool = false) {
        let push = {
            self.chooseNavigation()
            self.workspacesPath.append(ClientFolderPush(peerKey: peerKey, hostName: hostName, folder: folder, section: section))
            self.destination = .workspaces
        }
        if restoringLayout { restoreLayout(push) } else { push() }
    }

    func openDevice(machineID: String?) {
        guard let machineID, !machineID.isEmpty else { return }
        deviceMachineID = machineID
        destination = .machines
    }

    func openWorkspaceDevice(machineID: String?) {
        guard let machineID, !machineID.isEmpty else { return }
        workspacesDeviceMachineID = machineID
        destination = .workspaces
    }

    func openChat(folderID: String, chatID: String, restoringLayout: Bool = false) {
        guard !folderID.isEmpty, !chatID.isEmpty else { return }
        let route = WorkDestinationResolver.route(folderID: folderID)
        guard let peer = route.peer,
              let target = reference(peer: peer, workspaceID: route.workspaceID, chatID: chatID) else { return }
        let already = self.folderID == folderID && section == .chat
            && isShowing(peer: peer, workspaceID: route.workspaceID, chatID: chatID)
        let open = {
            if !restoringLayout { self.chooseNavigation(); self.projectOpenGeneration &+= 1 }
            self.folderID = folderID
            self.section = .chat
            self.destination = .workspaces
            if !already { self.requestedChat = target }
        }
        if restoringLayout { restoreLayout(open) } else { open() }
    }
}

struct ClientFolderPush: Hashable {
    let peerKey: String
    let hostName: String
    let folder: WorkspaceFolder
    let section: WorkspaceSection

    static func == (lhs: ClientFolderPush, rhs: ClientFolderPush) -> Bool {
        lhs.peerKey == rhs.peerKey
            && lhs.folder.id == rhs.folder.id
            && lhs.section == rhs.section
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(peerKey)
        hasher.combine(folder.id)
        hasher.combine(section)
    }

    @ViewBuilder
    var destination: some View {
        switch section {
        case .chat:
            ClientChatView(
                peer: peerKey,
                workspaceID: ClientRemote.rawWorkspaceID(of: folder) ?? folder.id,
                folderName: folder.name,
                hostName: hostName,
                folder: folder
            )
        case .sessions:
            ClientWorkspaceSessionsView(peer: peerKey, hostName: hostName, folder: folder)
        default:
            ClientWorkspaceSectionDetail(peer: peerKey, hostName: hostName, folder: folder, section: section)
        }
    }
}

struct PresentedTaskBoard: Identifiable, Equatable {
    var id: String { peer }
    let peer: String
    let hostName: String
}

struct PresentedChat: Identifiable, Equatable {
    var id: WorkReference { reference }
    let scope: WorkReference.Scope
    var reference: WorkReference {
        WorkReference(scope: scope, hostIdentity: peer, workspaceID: workspaceID,
                      kind: .conversation, itemID: chatID)
    }
    var peer: String
    var workspaceID: String
    var folderName: String
    var hostName: String
    var chatID: String
}

#endif
