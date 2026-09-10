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
    var showWorkSearch = false
    /// The destination: a tab in tab mode, a sidebar row in sidebar mode.
    var destination: ClientTab = .home {
        didSet {
            if destination != oldValue {
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
                visibleTerminal = nil
                rememberedWorkspace = nil
                rememberedWorkspaceOwner = nil
            }
        }
    }
    func dismissRestoredRoute(generation: UInt64) {
        guard restoredRoute != nil, generation == restoredRouteGeneration else { return }
        restoredRoute = nil
    }

    var rememberedWorkspace: WorkReference?
    private var rememberedWorkspaceOwner: UUID?
    var visibleTerminal: WorkReference?
    var rememberedSection: WorkspaceSection?
    private let routeLaunch = WorkMobileRouteLaunch()
    private var restorationFinished = false

    func restoreRoute(visibleTabs: [ClientTab], notificationPending: Bool) {
        guard !restorationFinished, let scope = WorkSessionContext.shared.scope,
              scope.kind == .account else { return }
        restorationFinished = true
        guard !notificationPending, routeLaunch.claim(ticket: 0),
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
        if let chat = visibleChat, chat.scope == scope {
            return WorkMobileRoute(scope: scope, tab: destination.rawValue, reference: chat, section: "chat")
        }
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


    /// The folder open in the workspace plane, as `remote:<peer>:<id>`.
    var folderID: String? {
        didSet {
            if folderID != oldValue {
                restoredRoute = nil
                routeLaunch.navigationChanged()
            }
        }
    }

    /// Which of that folder's sections is showing. The sidebar lists them, so
    /// the detail column draws one section rather than the sections again.
    var section: WorkspaceSection = .sessions {
        didSet { if section != oldValue { restoredRoute = nil } }
    }

    /// Conversation a notification asked to open, consumed by the chat list
    /// once that folder is on screen.
    var requestedChat: WorkReference?

    /// The conversation the person is already in, as the folder thread or a
    /// Recents push. A notification tap for this id leaves that window as it
    /// is: locking the phone does not unmount it, and remounting blanks the
    /// transcript. The cover a tap presents is `presentedChat`, not this.
    var visibleChat: WorkReference? { didSet { if visibleChat != oldValue { routeLaunch.navigationChanged() } } }

    /// A chat opened from a notification on the tab layout, where there is
    /// no sidebar to land the folder in. Dismissing it returns where you were.
    var presentedChat: PresentedChat? { didSet { if presentedChat != oldValue { routeLaunch.navigationChanged() } } }

    /// True when this conversation is already on screen, so a tap should not
    /// open it again.
    func isShowing(peer: String, workspaceID: String, chatID: String) -> Bool {
        guard let target = reference(peer: peer, workspaceID: workspaceID, chatID: chatID) else { return false }
        return WorkDestinationResolver.sameConversation(presentedChat?.reference, target)
            || WorkDestinationResolver.sameConversation(visibleChat, target)
    }

    func reference(peer: String, workspaceID: String, chatID: String) -> WorkReference? {
        guard let scope = WorkSessionContext.shared.scope, scope.kind == .account,
              !peer.isEmpty, !workspaceID.isEmpty, !chatID.isEmpty else { return nil }
        return WorkReference(scope: scope, hostIdentity: peer, workspaceID: workspaceID,
                             kind: .conversation, itemID: chatID)
    }

    /// Remove the old account's entire navigation state before showing another.
    func reset() {
        restoredRoute = nil
        visibleTerminal = nil
        rememberedWorkspaceOwner = nil
        rememberedWorkspace = nil
        WorkMobileRouteStore.shared.clear()
        destination = .home
        folderID = nil
        section = .sessions
        requestedChat = nil
        visibleChat = nil
        presentedChat = nil
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
        restoredRoute = nil
        self.folderID = folderID
        self.section = section
        if folderID != nil { destination = .workspaces }
    }

    /// Folders pushed on the Workspaces tab's stack. `folderID` alone cannot
    /// do this: the tab layout observes the destination but not the folder,
    /// so a push needs its own road.
    var workspacesPath: [ClientFolderPush] = []

    /// Open a folder's section as a push on the Workspaces tab. New chat
    /// lands in that folder's chat, new session in its launcher.
    func pushFolder(peerKey: String, hostName: String, folder: WorkspaceFolder, section: WorkspaceSection) {
        workspacesPath.append(ClientFolderPush(peerKey: peerKey, hostName: hostName, folder: folder, section: section))
        destination = .workspaces
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
    func openChat(folderID: String, chatID: String) {
        guard !folderID.isEmpty, !chatID.isEmpty else { return }
        let route = WorkDestinationResolver.route(folderID: folderID)
        guard let peer = route.peer,
              let target = reference(peer: peer, workspaceID: route.workspaceID, chatID: chatID) else { return }
        let already = self.folderID == folderID && section == .chat
            && isShowing(peer: peer, workspaceID: route.workspaceID, chatID: chatID)
        self.folderID = folderID
        self.section = .chat
        self.destination = .workspaces
        if already { return }
        self.requestedChat = target
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
                hostName: hostName
            )
        case .sessions:
            ClientWorkspaceSessionsView(peer: peerKey, hostName: hostName, folder: folder)
        default:
            ClientWorkspaceDetailView(peer: peerKey, hostName: hostName, folder: folder)
        }
    }
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
