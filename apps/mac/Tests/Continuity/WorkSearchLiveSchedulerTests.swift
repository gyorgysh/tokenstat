// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
@main struct WorkSearchLiveSchedulerTests {
    @MainActor static func main() async throws {
        var requests: [(String,String,CheckedContinuation<WorkSearchLive.Page,Error>)] = []
        var received: [String] = []
        var current = true
        let scheduler = WorkSearchLiveScheduler(fetch: { host, query, _, _ in
            try await withCheckedThrowingContinuation { requests.append((host,query,$0)) }
        }, receive: { host,_,_ in received.append(host) }, ownsSession:{current}, debounce:{})
        func settle() async { for _ in 0..<30 { await Task.yield() } }
        let page = WorkSearchLive.Page(hits:[],nextCursor:nil,coverage:.init(searched:0,unreadable:0,partial:false))
        scheduler.update(query:"first",kinds:[])
        await settle()
        assert(requests.isEmpty, "typing before opt-in must not contact hosts")
        scheduler.select(["a","b","c"])
        await settle()
        assert(requests.count == 2)
        scheduler.update(query:"second",kinds:[])
        await settle()
        assert(requests.count == 2, "cancel does not release transport slots")
        requests[0].2.resume(returning:page)
        await settle()
        assert(requests.count == 3 && requests[2].1 == "second")
        assert(received.isEmpty, "old generation must not publish")
        requests[1].2.resume(returning:page)
        await settle()
        assert(requests.count == 4)
        requests[2].2.resume(returning:page)
        await settle()
        assert(requests.count == 5 && received == ["a"])
        current=false
        requests[3].2.resume(returning:page)
        requests[4].2.resume(returning:page)
        await settle()
        assert(received == ["a"], "lost ownership must discard late results")
        scheduler.close()
        scheduler.select(["a"])
        scheduler.update(query:"third",kinds:[])
        await settle()
        assert(requests.count == 5)
        var delays: [CheckedContinuation<Void, Never>] = []
        var sent: [String] = []
        let debounced = WorkSearchLiveScheduler(fetch:{_,query,_,_ in sent.append(query); return page},
            receive:{_,_,_ in}, ownsSession:{true}, debounce:{ await withCheckedContinuation { delays.append($0) } })
        debounced.update(query:"old",kinds:[])
        debounced.select(["a"])
        await settle()
        assert(delays.count == 1 && sent.isEmpty)
        debounced.update(query:"new",kinds:[])
        await settle()
        assert(delays.count == 2 && sent.isEmpty)
        delays[0].resume()
        await settle()
        assert(sent.isEmpty, "superseded debounce must not send")
        delays[1].resume()
        await settle()
        assert(sent == ["new"])
        debounced.close()
        var paged: [(String?, CheckedContinuation<WorkSearchLive.Page, Error>)] = []
        var publishedCursors: [String?] = []
        let pagination = WorkSearchLiveScheduler(fetch:{_,_,_,cursor in
            try await withCheckedThrowingContinuation { paged.append((cursor,$0)) }
        }, receive:{_,cursor,_ in publishedCursors.append(cursor)}, ownsSession:{true}, debounce:{})
        pagination.update(query:"pages",kinds:[])
        pagination.select(["a"])
        await settle()
        paged[0].1.resume(returning:.init(hits:[],nextCursor:"next",coverage:page.coverage))
        await settle()
        assert(pagination.more(["a"]) == ["a"])
        assert(pagination.more(["a"]).isEmpty)
        await settle()
        assert(paged.count == 2 && paged[1].0 == "next")
        paged[1].1.resume(returning:page)
        await settle()
        assert(publishedCursors.count == 2 && publishedCursors[1] == "next")
        assert(pagination.more(["a"]).isEmpty)
        pagination.close()
        print("Live scheduler: opt-in, two persistent slots, supersession and owner-loss passed")
    }
}
