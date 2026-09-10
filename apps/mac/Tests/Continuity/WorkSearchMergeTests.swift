// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
@main struct WorkSearchMergeTests {
    static func main() throws {
        let scope=WorkReference.Scope.local(installationID:"client")
        func hit(_ id:String, source:WorkSearchIndex.Source = .saved, score:Int = 8, anchor:String? = nil) -> WorkSearchIndex.Hit {
            .init(source:source,reference:.init(scope:scope,hostIdentity:"host",workspaceID:"folder",kind:.conversation,itemID:id,anchor:anchor),revision:"1",title:.init(text:"Layout",highlights:[]),excerpt:.init(text:"Layout",highlights:[]),folderName:"Folder",machineName:"Mac",updatedAt:Date(timeIntervalSince1970:1),partial:false,score:score)
        }
        let saved=[hit("a",score:20,anchor:"user-s1"),hit("b")]
        let live=[hit("a",source:.live,score:12,anchor:"text-s2"),hit("c",source:.live)]
        let merged=WorkSearchMerge.combine(saved:saved,live:live)
        assert(merged.count == 3)
        assert(merged[0].source == .live && merged[0].reference.anchor == "text-s2")
        assert(merged.map(\.reference.itemID) == ["a","b","c"])
        assert(WorkSearchMerge.combine(saved:saved.reversed(),live:live.reversed()).map(\.reference) == merged.map(\.reference))
        assert(WorkSearchMerge.combine(saved:(0..<250).map { hit(String(format:"%03d",$0)) },live:[]).count == 200)
        let retained=WorkSearchResultOrder.retained(previous:saved.map(\.reference),incoming:merged.map(\.reference))
        assert(retained.map(\.itemID) == ["a","b"] && retained[0].anchor == "text-s2")
        print("Search merge: live replacement, stable relevance ties, selected order and combined cap passed")
    }
}
