// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Actual source task, capability, model method and root callback bodies run
// against owned continuations and separate row fields. No real host is created.
import Foundation
enum L10n {static func text(_ key: String) -> String {key}}
struct ChatConversation: Sendable {var id: String}
struct WorkspaceFolder {var id: String}
enum FixtureFailure: Error {case failed}
@MainActor final class WorkSessionContext {static let shared=WorkSessionContext();var scope="account"}
/* SOURCE_FEATURE */
enum WorkDestinationResolver {
    /* SOURCE_ROUTE_RECORD */
    /* SOURCE_ROUTE */
}
@MainActor final class Wire {
    var pending: CheckedContinuation<ChatConversation,Error>?
    var calls:[[String:Any]]=[]
    func invoke(peer: String?,method: String,id: String) async throws -> ChatConversation {
        calls.append(["peer":peer as Any? ?? NSNull(),"method":method,"id":id])
        return try await withCheckedThrowingContinuation {pending=$0}
    }
    func answer(failure: Bool) {
        let held=pending;pending=nil
        if failure {held?.resume(throwing:FixtureFailure.failed)} else {held?.resume(returning:ChatConversation(id:"copy"))}
    }
}
@MainActor enum Bridge {
    static var version=0,probes=0
    static var wire=Wire()
    static func peerProtocolVersion(_ peer: String) async throws -> Int {
        probes += 1
        guard version>0 else {throw FixtureFailure.failed}
        return version
    }
    static func chatInvoke(peer: String?,_ method: String,_ params:[String:String],as type: ChatConversation.Type) async throws -> ChatConversation {
        try await wire.invoke(peer:peer,method:method,id:params["id"]!)
    }
    /* SOURCE_BRIDGE_ROUTE */
    /* SOURCE_BRIDGE_FORK */
}
@MainActor final class ChatModel {
    var published:[String]=[],reveal:[[String:String]]=[]
    func publishSidebarConversation(_ chat: ChatConversation,in folderID: String) {published.append(chat.id)}
    func reveal(id: String,in folder: String) {reveal.append(["id":id,"folder":folder])}
    /* SOURCE_MODEL_FORK */
}
@MainActor final class Root {
    var route: Route
    let chat=ChatModel()
    var projects:[String]=[],histories:[String]=[]
    init(_ route: Route) {self.route=route}
    func setProjectExpanded(_ id: String,_ value: Bool) {projects.append(id)}
    func setHistoryExpanded(_ id: String,_ value: Bool) {histories.append(id)}
    func openSection(_ section: WorkspaceSection,in folder: String) {route = .workspace(id:folder,section:section)}
    func operation(conversation: ChatConversation,folder: WorkspaceFolder) -> () async throws -> Void {
        return /* SOURCE_CALLBACK */
    }
}
@MainActor final class Row {
    var copying=false,actionError:String?
    let fork: () async throws -> Void
    init(_ fork: @escaping () async throws -> Void) {self.fork=fork}
    func start() {
        /* SOURCE_TASK */
    }
}
@main enum ForkReference {
    @MainActor static func until(_ predicate: ()->Bool) async {
        for _ in 0..<10_000 {if predicate() {return};await Task.yield()}
        precondition(predicate())
    }
    static func route(_ raw:[String:Any]) -> Route {
        switch raw["kind"] as! String {
        case "global": return .global(GlobalSection(rawValue:raw["section"] as! String)!)
        case "workspace": return .workspace(id:raw["id"] as! String,section:WorkspaceSection(rawValue:raw["section"] as! String)!)
        case "workspacesOverview":return .workspacesOverview
        case "sshTerminals":return .sshTerminals(host:raw["host"] as! String)
        case "ssh":
            let section=raw["section"] as! [String:Any]
            switch section["kind"] as! String {
            case "hosts":return .ssh(.hosts(folder:section["folder"] as? String))
            case "keys":return .ssh(.keys)
            case "snippets":return .ssh(.snippets)
            default:return .ssh(.knownHosts)
            }
        default:fatalError("Unknown fixture route")
        }
    }
    static func value(_ route: Route) -> [String:Any] {
        switch route {
        case .global(let section):return ["kind":"global","section":section.rawValue]
        case .workspace(let id,let section):return ["kind":"workspace","id":id,"section":section.rawValue]
        case .workspacesOverview:return ["kind":"workspacesOverview"]
        case .sshTerminals(let host):return ["kind":"sshTerminals","host":host]
        case .ssh(let section):
            let raw:[String:Any]
            switch section {case .hosts(let folder):raw=["kind":"hosts","folder":folder as Any? ?? NSNull()];case .keys:raw=["kind":"keys"];case .snippets:raw=["kind":"snippets"];case .knownHosts:raw=["kind":"knownHosts"]}
            return ["kind":"ssh","section":raw]
        }
    }
    @MainActor static func run(_ input:[String:Any]) async -> [String:Any] {
        WorkSessionContext.shared.scope="account";Bridge.version=input["version"] as! Int;Bridge.probes=0;Bridge.wire=Wire()
        let root=Root(route(input["before"] as! [String:Any])),folder=input["folder"] as! String
        let row=Row(root.operation(conversation:ChatConversation(id:"source"),folder:WorkspaceFolder(id:folder)))
        row.start();let began=row.copying
        await until {Bridge.wire.pending != nil || !row.copying}
        root.route=route(input["after"] as! [String:Any])
        let changed=input["scopeChanged"] as! Bool,visible=(input["mounted"] as! Bool) && !changed
        if changed {WorkSessionContext.shared.scope="other"}
        if Bridge.wire.pending != nil {Bridge.wire.answer(failure:input["failure"] as! Bool)}
        await until {!row.copying}
        return ["input":input,"began":began,"copying":visible && row.copying,"error":visible && row.actionError != nil,"published":root.chat.published,"reveal":root.chat.reveal,"projects":root.projects,"histories":root.histories,"route":value(root.route),"calls":Bridge.wire.calls,"probes":Bridge.probes]
    }
    @MainActor static func main() async throws {
        let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
        var cases:[[String:Any]]=[]
        for row in input["cases"] as! [[String:Any]] {cases.append(await run(row["input"] as! [String:Any]))}
        let pairs=(input["routePairs"] as! [[String:Any]]).map {pair -> [String:Any] in
            let a=route(pair["a"] as! [String:Any]),b=route(pair["b"] as! [String:Any])
            return ["a":pair["a"]!,"b":pair["b"]!,"equal":a==b,"setCount":Set([a,b]).count]
        }
        print(String(data:try JSONSerialization.data(withJSONObject:["minimum":RemoteHostFeature.chatFork.minimumProtocol,"cases":cases,"routePairs":pairs],options:[.sortedKeys]),encoding:.utf8)!)
    }
}
