// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Where the person is, held above the layout rather than inside it.
///
/// The client can be drawn two ways (see `ClientLayoutMode`), and detaching a
/// keyboard swaps between them. The selection cannot live inside either shape
/// or the swap lands you on Home, which is the one thing that would make the
/// feature feel like a bug.
///
/// A scoped identifier route survives relaunch and layout changes. Restored
/// destinations resolve through Continue's availability flow, while active
/// folder models and pushed snapshots stay in memory only.
@MainActor
@Observable
final class ClientNavigationModel {
    let chatHandoff = ClientChatLayoutHandoff()
    var restoredChatReader: ClientChatLayoutHandoff.Reader?
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
        pushedChat = nil
        restoredChatReader = nil
        visibleChat = nil
        visibleChatOwner = nil
        visibleChatSessionKey = nil
    }

    /// Synchronous layout writes are presentation changes, not new intent.
    func restoreLayout(_ operation: () -> Void) {
        let previous = restoringLayout
        restoringLayout = true
        defer { restoringLayout = previous }
        operation()
    }

    /// Choosing a row/New/Fork inside a folder advances chat intent without
    /// dismissing the folder presentation that contains those controls.
    func chooseWithinChat(session: ClientChatSession, presentationID: UUID?) {
        let pushes = presentationID != nil && pushedChat?.id == presentationID ? pushedChats : []
        let fallback = restoredChatReader.flatMap { $0.session === session && $0.key.conversation == nil ? $0 : nil }
        chooseNavigation()
        pushedChats = pushes
        restoredChatReader = fallback
    }
    var showWorkSearch = false
    var ecosystemSearchTerm = ""

    /// A screen or setting search picked, held until search has closed.
    ///
    /// Two sheets presented from one view queue rather than stack, so a result
    /// that opens the account sheet has to wait for search to go, or the
    /// account never appears. `ClientRootView` delivers this on dismissal.
    var pendingPlace: ClientAppDestination?

    /// Where the account sheet should land, when something outside it asked
    /// for a setting by name. Consumed once, by the sheet.
    var accountRequest: ClientAccountRequest?

    /// Home's editor was asked for from elsewhere. Home opens it and clears
    /// this.
    var homeEditorRequested = false
    /// Workspaces' section editor, same pattern as Home.
    var workspacesEditorRequested = false
    /// The destination: a tab in tab mode, a sidebar row in sidebar mode.
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
        // A presented conversation is above the underlying terminal or folder,
        // whose disappearance may arrive after the app saves its background route.
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
        if let restoredRoute, restoredRoute.scope == scope,
           restoredChatReader?.matches(restoredRoute) == true { return restoredRoute }
        if let folder = rememberedWorkspace, folder.scope == scope {
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


    /// Expansion is independent of the detail destination. Visiting Home or
    /// Devices must not fold the workspace tree, including after a split reset.
    private(set) var sidebarFolderID: String?

    /// The folder open in the workspace plane, as `remote:<peer>:<id>`.
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

    /// Which project section the strip above the content is showing.
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
    }

    /// Conversation a notification asked to open, consumed by the chat list
    /// once that folder is on screen.
    private(set) var requestedChatGeneration: UInt64 = 0
    var requestedChat: WorkReference? {
        didSet {
            requestedChatGeneration &+= 1
            if requestedChat != nil { chooseNavigation() }
        }
    }
    var projectChatAction: ClientProjectChatAction?

    /// The conversation the person is already in, as the folder thread or a
    /// Recents push. A notification tap for this id leaves that window as it
    /// is: locking the phone does not unmount it, and remounting blanks the
    /// transcript. The cover a tap presents is `presentedChat`, not this.
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
    }

    /// Back from a retained folder fallback still lands on that folder's list.
    /// Its destination identifiers become workspace identifiers, not the chat
    /// that was just closed; a later fold cannot reopen that conversation.
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

    /// A chat opened from a notification on the tab layout, where there is
    /// no sidebar to land the folder in. Dismissing it returns where you were.
    var presentedChat: PresentedChat? { didSet { if presentedChat != oldValue { chatHandoff.suspend(); routeLaunch.navigationChanged() } } }
    var presentedTaskBoard: PresentedTaskBoard?

    /// True when this conversation is already on screen, so a tap should not
    /// open it again.
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

    /// Remove the old account's entire navigation state before showing another.
    func reset() {
        chooseNavigation()
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
        workspacesPath = []
    }

    /// A first task, offered to the composer of the next chat that opens.
    ///
    /// Text, never a sent message. Setup ends by handing somebody a project and
    /// something to type into it, and a prompt may cost money, so the send stays
    /// theirs. Consumed once by the chat that picks it up: coming back to that
    /// folder later must not refill an emptied composer. Scoped to the folder
    /// setup opened, so any other chat that mounts first cannot consume it.
    var suggestedPrompt: (folderID: String, text: String)?

    /// Take the offered first task for this folder, if there is one. Reading it
    /// clears it, and a folder that does not match leaves it for its own chat.
    func takeSuggestedPrompt(for folderID: String) -> String? {
        guard let offered = suggestedPrompt, offered.folderID == folderID else { return nil }
        suggestedPrompt = nil
        return offered.text
    }

    /// Compatibility for callers that do not scope. Prefer
    /// `takeSuggestedPrompt(for:)`; this consumes whatever is held.
    func takeSuggestedPrompt() -> String? {
        defer { suggestedPrompt = nil }
        return suggestedPrompt?.text
    }

    /// The machine Devices should be showing, when something outside that tab
    /// asked for it.
    ///
    /// A machine id rather than a `Machine`, because the account list is
    /// reloaded underneath and the row that opened this may not be the same
    /// value by the time the push happens. `ClientDevicesView` clears it when
    /// the push ends, so returning to Devices later lands on the list.
    var deviceMachineID: String?

    /// Selecting a folder implies the workspace plane, so both move together.
    func open(folderID: String?, section: WorkspaceSection = .sessions) {
        chooseNavigation()
        projectOpenGeneration &+= 1
        requestedChat = nil
        restoredRoute = nil
        self.folderID = folderID
        self.section = section
        if folderID != nil { destination = .workspaces }
    }

    /// Folders pushed on the Workspaces tab's stack. `folderID` alone cannot
    /// do this: the tab layout observes the destination but not the folder,
    /// so a push needs its own road.
    var workspacesPath: [ClientFolderPush] = []

    func updateWorkspacesPath(_ path: [ClientFolderPush], layout: UInt64) {
        guard layout == stackGeneration, path != workspacesPath else { return }
        chooseNavigation()
        workspacesPath = path
    }

    /// Open a folder's section as a push on the Workspaces tab. New chat
    /// lands in that folder's chat, new session in its launcher.
    func pushFolder(peerKey: String, hostName: String, folder: WorkspaceFolder, section: WorkspaceSection,
                    restoringLayout: Bool = false) {
        let push = {
            self.chooseNavigation()
            self.workspacesPath.append(ClientFolderPush(peerKey: peerKey, hostName: hostName, folder: folder, section: section))
            self.destination = .workspaces
        }
        if restoringLayout { restoreLayout(push) } else { push() }
    }

    /// Show one machine on Devices, from anywhere.
    ///
    /// Workspaces lists the same computers it can reach, and the readings on
    /// that row are a summary of a screen that already exists. Tapping the row
    /// goes there rather than growing a second device screen inside
    /// Workspaces.
    func openDevice(machineID: String?) {
        guard let machineID, !machineID.isEmpty else { return }
        deviceMachineID = machineID
        destination = .machines
    }

    /// Open this conversation in its folder's chat section.
    ///
    /// If that thread is already the one on screen, only the destination
    /// moves. Setting `requestedChat` again would re-select it and blank the
    /// transcript.
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

/// One folder's section, pushed on the Workspaces tab's stack.
///
/// Identity is the folder, not its snapshot: equality and hashing use only
/// peer, folder id and section, so a folder refresh that changes its name,
/// branch or counts neither duplicates the entry nor breaks pop semantics.
/// The held `folder` is the push-time snapshot for the destination's initial
/// draw; detail screens reload on appear.
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
            ClientWorkspaceDetailView(peer: peerKey, hostName: hostName, folder: folder)
        }
    }
}

/// Kept above tab/sidebar layouts so the host-wide board stays open on resize.
struct PresentedTaskBoard: Identifiable, Equatable {
    var id: String { peer }
    let peer: String
    let hostName: String
}

/// Enough to open one thread from a notification without keeping a folder
/// model around. The ids are host-local and arrived over the tunnel, not
/// on the push.
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
