// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Inert fixtures around the original RootView projection and open gates.
// Loaded chat/draft/access/cache facts are injected. No IO or preferences.
import Foundation

enum WorkCache {
    /* SOURCE_RECORD_ID */
    /* SOURCE_RECORD_PREFIX */
}

enum PinnedWorkStore {
    /* SOURCE_PIN */
    /* SOURCE_PIN_KEY */
    /* SOURCE_VALID_SCOPE */
    /* SOURCE_VALID_IDENTIFIER */
}
@MainActor final class WorkContinuityStore {
    static let shared = WorkContinuityStore()
    var recent: [WorkReference] = []
    func recentConversations(scope: WorkReference.Scope) -> [WorkReference] {
        Array(recent.filter { $0.scope == scope }.prefix(4))
    }
}
@MainActor final class WorkAccessStore {
    static let shared = WorkAccessStore()
    var access: [String:Bool] = [:]
    func allowed(scope: WorkReference.Scope,host: String) -> Bool? { access[host] }
}
struct HomeFolder: Decodable { var id: String; var name: String; var machineLabel: String? }
struct HomeConversation: Decodable { var id: String; var title: String; var unused: Bool }
struct HomeCatalog: Decodable {
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
    var folders: [HomeFolder]
    var machines: [Machine]
    var access: [String:Bool]
    var saved: [WorkReference]
    var conversations: [String:[HomeConversation]]
    var terminals: [String:[String]]
}
struct HomePin: Decodable { var reference: WorkReference; var label: String; var folderName: String }
struct HomeWorkInput: Decodable { var catalog: HomeCatalog; var recent: [WorkReference]; var pins: [HomePin] }
struct HomeWorkspaces { var folders: [HomeFolder] }
struct HomeAccount { var machines: [Machine] }
struct HomeAccounts { var account: HomeAccount? }
struct TerminalSession { var hostID: String }
final class HomeTerminals {
    var items: [String:[String]] = [:]
    var selected: String?
    func sessions(in folder: String) -> [TerminalSession] { (items[folder] ?? []).map { .init(hostID:$0) } }
    func select(_ session: TerminalSession) { selected=session.hostID }
}
final class HomeChat {
    var conversations: [String:[HomeConversation]] = [:]
    var revealed: String?
    func sidebarChats(in folder: String) -> [HomeConversation] { conversations[folder] ?? [] }
    func isUnused(_ conversation: HomeConversation,in folder: String) -> Bool { conversation.unused }
    func reveal(id: String,in folder: String) { revealed=id }
}
struct HomeSavedCatalog {
    var saved: [WorkReference]
    func contains(_ reference: WorkReference) -> Bool {
        guard let key=WorkCache.recordID(for:reference) else { return false }
        return saved.contains { $0.scope == reference.scope && WorkCache.recordID(for:$0) == key }
    }
}
struct HomeSavedSelection { var reference: WorkReference }
@MainActor final class HomeWorkProjectionReference {
    var workspaces: HomeWorkspaces
    let chat = HomeChat()
    var account: HomeAccounts
    var savedWorkCatalog: HomeSavedCatalog
    let terminals = HomeTerminals()
    var lastSection: [String:WorkspaceSection] = [:]
    var target: [String:Any]?
    var savedConversation: HomeSavedSelection? {
        didSet { if let savedConversation { target=["kind":"savedCopy","reference":referenceJSON(savedConversation.reference)] } }
    }
    init(_ input: HomeWorkInput) {
        WorkSessionContext.shared.scope=input.catalog.scope
        WorkSessionContext.shared.localHostIdentity=input.catalog.localHostIdentity
        WorkContinuityStore.shared.recent=input.recent
        WorkAccessStore.shared.access=input.catalog.access
        workspaces=HomeWorkspaces(folders:input.catalog.folders)
        account=HomeAccounts(account:HomeAccount(machines:input.catalog.machines))
        savedWorkCatalog=HomeSavedCatalog(saved:input.catalog.saved)
        chat.conversations=input.catalog.conversations
        terminals.items=input.catalog.terminals
    }
    func setProjectExpanded(_ folder: String,_ expanded: Bool) {}
    func setHistoryExpanded(_ folder: String,_ expanded: Bool) {}
    func openSection(_ section: WorkspaceSection,in folder: String,update: () -> Void = {}) {
        update()
        if section == .sessions, let item=terminals.selected { target=["kind":"terminal","folder":folder,"item":item] }
        else if let item=chat.revealed { target=["kind":"conversation","folder":folder,"item":item] }
        else { target=["kind":"workspace","folder":folder] }
    }
    /* SOURCE_RECENT */
    /* SOURCE_AVAILABILITY */
    /* SOURCE_MESSAGE */
    /* SOURCE_PIN_SUBTITLE */
    /* SOURCE_PIN_AVAILABILITY */
    /* SOURCE_TERMINAL */
    /* SOURCE_OPEN_RECENT */
    /* SOURCE_OPEN_PIN */
    func reading(_ input: HomeWorkInput) -> [String:Any] {
        let recent=recentHomeWork.map { ["reference":referenceJSON($0.reference),"title":$0.title,"subtitle":$0.subtitle,"unavailable":$0.unavailable as Any? ?? NSNull()] }
        func pin(_ input: HomePin) -> PinnedWorkStore.Pin { .init(reference:input.reference,label:input.label,folderName:input.folderName,pinnedAt:Date(timeIntervalSince1970:0)) }
        let pins=input.pins.filter { $0.reference.scope == WorkSessionContext.shared.scope }.map { raw in
            ["pin":["reference":referenceJSON(raw.reference),"label":raw.label,"folderName":raw.folderName],"subtitle":pinSubtitle(pin(raw)),"unavailable":pinAvailability(pin(raw)) as Any? ?? NSNull()] as [String:Any]
        }
        let recentOpen: [Any]=input.recent.map { ref in
            target=nil; chat.revealed=nil; terminals.selected=nil; openHomeWork(ref); return target as Any? ?? NSNull()
        }
        let pinOpen: [Any]=input.pins.map { raw in
            target=nil; chat.revealed=nil; terminals.selected=nil; openPin(pin(raw)); return target as Any? ?? NSNull()
        }
        return ["recent":recent,"pins":pins,"recentOpen":recentOpen,"pinOpen":pinOpen]
    }
}
func referenceJSON(_ reference: WorkReference) -> [String:Any] {
    ["scope":["kind":reference.scope.kind.rawValue,"origin":reference.scope.origin,"identity":reference.scope.identity],"hostIdentity":reference.hostIdentity,"workspaceId":reference.workspaceID,"kind":reference.kind.rawValue,"itemId":reference.itemID as Any? ?? NSNull(),"anchor":reference.anchor as Any? ?? NSNull()]
}
