// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Run inside the native QA target with the production model/cache/index types.
import Foundation
@MainActor enum WorkSearchModelTests {
    struct Failure: Error { let message: String }
    static func run() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message:message) } }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw Failure(message:"Timed out awaiting model state")
        }
        try check(InProcessTransport.protocolVersion == "14", "QA app links the rebuilt protocol 14 runtime")
        let legacyChunk = try JSONDecoder().decode(ChatEventChunk.self, from: Data(#"{"events":[],"nextOffset":10}"#.utf8))
        try check(legacyChunk.tailCursor == nil && !legacyChunk.reset, "older host polling remains decodable")
        let resetChunk = try JSONDecoder().decode(ChatEventChunk.self, from: Data(#"{"events":[],"nextOffset":10,"tailCursor":"opaque-tail","reset":true}"#.utf8))
        let resetRoundTrip = try JSONDecoder().decode(ChatEventChunk.self, from: JSONEncoder().encode(resetChunk))
        try check(resetRoundTrip.tailCursor == "opaque-tail" && resetRoundTrip.reset, "trim signal and cursor survive decoding")
        let cursorPage = ChatEventPage(events:[],nextOffset:10,tailCursor:"opaque-page-tail")
        let pageRoundTrip = try JSONDecoder().decode(ChatEventPage.self, from: JSONEncoder().encode(cursorPage))
        try check(pageRoundTrip.tailCursor == cursorPage.tailCursor, "saved page retains opaque polling cursor")
        let records: [[String: Any]] = [
            ["seq":10,"kind":"agent","event":["kind":"text","delta":"First "]],
            ["seq":20,"kind":"agent","event":["kind":"text","delta":"second"]],
            ["seq":30,"kind":"agent","event":["kind":"done","status":"ok"]],
            ["seq":40,"kind":"agent","event":["kind":"text","delta":"After boundary"]],
            ["seq":50,"kind":"agent","event":["kind":"thinking","delta":"Think "]],
            ["seq":60,"kind":"agent","event":["kind":"thinking","delta":"more"]]
        ]
        let events = try JSONDecoder().decode([ChatTimelineEvent].self, from: JSONSerialization.data(withJSONObject: records))
        let full = ChatDisplayItem.coalesce(events, defaultBackend:"qa", running:false)
        let partial = ChatDisplayItem.coalesce(Array(events.dropFirst()), defaultBackend:"qa", running:false)
        try check(partial.contains { $0.id == "text-s20" }, "partial stream row starts at loaded event")
        try check(ChatReadingAnchor.resolve("text-s20",items:full,events:events) == "text-s10", "partial text anchor resolves after prepend")
        try check(ChatReadingAnchor.resolve("think-s60",items:full,events:events) == "think-s50", "partial thinking anchor resolves after prepend")
        try check(ChatReadingAnchor.resolve("text-s40",items:full,events:events) == "text-s40", "tool/turn boundary does not merge messages")
        try check(ChatReadingAnchor.resolve("text-s30",items:full,events:events) == nil, "nontext event cannot alias a text row")
        try check(ChatReadingAnchor.resolve("text-s25",items:full,events:events) == nil, "missing record cannot alias a neighboring message")
        let scope = WorkReference.Scope.local(installationID:"qa-model")
        let folder = WorkSearchIndex.Folder(hostIdentity:"host",workspaceID:"folder")
        func reference(_ id:String, _ anchor:String) -> WorkReference {
            .init(scope:scope,hostIdentity:"host",workspaceID:"folder",kind:.conversation,itemID:id,anchor:anchor)
        }
        func page(_ ids:[String], cursor:String? = nil) -> WorkSearchLive.Page {
            .init(hits:ids.map { id in .init(reference:reference(id,"text-s42"),revision:"2",folderName:"Design",title:"Layout",excerpt:.init(text:"Layout",highlights:[]),score:12,updatedAt:Date(),partial:false) },nextCursor:cursor,coverage:.init(searched:3,unreadable:0,partial:false))
        }
        var requests: [(String?,CheckedContinuation<WorkSearchLive.Page,Error>)] = []
        var owned = true
        let saved = WorkSearchIndex.Document(reference:reference("a","user-s1"),revision:"1",title:"Layout",text:"Layout",folderName:"Design",machineName:"Studio",updatedAt:Date(),partial:false)
        let removed = WorkSearchIndex.Document(reference:reference("removed","user-s2"),revision:"1",title:"Layout",text:"Layout",folderName:"Design",machineName:"Studio",updatedAt:saved.updatedAt.addingTimeInterval(-1),partial:false)
        let cache = WorkSearchCache()
        let model=WorkSearchModel(scope:scope,folders:[folder:"Design"],machines:["host":"Studio"],metadata:[saved,removed],includesSavedText:false,liveHosts:["host"],liveFetch:{_,_,_,cursor in
            try await withCheckedThrowingContinuation { requests.append((cursor,$0)) }
        },cache:cache,ownsSession:{owned})
        defer { model.close() }
        model.query="layout"
        await model.start()
        try check(model.results.count == 2 && requests.isEmpty,"initial saved-only search")
        model.selected=model.results[0].reference
        model.selectLiveHosts(["host"])
        try await wait { requests.count == 1 }
        requests[0].1.resume(returning:page(["a","b"],cursor:"next"))
        try await wait { model.hasUpdatedResults }
        try check(model.results.count == 2 && model.results[0].source == .live,"selected row retained and replaced")
        await cache.discardAfterRepair()
        await model.acceptUpdatedResults()
        try check(!model.results.contains { $0.reference.itemID == "removed" }, "pending acceptance must not resurrect removed saved content")
        try check(model.results.count == 2,"accept first live update")
        model.loadMoreLive()
        try await wait { requests.count == 2 }
        try check(requests[1].0 == "next","continuation propagated")
        requests[1].1.resume(returning:page(["c"]))
        try await wait { model.hasUpdatedResults }
        await model.acceptUpdatedResults()
        try check(model.results.count == 3,"append continuation")
        model.selectLiveHosts(["host"])
        try await wait { requests.count == 3 }
        try check(model.results.count == 3,"retry retains available rows")
        requests[2].1.resume(throwing:Failure(message:"offline"))
        try await wait { model.liveFailures.contains("host") }
        try check(model.results.count == 3,"failed retry retains rows")
        model.selectLiveHosts(["host"])
        try await wait { requests.count == 4 }
        owned=false
        requests[3].1.resume(returning:page(["foreign"]))
        try await wait { model.results.isEmpty }
        try check(!model.results.contains { $0.reference.itemID == "foreign" },"owner loss discards reply")
    }
}
