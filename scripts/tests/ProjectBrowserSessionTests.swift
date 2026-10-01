// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift, BrowserHistory.swift and ProjectBrowserSession.swift.
import Foundation

@MainActor enum Bridge {
    struct Reply { let url: String }
    static var opened: [Int] = []
    static var closed: [Int] = []
    static var pending: CheckedContinuation<Reply, Error>?
    enum Failure: Error { case transport }
    static var failListen = false
    static var failClose = false
    static var block = false
    static var blockClose = false
    static var pendingClose: CheckedContinuation<Void, Never>?
    static func proxyListen(peer: String, host: String, port: Int) async throws -> Reply {
        opened.append(port)
        if failListen { throw Failure.transport }
        if block { return try await withCheckedThrowingContinuation { pending = $0 } }
        return Reply(url: "http://127.0.0.1:\(45000 + port % 1000)/")
    }
    static func proxyUnlistenConfirmed(peer: String, host: String, port: Int) async throws {
        closed.append(port)
        if failClose { throw Failure.transport }
        if blockClose { await withCheckedContinuation { pendingClose = $0 } }
    }
}

@main struct ProjectBrowserSessionTests {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        precondition(condition(), "An asynchronous listener operation did not finish")
    }
    @MainActor static func main() async {
        let name = "browser-session-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = BrowserHistory(defaults: defaults)
        let owner = WorkReference(scope: .local(installationID: "installation-a"), hostIdentity: "host-a", workspaceID: "project-a", kind: .workspace, itemID: nil)
        history.record(BrowserTarget("3000")!, for: owner)
        let a = ProjectBrowserSession(owner: owner, peer: "host-a", history: history, isCurrent: { true })
        precondition(a.targetURL == "http://127.0.0.1:3000/" && a.transportURL.isEmpty && Bridge.opened.isEmpty,
                     "A saved suggestion opened a connection without an explicit action")
        for invalid in ["http://localhost:0/", "http://localhost:65536/", "http://user:pass@localhost:3000/", "http://localhost:3000/path\nnext", "http://127.0.0.2:3000/"] {
            await a.open(invalid)
            precondition(a.transportURL.isEmpty && Bridge.opened.isEmpty && a.error != nil,
                         "An invalid remote target bypassed its bridge")
        }
        let b = ProjectBrowserSession(owner: owner, peer: "host-a", history: history, isCurrent: { true })
        await a.open("localhost:3000/path")
        await b.open("localhost:3000/other")
        precondition(Bridge.opened == [3000], "Two pages did not share their listener")
        precondition(a.transportURL == "http://127.0.0.1:45000/path")
        a.observed("http://127.0.0.1:45000/next?q=one")
        precondition(history.entry(for: owner).lastTarget == "http://localhost:3000/next?q=one")
        precondition(a.intercepts(URL(string: "http://localhost:4000/")!))
        precondition(!a.intercepts(URL(string: a.transportURL)!))
        precondition(a.intercepts(URL(string: "http://user:pass@localhost:3000/")!))
        var post = URLRequest(url: URL(string: "http://localhost:4000/form")!)
        post.httpMethod = "POST"
        precondition(a.intercept(post, isMainFrame: true), "An unmapped remote POST was allowed onto this computer")
        precondition(a.intercept(URLRequest(url: URL(string: "http://localhost:4000/frame")!), isMainFrame: false),
                     "A remote subframe bypassed its project computer")
        await Task.yield()
        precondition(!Bridge.opened.contains(4000), "A blocked POST or subframe was replayed as GET")
        let closedAddress = a.transportURL
        a.close()
        let saved = history.entry(for: owner)
        a.observed(closedAddress)
        await a.open("4001")
        precondition(history.entry(for: owner) == saved && !Bridge.opened.contains(4001),
                     "A queued browser callback reopened or saved a closed listener")
        await Task.yield()
        precondition(Bridge.closed.isEmpty, "Closing one page disconnected another page")
        b.close()
        await wait { Bridge.closed == [3000] }
        Bridge.block = true
        let c = ProjectBrowserSession(owner: owner, peer: "pending-host", history: history, isCurrent: { true })
        let d = ProjectBrowserSession(owner: owner, peer: "pending-host", history: history, isCurrent: { true })
        let first = Task { await c.open("3100") }
        let second = Task { await d.open("3100") }
        await wait { Bridge.pending != nil && c.isOpening && d.isOpening }
        precondition(Bridge.opened.filter { $0 == 3100 }.count == 1)
        c.close()
        Bridge.pending?.resume(returning: Bridge.Reply(url: "http://127.0.0.1:45100/"))
        Bridge.pending = nil
        await first.value
        await second.value
        precondition(c.transportURL.isEmpty && d.transportURL == "http://127.0.0.1:45100/")
        precondition(!Bridge.closed.contains(3100), "A stale pending page closed another page's listener")
        d.close()
        await wait { Bridge.closed.contains(3100) }
        Bridge.block = false
        let oldAccount = ProjectBrowserSession(owner: owner, peer: "scope-host", history: history, isCurrent: { true })
        await oldAccount.open("3200")
        let nextOwner = WorkReference(scope: .local(installationID: "installation-b"), hostIdentity: "host-a", workspaceID: "project-a", kind: .workspace, itemID: nil)
        let newAccount = ProjectBrowserSession(owner: nextOwner, peer: "scope-host", history: history, isCurrent: { true })
        await newAccount.open("3200")
        precondition(Bridge.opened.filter { $0 == 3200 }.count == 2 && Bridge.closed.filter { $0 == 3200 }.count == 1,
                     "An account reused a listener opened under another account")
        oldAccount.close()
        await Task.yield()
        precondition(Bridge.closed.filter { $0 == 3200 }.count == 1, "An old account closed the new account's listener")
        newAccount.close()
        await wait { Bridge.closed.filter { $0 == 3200 }.count == 2 }
        let rotating = ProjectBrowserSession(owner: owner, peer: "rotation-host", history: history, isCurrent: { true })
        await rotating.open("3300")
        let firstLoad = rotating.loadRevision
        await rotating.open("3300")
        precondition(rotating.loadRevision == firstLoad + 1, "Go on the same address did not request a fresh page load")
        let oldGeneration = rotating.navigationGeneration
        await rotating.open("3301")
        precondition(!rotating.observed("http://127.0.0.1:45300/old", generation: oldGeneration),
                     "An old registered completion replaced an explicit Go")
        precondition(!rotating.observed("http://127.0.0.1:45300/late", generation: rotating.navigationGeneration, registered: false),
                     "A delayed in-page start took ownership while Go was pending")
        precondition(rotating.observed("http://127.0.0.1:45301/ready", generation: rotating.navigationGeneration))
        precondition(history.entry(for: owner).lastTarget == "http://127.0.0.1:3301/ready")
        for port in 3302...3320 { await rotating.open(String(port)) }
        await wait { Bridge.closed.filter { (3300..<3320).contains($0) }.count == 20 }
        precondition(rotating.intercepts(URL(string: "http://127.0.0.1:45300/back")!),
                     "Back used a retired listener instead of reacquiring it")
        await rotating.open(rotating.canonicalURL("http://127.0.0.1:45300/back"))
        precondition(rotating.targetURL == "http://127.0.0.1:3300/back" && Bridge.opened.filter { $0 == 3300 }.count == 2)
        await rotating.open("http://127.0.0.1:45300/typed")
        precondition(rotating.targetURL == "http://127.0.0.1:45300/typed" && Bridge.opened.contains(45300),
                     "A typed service port was mistaken for an old proxy listener")
        rotating.close()
        await wait { Bridge.closed.filter { $0 == 3300 }.count == 2 }
        let retiring = ProjectBrowserSession(owner: owner, peer: "closing-host", history: history, isCurrent: { true })
        await retiring.open("3400")
        Bridge.blockClose = true
        retiring.close()
        await wait { Bridge.pendingClose != nil }
        var waitingCurrent = true
        let waiting = ProjectBrowserSession(owner: nextOwner, peer: "closing-host", history: history, isCurrent: { waitingCurrent })
        let waitedOpen = Task { await waiting.open("3400") }
        await wait { waiting.isOpening }
        waitingCurrent = false
        Bridge.blockClose = false
        Bridge.pendingClose?.resume()
        Bridge.pendingClose = nil
        await waitedOpen.value
        precondition(Bridge.opened.filter { $0 == 3400 }.count == 1 && waiting.transportURL.isEmpty,
                     "A stale account started listening after awaiting retirement")
        waiting.close()
        Bridge.failListen = true
        Bridge.failClose = true
        let uncertain = ProjectBrowserSession(owner: owner, peer: "uncertain-host", history: history, isCurrent: { true })
        await uncertain.open("3500")
        await wait { Bridge.closed.contains(3500) }
        Bridge.failListen = false
        let retry = ProjectBrowserSession(owner: nextOwner, peer: "uncertain-host", history: history, isCurrent: { true })
        await retry.open("3500")
        await retry.open("3500")
        precondition(retry.transportURL.isEmpty && Bridge.opened.filter { $0 == 3500 }.count == 1,
                     "A lost listener answer and failed retirement were reused by another account")
        Bridge.failClose = false
        await retry.open("3500")
        precondition(!retry.transportURL.isEmpty && Bridge.opened.filter { $0 == 3500 }.count == 2,
                     "Confirmed retirement did not permit a fresh listener retry")
        retry.close()
        uncertain.close()
        await wait { Bridge.closed.filter { $0 == 3500 }.count >= 4 }
        history.record(BrowserTarget("3000")!, for: owner)
        var current = true
        let stale = ProjectBrowserSession(owner: owner, peer: "host-b", history: history, isCurrent: { current })
        Bridge.block = true
        let opening = Task { await stale.open("4000") }
        await wait { Bridge.pending != nil }
        precondition(stale.loadRevision == 0, "A pending bridge tried to reload the previous page")
        current = false
        stale.close()
        Bridge.pending?.resume(returning: Bridge.Reply(url: "http://127.0.0.1:45400/"))
        Bridge.pending = nil
        await opening.value
        await wait { Bridge.closed.contains(4000) }
        precondition(stale.transportURL.isEmpty && !history.entry(for: owner).ports.contains(4000),
                     "A late listener response published or persisted into a retired browser")
        print("Project browser: explicit opening, shared listener lifetime, canonical pages and stale cleanup passed")
    }
}
