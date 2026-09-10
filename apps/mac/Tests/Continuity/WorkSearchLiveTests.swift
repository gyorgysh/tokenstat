// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

@main struct WorkSearchLiveTests {
    static func main() throws {
        let scope = WorkReference.Scope.account(origin: "https://example.invalid", handle: "alice")!
        let hit: [String: Any] = ["source":"live", "reference": ["scope":["kind":"local","origin":"","identity":"host"], "hostIdentity":"host", "workspaceId":"folder", "kind":"conversation", "itemId":"chat", "anchor":"user-s42"], "revision":"1", "folderName":"Design project", "title":"Layout", "excerpt":"👩🏽‍💻 café", "highlights":[["location":8,"length":4]], "score":12, "updatedAtMs":1000, "partial":false]
        func data(_ hits: [[String: Any]], cursor: String? = nil) throws -> Data {
            var payload: [String: Any] = ["hits":hits,"coverage":["searched":hits.count,"unreadable":0,"partial":false]]
            if let cursor { payload["nextCursor"] = cursor }
            return try JSONSerialization.data(withJSONObject: payload)
        }
        let page = try WorkSearchLive.decode(data([hit]), expectedHost:"host", scope:scope)
        assert(page.hits[0].folderName == "Design project")
        assert(page.hits[0].reference.scope == scope)
        assert(page.hits[0].reference.anchor == "user-s42")
        assert(page.hits[0].excerpt.highlights == [NSRange(location:8,length:4)])
        func refuses(_ hit: [String: Any], host: String = "host") throws {
            do { _ = try WorkSearchLive.decode(data([hit]), expectedHost:host, scope:scope); fatalError("accepted invalid response") }
            catch WorkSearchLive.Invalid.response {}
        }
        try refuses(hit, host:"other")
        for range in [["location":1,"length":1],["location":8,"length":Int.max],["location":-1,"length":1]] {
            var invalid=hit; invalid["highlights"]=[range]; try refuses(invalid)
        }
        for field in ["hostIdentity", "anchor"] {
            var invalid=hit; var reference=hit["reference"] as! [String: Any]
            reference[field]="foreign"; invalid["reference"]=reference; try refuses(invalid)
        }
        var forged=hit; var reference=hit["reference"] as! [String: Any]
        reference["scope"]=["kind":"account","origin":"https://example.invalid","identity":"alice"]
        forged["reference"]=reference; try refuses(forged)
        do { _ = try WorkSearchLive.decode(data([hit,hit]),expectedHost:"host",scope:scope); fatalError("duplicate destination") } catch WorkSearchLive.Invalid.response {}
        do { _ = try WorkSearchLive.decode(data([hit],cursor:"offset:50"),expectedHost:"host",scope:scope); fatalError("invalid cursor") } catch WorkSearchLive.Invalid.response {}
        do { _ = try WorkSearchLive.decode(data([hit]),expectedHost:"host",scope:scope,workspaceIDs:["other"]); fatalError("foreign filter") } catch WorkSearchLive.Invalid.response {}
        print("Live search: verified host scope, stable anchors, original highlights and malformed response refusal passed")
    }
}
