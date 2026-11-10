// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Compile original DTO/history/menu/formatting methods against inert owners.
// This does not instantiate ChatModel, a draft file store, transport or windows.
import Foundation
import SwiftUI

/* SOURCE_HISTORY */
/* SOURCE_PRESENTATION */
/* SOURCE_AGE */
/* SOURCE_ELAPSED */
/* SOURCE_SHARING */
/* SOURCE_PULL */
// Routing decoration is outside this sidebar-field decoder comparison.
struct ChatRoutingState: Codable, Hashable, Sendable {}
/* SOURCE_CONVERSATION */

@MainActor enum ChatSidebarReference {
    /* SOURCE_CACHE_CAP */
    /* SOURCE_PATIENCE */
    struct InitialMark {
        var id: String
        /* SOURCE_INITIAL */
        func value() -> String {initial}
    }
    typealias SidebarPinAction = ProjectMenuReference.SidebarPinAction
    struct Folder { var name="Fixture project" }
    struct Row {
        var conversation: ChatConversation; var draft: WorkReference?; var folder=Folder()
        @ProjectMenuReference.Cell var renaming=false
        @ProjectMenuReference.Cell var copying=false
        @ProjectMenuReference.Cell var actionError: String?
        @ProjectMenuReference.Cell var confirmsRemoval=false
        func fork() async throws {}
        /* SOURCE_MENU */
        func entries() -> [NativeMenuItem] { menu }
    }
    final class Drafts {
        static let shared=Drafts(); var present=false
        func draft(for reference: WorkReference) -> Int? { present ? 1 : nil }
    }
    struct Filter {
        typealias ChatDraftStore = Drafts
        var selected: ChatConversation?
        func draftReference(for id: String,in folder: String) -> WorkReference? {
            WorkReference(scope:.local(installationID:"fixture"),hostIdentity:"host",workspaceID:folder,kind:.conversation,itemID:id)
        }
        /* SOURCE_UNUSED */
        /* SOURCE_UNTOUCHED */
    }
    /* SOURCE_HOLDING */
    static func decode(_ input: Any) throws -> ChatConversation {
        try JSONDecoder().decode(ChatConversation.self,from:JSONSerialization.data(withJSONObject:input))
    }
    static func snapshot(_ input: [String:Any]) throws -> [String:Any] {
        let windows=(input["windows"] as! [[String:Any]]).map { row -> [String:Any] in
            let range=ChatHistoryWindow.visible(count:row["count"] as! Int,selected:row["selected"] as? Int,expanded:row["expanded"] as! Bool)
            var result=row; result["range"]=[range.lowerBound,range.upperBound]; return result
        }
        let loops=(input["loops"] as! [[String:Any]]).map { row -> [String:Any] in
            var result=row; result["next"]=ChatHistoryWindow.looped(count:row["count"] as! Int,current:row["current"] as? Int,step:row["step"] as! Int) as Any? ?? NSNull(); return result
        }
        let orders=try (input["orders"] as! [[String:Any]]).map { row -> [String:Any] in
            let list=try (row["ids"] as! [String]).map { try decode(["id":$0,"workspaceId":"folder","title":"Conversation","backend":"codex"]) }
            var result=row; result["ordered"]=holdingOrder(list,held:row["held"] as? [String]).map(\.id); return result
        }
        let menus=try (input["menus"] as! [[String:Any]]).map { row -> [String:Any] in
            let state=row["state"] as! [String:Any]
            let conversation=try decode(["id":"one","workspaceId":"folder","title":"Conversation","backend":"codex","running":state["running"]!,"teamShare":state["shared"] as! Bool ? ["id":"shared"] : NSNull()])
            let reference=state["reference"] as! Bool ? WorkReference(scope:.local(installationID:"fixture"),hostIdentity:"host",workspaceID:"folder",kind:.conversation,itemID:"one") : nil
            ProjectMenuReference.PinnedWorkStore.shared.pinned=state["pinned"] as! Bool
            ProjectMenuReference.PinnedWorkStore.shared.count=state["pinCount"] as! Int
            let view=Row(conversation:conversation,draft:reference); view.copying=state["copying"] as! Bool
            let entries=view.entries().map { entry -> [String:Any] in
                let kind: String
                switch entry.kind {case .action:kind="action";case .separator:kind="separator";case .heading:kind="heading"}
                return ["kind":kind,"title":entry.title,"enabled":entry.isEnabled,"selected":entry.isSelected,"symbol":entry.symbol as Any? ?? NSNull(),"destructive":entry.destructive]
            }
            return ["state":state,"entries":entries]
        }
        let presentation=(input["presentation"] as! [[String:Any]]).map { row -> [String:Any] in
            var result=row; let value=WorkspaceDirectoryPresentation.resolve(hasContent:row["content"] as! Bool,hasLoaded:row["loaded"] as! Bool,isLoading:row["loading"] as! Bool,error:row["error"] as! Bool ? "failure" : nil)
            switch value {case .content:result["result"]="content";case .loading:result["result"]="loading";case .failed:result["result"]="failed";case .empty:result["result"]="empty"}; return result
        }
        let ages=(input["ages"] as! [[String:Any]]).map { row -> [String:Any] in var result=row;result["label"]=CompactAge.text(ms:(row["ms"] as! NSNumber).int64Value,now:Date(timeIntervalSince1970:(row["now"] as! NSNumber).doubleValue/1000));return result }
        let timers=(input["timers"] as! [[String:Any]]).map { row -> [String:Any] in var result=row;result["label"]=TurnElapsed.phrase(since:Date(timeIntervalSince1970:(row["start"] as! NSNumber).doubleValue/1000),now:Date(timeIntervalSince1970:(row["now"] as! NSNumber).doubleValue/1000));return result }
        let untouched=try (input["untouched"] as! [[String:Any]]).map { row -> [String:Any] in
            let conversation=try decode(row["conversation"]!); Drafts.shared.present=row["draft"] as! Bool
            let filter=Filter(selected:row["selected"] as! Bool ? conversation : nil)
            var result=row; result["unused"]=filter.isUnused(conversation,in:"folder"); result["shown"] = !filter.isUntouched(conversation,in:"folder"); return result
        }
        let wires=(input["wires"] as! [[String:Any]]).map { row -> [String:Any] in
            let output: Any
            if let conversation=try? decode(row["input"]!) {
                output=["id":conversation.id,"workspace":conversation.workspaceID,"title":conversation.title,"backend":conversation.backend,"label":conversation.title.isEmpty ? L10n.text("apple.rootview.untitled_conversation.31d248c4") : conversation.title,"running":conversation.running,"updated":conversation.updatedAtMs,"last":conversation.lastMessageAtMs as Any? ?? NSNull(),"shared":conversation.teamShare?.id as Any? ?? NSNull(),"pull":conversation.pull?.symbol as Any? ?? NSNull()] as [String:Any]
            } else { output=NSNull() }
            return ["input":row["input"]!,"output":output]
        }
        let initials=(input["initials"] as! [[String:Any]]).map {row -> [String:Any] in ["id":row["id"]!,"initial":InitialMark(id:row["id"] as! String).value()]}
        return ["patience":Patience.standard,"cacheCap":chatListCacheCap,"initials":initials,"windows":windows,"loops":loops,"orders":orders,"menus":menus,"presentation":presentation,"ages":ages,"timers":timers,"untouched":untouched,"wires":wires]
    }
}
