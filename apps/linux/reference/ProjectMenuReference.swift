// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Only loaded-model facts are injected. Original menu declarations are compiled
// at the markers; all unported destinations are inert and perform no IO.
import Foundation

extension Notification.Name {
    static let remotePeerDidDisconnect = Notification.Name("fixture.remotePeerDidDisconnect")
}
@MainActor enum ProjectMenuReference {
    @propertyWrapper final class Cell<Value> {
        var wrappedValue: Value
        init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    }
    struct State: Decodable {
        var reference: Bool; var pinned: Bool; var pinCount: Int
        var machineId: String?; var machineLabel: String?
        var stale: Bool; var shared: Bool; var stopSharing: Bool; var gitIsRepo: Bool?
    }
    final class PinnedWorkStore {
        static let shared = PinnedWorkStore()
        static let capacity = 8
        var pinned = false; var count = 0
        func isPinned(_ reference: WorkReference) -> Bool { pinned }
        func pins(in scope: WorkReference.Scope) -> [Int] { Array(0..<count) }
        func pin(_ reference: WorkReference,label: String,folderName: String) {}
        func unpin(_ reference: WorkReference) {}
    }
    /* SOURCE_PIN_ACTION */
    struct Git { var isRepo: Bool }
    struct WorkspaceFolder {
        var id = "fixture"; var name = "Fixture project"
        var machineID: String?; var machineLabel: String?; var git: Git?
        var isRemote: Bool { machineID != nil }
    }
    struct Publication { var workspaceId = "fixture"; var phase = "active"; var accountCleanupPending = false }
    struct Teams {
        var shared: Bool; var stopSharing: Bool
        var localProjects: [Publication] { stopSharing ? [Publication()] : [] }
        func localProjects(for id: String) -> [Publication] { shared ? [Publication()] : [] }
    }
    struct Workspaces {
        var stale: Bool
        func isRemoteStale(_ peer: String) -> Bool { stale }
        func revealInFinder(_ folder: WorkspaceFolder) {}
        func showLauncher(in id: String) {}
    }
    struct Saved { var reference: WorkReference; var name: String }
    struct Stopping { var name: String; var publications: [Publication] }
    struct Root {
        var teams: Teams; var workspaces: Workspaces; var hasReference: Bool
        @Cell var savedFolder: Saved? = nil; @Cell var sharingProject: WorkspaceFolder? = nil
        @Cell var stoppingSharing: Stopping? = nil; @Cell var worktreeProject: WorkspaceFolder? = nil
        @Cell var workspacePendingChatRemoval: WorkspaceFolder? = nil; @Cell var workspacePendingRemove: WorkspaceFolder? = nil
        init(_ state: State) {
            teams = Teams(shared:state.shared,stopSharing:state.stopSharing)
            workspaces = Workspaces(stale:state.stale); hasReference = state.reference
        }
        func pinReference(for folder: WorkspaceFolder) -> WorkReference? {
            hasReference ? WorkReference(scope:.local(installationID:"fixture"),hostIdentity:"fixture-host",workspaceID:folder.id,kind:.workspace,itemID:nil) : nil
        }
        func openSharedProject(_ folder: WorkspaceFolder) {}
        func startPrivateChat(in folder: WorkspaceFolder) {}
        func startNewChat(in folder: WorkspaceFolder) {}
        func openSection(_ section: WorkspaceSection,in id: String,after: () -> Void) { after() }
        /* SOURCE_PROJECT_ACTIONS */
        func entries(_ folder: WorkspaceFolder) -> [NativeMenuItem] { projectActions(folder) }
    }
    struct Row {
        var isStale: Bool; @Cell var renaming = false; var actions: () -> [NativeMenuItem]
        init(stale: Bool,actions: @escaping () -> [NativeMenuItem]) { isStale=stale; self.actions=actions }
        /* SOURCE_ROW_MENU */
        func entries() -> [NativeMenuItem] { menu }
    }
    @MainActor struct Resolver {
        /* SOURCE_PIN_REFERENCE */
        func resolve(_ id: String) -> WorkReference? {
            pinReference(for:WorkspaceFolder(id:id,machineID:nil,machineLabel:nil,git:nil))
        }
    }
    @MainActor enum RemovalReference {
        struct Document {var workspaceID: String; var path="dirty-file"; var isDirty=true}
        enum Bridge {
            static var calls: [[String:Any]]=[]; static var fail=false
            static func call(_ method: String,_ params: [String:Any]) throws {
                calls.append(["method":method,"params":params])
                if fail {throw NSError(domain:"fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"host failed"])}
            }
            static func removeWorkspace(id: String) async throws {try call("workspace.remove",["id":id])}
            static func onPeer<T: Decodable>(_ peer: String,_ method: String,_ params: [String:Any],as type: T.Type) async throws -> T {
                try call("remote.call",["peer":peer,"method":method,"params":params])
                return try JSONDecoder().decode(type,from:Data("{\"removed\":true}".utf8))
            }
        }
        @MainActor final class Controller {
            var documents: [String:Document]=[:]; var selectedID: String?
            var remoteFolders: [String:[WorkspaceFolder]]=[:]; var errorMessage: String?
            var closed: String?; var forgotten: [String]=[]; var refreshed: [String]=[]; var loads=0; var publishes=0
            func requestClose(_ path: String,in id: String) {closed=path}
            func forgetTabs(in id: String) {forgotten.append(id)}
            func publishFolders() {publishes += 1}
            func refreshRemotePeer(_ peer: String) {refreshed.append(peer)}
            func load() async {loads += 1}
            /* SOURCE_REMOVE */
        }
        static func run(_ input: [String:Any]) async -> [String:Any] {
            let id=input["id"] as! String, peer=input["peer"] as? String
            let folder=WorkspaceFolder(id:id,machineID:peer,machineLabel:nil,git:nil)
            let controller=Controller();controller.selectedID=input["selected"] as! Bool ? id : "other-selected"
            if let peer {controller.remoteFolders[peer]=[folder]}
            let dirty=input["dirty"] as! String
            if dirty != "none" {controller.documents["doc"]=Document(workspaceID:dirty == "own" ? id : "different-workspace")}
            Bridge.calls=[];Bridge.fail=input["fail"] as! Bool
            await controller.remove(folder)
            return ["calls":Bridge.calls,"close":controller.closed as Any? ?? NSNull(),"forgotten":controller.forgotten,"refreshed":controller.refreshed,"load":controller.loads,"publish":controller.publishes,"selection":controller.selectedID as Any? ?? NSNull(),"error":controller.errorMessage as Any? ?? NSNull()]
        }
    }
    static func snapshot(_ input: [String:Any]) async throws -> [String:Any] {
        let menus = try (input["menus"] as! [[String:Any]]).map { value -> [String:Any] in
            let state = try JSONDecoder().decode(State.self,from:JSONSerialization.data(withJSONObject:value["state"]!))
            PinnedWorkStore.shared.pinned=state.pinned; PinnedWorkStore.shared.count=state.pinCount
            let folder = WorkspaceFolder(machineID:state.machineId,machineLabel:state.machineLabel,git:state.gitIsRepo.map { Git(isRepo:$0) })
            let root = Root(state)
            let row = Row(stale:state.stale,actions:{ root.entries(folder) })
            let entries = row.entries().map { entry -> [String:Any] in
                let kind: String
                switch entry.kind { case .action:kind="action"; case .separator:kind="separator"; case .heading:kind="heading" }
                return ["kind":kind,"title":entry.title,"enabled":entry.isEnabled,"selected":entry.isSelected,"symbol":entry.symbol as Any? ?? NSNull(),"destructive":entry.destructive]
            }
            return ["state":value["state"]!,"items":entries]
        }
        let oldScope=WorkSessionContext.shared.scope, oldIdentity=WorkSessionContext.shared.localHostIdentity
        defer { WorkSessionContext.shared.scope=oldScope; WorkSessionContext.shared.localHostIdentity=oldIdentity }
        let references = try (input["references"] as! [[String:Any]]).map { value -> [String:Any] in
            WorkSessionContext.shared.scope = value["scope"] is NSNull ? nil : try JSONDecoder().decode(WorkReference.Scope.self,from:JSONSerialization.data(withJSONObject:value["scope"]!))
            WorkSessionContext.shared.localHostIdentity = value["local"] as? String
            let reference = Resolver().resolve(value["folder"] as! String)
            let encoded: Any = try reference.map { reference -> [String:Any] in
                var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reference)) as! [String:Any]
                object["itemId"]=NSNull(); object["anchor"]=NSNull()
                return object
            } as Any? ?? NSNull()
            var out=value; out["reference"]=encoded; return out
        }
        var removals: [[String:Any]]=[]
        for value in input["removals"] as! [[String:Any]] {
            let state=value["input"] as! [String:Any]
            removals.append(["input":state,"result":await RemovalReference.run(state)])
        }
        return ["menus":menus,"references":references,"removals":removals]
    }
}
