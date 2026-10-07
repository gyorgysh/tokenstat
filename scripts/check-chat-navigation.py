#!/usr/bin/env python3
"""Compile the production mobile navigation/coordinator on Mac with UI value stubs.

No app, network, credential, or user-default mutation. SwiftUI view bodies are
covered by source guards and the separate simulator build/native tests.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'apps/mac/Sources'
nav = (sources / 'Client/ClientNavigation.swift').read_text()
nav_class = nav[nav.index('@MainActor\n@Observable\nfinal class ClientNavigationModel'):nav.index('/// One folder\'s section, pushed')]
presented = nav[nav.index('struct PresentedTaskBoard:'):nav.rindex('#endif')]
model_stub = (root / 'scripts/tests/ClientChatSessionTests.swift').read_text().split('@main\n')[0]
stubs = '''
enum ClientTab: String { case home, workspaces, insights, machines, ssh }
enum WorkspaceSection: String { case sessions, chat, changes }
struct ClientAppDestination {}
struct ClientAccountRequest {}
struct ClientProjectChatAction {}
struct ClientOwnedPush: Identifiable { let id: UUID }
struct WorkspaceFolder: Hashable { let id: String; var name: String = "P" }
struct ClientFolderPush: Hashable {
    let peerKey: String; let hostName: String; let folder: WorkspaceFolder; let section: WorkspaceSection
}
struct ClientProjectChats { struct Key: Hashable { let peer: String; let workspace: String } }
enum LaunchPreferences { static let restoresLocation = false }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
}
enum WorkDestinationResolver {
    static func sameConversation(_ a: WorkReference?, _ b: WorkReference?) -> Bool {
        guard let a, let b else { return false }
        return a.scope == b.scope && a.kind == b.kind && a.hostIdentity == b.hostIdentity
            && a.workspaceID == b.workspaceID && a.itemID == b.itemID
    }
    static func route(folderID: String) -> (peer: String?, workspaceID: String) {
        let parts = folderID.split(separator: ":", maxSplits: 2).map(String.init)
        return parts.count == 3 ? (parts[1], parts[2]) : (nil, folderID)
    }
}
'''
tests = '''
@main struct NavigationChecks {
    @MainActor static func main() {
        let scope = WorkReference.Scope.account(origin: "https://test.example", handle: "alice")!
        WorkSessionContext.shared.scope = scope
        let nav = ClientNavigationModel()
        nav.destination = .workspaces
        let session = ClientChatSession(), owner = UUID(), push = UUID()
        let b = WorkReference(scope: scope, hostIdentity: "mac", workspaceID: "p", kind: .conversation, itemID: "b")
        let key = ClientChatSessions.Key(peer: "mac", workspace: "p", conversation: "b")
        session.model.selected = ChatConversation(id: "b")
        session.model.currentReference = b
        session.model.selectionGeneration = 3
        nav.chooseNavigation()
        let initialIntent = nav.chatHandoff.intent
        nav.showChat(b, owner: owner, sessionKey: key, session: session, folderName: "P", hostName: "Mac",
            presentationID: push, intent: initialIntent, handoffID: nil, layout: 0)
        precondition(nav.visibleChat == b && nav.currentRoute?.reference == b)
        let route = nav.currentRoute!
        let delivery = nav.chatHandoff.begin(route: route)!
        nav.restoreLayout {
            nav.folderID = "remote:mac:p"
            nav.section = .chat
            nav.requestedChat = b
            nav.pushFolder(peerKey: "mac", hostName: "Mac", folder: WorkspaceFolder(id: "p"),
                section: .chat, restoringLayout: true)
            nav.restoredRoute = route
        }
        precondition(nav.chatHandoff.intent == initialIntent && nav.chatHandoff.isCurrent(delivery, scope: scope))
        precondition(nav.visibleChat == nil && nav.visibleChatSessionKey == nil)
        let request = nav.requestedChatGeneration
        nav.requestedChat = nil
        precondition(nav.chatHandoff.intent == initialIntent && nav.requestedChatGeneration != request)
        nav.showChat(b, owner: owner, sessionKey: key, session: session, folderName: "P", hostName: "Mac",
            presentationID: push, intent: initialIntent, handoffID: delivery.id, layout: 0)
        precondition(nav.visibleChat == b && nav.chatHandoff.pending == nil)

        nav.presentedChat = PresentedChat(scope: scope, peer: "mac", workspaceID: "p",
            folderName: "P", hostName: "Mac", chatID: "c")
        nav.leaveChat(owner: owner)
        precondition(nav.currentRoute?.reference?.itemID == "c" && nav.chatHandoff.reader?.session === session)
        nav.presentedChat = nil
        precondition(nav.visibleChat == nil && nav.isShowing(peer: "mac", workspaceID: "p", chatID: "b"))
        precondition(nav.currentRoute?.reference == b)
        let afterCover = nav.chatHandoff.begin(route: nav.currentRoute!)!
        precondition(nav.chatHandoff.isCurrent(afterCover, scope: scope))
        nav.showChat(b, owner: UUID(), sessionKey: key, session: session, folderName: "P", hostName: "Mac",
            presentationID: push, intent: initialIntent, handoffID: nil, layout: 0)
        precondition(nav.visibleChat == nil, "old presentation intent cannot republish after cover suspension")

        nav.stackGeneration = 2
        let path = nav.workspacesPath
        let beforeOldPath = nav.chatHandoff.intent
        nav.updateWorkspacesPath([], layout: 1)
        precondition(nav.workspacesPath == path && nav.chatHandoff.intent == beforeOldPath)
        nav.updateWorkspacesPath([], layout: 2)
        precondition(nav.chatHandoff.reader == nil && nav.chatHandoff.pending == nil)

        // The actual root navigation state keeps the destination after origin removal.
        var pinnedOrigin: UUID? = UUID()
        nav.pushOwned(ClientOwnedPush(id: pinnedOrigin!), from: nil)
        let target = nav.pushedChat!.id
        let staleGeneration = nav.pushedChatGeneration
        pinnedOrigin = nil
        precondition(nav.pushedChat?.id == target)
        nav.pushOwned(ClientOwnedPush(id: UUID()), from: nil)
        nav.dismissPushedChat(generation: staleGeneration, layout: 2)
        precondition(nav.pushedChat != nil, "predecessor dismissal cannot close successor")
        let currentGeneration = nav.pushedChatGeneration
        nav.dismissPushedChat(generation: currentGeneration, layout: 1)
        precondition(nav.pushedChat != nil, "obsolete stack dismissal is passive")
        nav.dismissPushedChat(generation: currentGeneration, layout: 2)
        precondition(nav.pushedChat == nil && nav.chatHandoff.reader == nil)
        precondition(nav.chatHandoff.begin(route: route) == nil, "Back then fold does not reopen")
        // Continue workspace -> launcher chat -> system Back returns to workspace.
        let project = UUID(), chat = UUID()
        nav.pushOwned(ClientOwnedPush(id: project), from: nil)
        nav.pushOwned(ClientOwnedPush(id: chat), from: project)
        precondition(nav.pushedChats.map(\\.id) == [project, chat])
        nav.chooseWithinChat(session: session, presentationID: chat)
        precondition(nav.pushedChats.map(\\.id) == [project, chat], "row/New/Fork keeps its containing destination")
        nav.leaveThread(session: session, presentationID: chat)
        precondition(nav.pushedChats.map(\\.id) == [project, chat], "list Back is in place")
        let nestedGeneration = nav.pushedChatGeneration
        nav.dismissPushedChat(generation: nestedGeneration, layout: 2, depth: 1)
        precondition(nav.pushedChats.map(\\.id) == [project])
        nav.dismissPushedChat(generation: nestedGeneration, layout: 2, depth: 0)
        precondition(nav.pushedChats.map(\\.id) == [project], "late inner-stack callback cannot pop project")
        nav.dismissPushedChat(generation: nav.pushedChatGeneration, layout: 2)
        precondition(nav.pushedChats.isEmpty)

        // An exact folder fallback survives list Back and background workspace callbacks.
        let folder = ClientChatSession()
        folder.model.selected = ChatConversation(id: "b")
        folder.model.currentReference = b
        nav.showChat(b, owner: UUID(), sessionKey: .init(peer: "mac", workspace: "p", conversation: nil),
            session: folder, folderName: "P", hostName: "Mac", presentationID: nil,
            intent: nav.chatHandoff.intent, handoffID: nil, layout: 2)
        let fallback = nav.chatHandoff.reader!
        nav.restoreLayout { nav.restoredChatReader = fallback; nav.restoredRoute = route }
        nav.leaveThread(session: folder)
        precondition(nav.restoredChatReader?.session === folder && nav.currentRoute?.reference?.kind == .workspace)
        nav.rememberWorkspace(peer: "mac", workspaceID: "other", section: .sessions, owner: UUID())
        let folderRoute = nav.currentRoute!
        precondition(folderRoute.reference?.workspaceID == "p" && fallback.matches(folderRoute))
        nav.restoreLayout { nav.restoredChatReader = fallback; nav.restoredRoute = folderRoute }
        precondition(nav.restoredChatReader?.session === folder, "next fold keeps the source list session")
        let terminal = WorkReference(scope: scope, hostIdentity: "mac", workspaceID: "other",
            kind: .terminal, itemID: "pty")
        nav.showTerminal(terminal, owner: "old-cover")
        precondition(nav.currentRoute?.reference == terminal)
        // Authoritative dismissal has no scene-phase gate.
        nav.leaveTerminal(owner: "old-cover")
        precondition(nav.currentRoute?.reference == folderRoute.reference && fallback.matches(nav.currentRoute!))
        nav.showTerminal(terminal, owner: "new-cover")
        nav.leaveTerminal(owner: "old-cover")
        precondition(nav.visibleTerminal == terminal, "old cover teardown cannot clear a successor for the same pty")
        nav.leaveTerminal(owner: "new-cover")
        precondition(nav.currentRoute?.reference == folderRoute.reference)
        let child = UUID(), grandchild = UUID()
        nav.pushOwned(ClientOwnedPush(id: child), from: fallback.id)
        nav.pushOwned(ClientOwnedPush(id: grandchild), from: child)
        precondition(nav.restoredChatReader?.session === folder)
        nav.dismissPushedChat(generation: nav.pushedChatGeneration, layout: 2, depth: 1)
        nav.dismissPushedChat(generation: nav.pushedChatGeneration, layout: 2, depth: 0)
        precondition(nav.restoredChatReader?.session === folder && nav.currentRoute?.reference?.workspaceID == "p")
        nav.pushOwned(ClientOwnedPush(id: UUID()), from: nil)
        precondition(nav.restoredChatReader == nil && nav.restoredRoute == nil, "new root choice retires unrelated fallback")

        // Fork captures the production action ticket before its await.
        let forkTicket = nav.chatActionTicket()
        precondition(nav.acceptsChatAction(forkTicket))
        nav.pushOwned(ClientOwnedPush(id: UUID()), from: nil)
        let successor = nav.pushedChat!.id
        if nav.acceptsChatAction(forkTicket) { nav.chooseWithinChat(session: folder, presentationID: child) }
        precondition(!nav.acceptsChatAction(forkTicket) && nav.pushedChat?.id == successor)
        let beforeLayout = nav.chatActionTicket()
        nav.stackGeneration &+= 1
        precondition(!nav.acceptsChatAction(beforeLayout))
        let beforeAccount = nav.chatActionTicket()
        WorkSessionContext.shared.scope = .account(origin: "https://test.example", handle: "bob")!
        precondition(!nav.acceptsChatAction(beforeAccount))
        print("Mobile navigation: passive restoration, cover return, nested pushes, in-place selection/list Back, fallback provenance, inactive terminal dismissal, stale Fork/layout/account delivery and guarded system Back passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-chat-navigation-') as directory:
    path = Path(directory) / 'checks.swift'
    path.write_text(model_stub + stubs + nav_class + presented + tests)
    files = ['Client/ClientChatLayoutHandoff.swift', 'Client/ClientChatSession.swift',
             'Features/Workspaces/Chat/Singleflight.swift', 'Features/Work/ChatDraftTransition.swift',
             'Features/Work/WorkReference.swift', 'Features/Work/WorkMobileRoute.swift', 'Design/L10n.swift']
    binary = Path(directory) / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-o', str(binary),
                    str(path), *[str(sources / file) for file in files]], check=True)
    subprocess.run([str(binary)], check=True)
