// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Only fields read by the unchanged original state owners. No Bridge, shared
// store, host, preferences, archive or agent is constructed by this harness.
import Foundation
struct ChatConversation: Codable, Identifiable {
    var id: String
    var title: String
    var pendingSteer: String?
}
@main enum ChatMutationsReference {
    static func row(_ raw: Any) throws -> ChatConversation {
        try JSONDecoder().decode(ChatConversation.self,from:JSONSerialization.data(withJSONObject:raw))
    }
    static func value(_ row: ChatConversation) -> [String:Any] {
        ["id":row.id,"title":row.title,"pendingSteer":row.pendingSteer as Any? ?? NSNull()]
    }
    @MainActor static func run(_ input: [String:Any]) throws -> [String:Any] {
        let lists=ChatListMutations<ChatConversation>();var notes=ChatSteerOverlay()
        var reads:[String:(ChatListMutations<ChatConversation>.Read,ChatSteerOverlay.Read)]=[:]
        var mutations:[String:ChatSteerOverlay.Mutation]=[:],current:[String:[ChatConversation]]=[:],output:[[String:Any]]=[]
        for step in input["steps"] as! [[String:Any]] {
            let owner=step["owner"] as? String ?? "owner",name=step["name"] as? String ?? "default"
            var accepted:Any=NSNull(),record:Any=NSNull()
            switch step["op"] as! String {
            case "read": reads[name]=(lists.beginRead(owner:owner),notes.beginRead(owner:owner))
            case "replace": lists.replace(try row(step["row"]!),owner:owner)
            case "remove": lists.remove(step["id"] as! String,owner:owner)
            case "mutation": mutations[name]=notes.mutation(owner:owner,conversationID:step["id"] as! String)
            case "remember": accepted=notes.remember(owner:owner,conversationID:step["id"] as! String,note:step["note"] as? String,ifUnchangedSince:(step["since"] as? String).map { mutations[$0]! })
            case "apply":
                let read=reads[name]!,held=current[owner] ?? []
                current[owner]=notes.apply(lists.apply(try (step["rows"] as! [Any]).map(row),read:read.0,current:held),read:read.1,current:held)
            case "preserve":
                let incoming=try row(step["row"]!)
                record=value(ChatSteerOverlay.preservingNote(in:incoming,from:current[owner]?.first { $0.id==incoming.id }))
            case "reset": lists.removeAll();notes.removeAll();current=[:]
            default: fatalError("Unknown fixture operation")
            }
            output.append(["rows":(current[owner] ?? []).map(value),"accepted":accepted,"record":record])
        }
        return ["input":input,"rows":output]
    }
    @MainActor static func main() throws {
        let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
        let cases=try (input["cases"] as! [[String:Any]]).map { try run($0["input"] as! [String:Any]) }
        let output:[String:Any]=["cases":cases,"reads":ChatReadFlights.reads.sorted(),"mutations":ChatReadFlights.mutations.sorted()]
        print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
