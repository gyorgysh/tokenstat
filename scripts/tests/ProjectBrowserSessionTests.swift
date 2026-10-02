// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkReference.swift, BrowserHistory.swift, BrowserNavigationEpoch.swift and ProjectBrowserSession.swift.
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
    static var blockedPort: Int?
    static var listenerOffset = 0
    static var blockClose = false
    static var pendingClose: CheckedContinuation<Void, Never>?
    static func proxyListen(peer: String, host: String, port: Int) async throws -> Reply {
        opened.append(port)
        if failListen { throw Failure.transport }
        if block, blockedPort == nil || blockedPort == port { return try await withCheckedThrowingContinuation { pending = $0 } }
        return Reply(url: "http://127.0.0.1:\(45000 + port % 1000 + listenerOffset)/")
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
        let readinessURL = URL(string: "http://127.0.0.1:45000/")!
        var probes = 0
        let ready = await BrowserServiceReadiness.wait(readinessURL, isCurrent: { true }, timeout: 2) { _ in
            probes += 1
            return probes == 3
        }
        precondition(ready && probes == 3, "A slow agent web UI loaded before its service was ready")
        var readinessCurrent = true
        let staleReady = await BrowserServiceReadiness.wait(readinessURL, isCurrent: { readinessCurrent }) { _ in
            readinessCurrent = false
            return true
        }
        precondition(!staleReady, "A service readiness answer reopened a retired browser")
        let timedOut = await BrowserServiceReadiness.wait(readinessURL, isCurrent: { true }, timeout: 0) { _ in
            preconditionFailure("An expired readiness check still sent a request")
        }
        precondition(!timedOut)
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

        let navigating = ProjectBrowserSession(owner: owner, peer: "history-host", history: history, isCurrent: { true })
        await navigating.open("http://localhost:4100/first")
        navigating.observed(navigating.transportURL)
        // A link on the same listener is a second page, not a replacement.
        navigating.observed("http://127.0.0.1:45100/second", registered: false)
        await navigating.open("http://localhost:4200/third")
        navigating.observed(navigating.transportURL)
        await wait { Bridge.closed.contains(4100) }
        precondition(navigating.canGoBack && !navigating.canGoForward)
        Bridge.listenerOffset = 1
        await navigating.goBack()
        precondition(navigating.targetURL == "http://localhost:4100/second")
        precondition(navigating.transportURL == "http://127.0.0.1:45101/second",
                     "Back did not reacquire a fresh listener for its canonical page")
        navigating.observed(navigating.transportURL)
        precondition(navigating.canGoBack && navigating.canGoForward)
        await navigating.goBack()
        navigating.observed(navigating.transportURL)
        precondition(navigating.targetURL == "http://localhost:4100/first" && !navigating.canGoBack,
                     "Back appended its replacement URL and became trapped on the second page")
        await navigating.goForward()
        navigating.observed(navigating.transportURL)
        precondition(navigating.targetURL == "http://localhost:4100/second")
        await navigating.goForward()
        navigating.observed(navigating.transportURL)
        precondition(navigating.targetURL == "http://localhost:4200/third" && !navigating.canGoForward)
        await navigating.goBack()
        navigating.observed(navigating.transportURL)
        await navigating.open("http://localhost:4100/new-branch")
        navigating.observed(navigating.transportURL)
        precondition(!navigating.canGoForward, "A new navigation retained an abandoned forward branch")
        navigating.close()
        Bridge.listenerOffset = 0

        let spa = ProjectBrowserSession(owner: owner, peer: "spa-host", history: history, isCurrent: { true })
        await spa.open("http://localhost:4300/app")
        spa.observed(spa.transportURL)
        let initialItem = BrowserPageHistoryItem(id: UUID(), url: spa.transportURL)
        let firstState = BrowserPageHistoryItem(id: UUID(), url: spa.transportURL)
        let secondState = BrowserPageHistoryItem(id: UUID(), url: spa.transportURL)
        let generation = spa.navigationGeneration
        precondition(spa.observedHistory(.snapshot, items: [initialItem], currentID: initialItem.id, generation: generation))
        // A synchronous replace/push burst may finish before its first message.
        precondition(spa.observedHistory(.replace, items: [initialItem, firstState, secondState],
            currentID: secondState.id, generation: generation))
        // Both pushes use the same URL, and can arrive in one native snapshot.
        precondition(spa.observedHistory(.push, items: [initialItem, firstState, secondState],
            currentID: secondState.id, generation: generation))
        await spa.goBack()
        precondition(spa.historyItemToRestore == firstState.id,
                     "Same-URL Back lost the native item's History API state")
        precondition(!spa.observedHistory(.push, items: [initialItem, firstState, secondState],
            currentID: secondState.id, generation: generation), "A stale document mutation replaced Back")
        precondition(spa.observedHistory(.pop, items: [initialItem, firstState, secondState],
            currentID: firstState.id, generation: spa.navigationGeneration))
        spa.observed(firstState.url, registered: true)
        precondition(spa.canGoBack && spa.canGoForward, "A completion duplicated a History API pop")
        let replaced = BrowserPageHistoryItem(id: firstState.id, url: "http://127.0.0.1:45300/replaced")
        precondition(spa.observedHistory(.replace, items: [initialItem, replaced, secondState],
            currentID: replaced.id, generation: spa.navigationGeneration))
        await spa.goBack()
        precondition(spa.historyItemToRestore == initialItem.id && spa.targetURL == "http://localhost:4300/app",
                     "replaceState appended a page instead of replacing its current entry")
        spa.observed(initialItem.url)
        precondition(!spa.canGoBack && spa.canGoForward)
        await spa.goForward()
        precondition(spa.historyItemToRestore == firstState.id && spa.targetURL == "http://localhost:4300/replaced")
        spa.observed(replaced.url)
        let branch = BrowserPageHistoryItem(id: UUID(), url: "http://127.0.0.1:45300/branch")
        precondition(spa.observedHistory(.push, items: [initialItem, replaced, branch],
            currentID: branch.id, generation: spa.navigationGeneration) && !spa.canGoForward,
                     "A History API push retained an abandoned forward branch")
        spa.close()
        precondition(!spa.observedHistory(.pop, items: [initialItem], currentID: initialItem.id,
            generation: spa.navigationGeneration), "A retired document changed canonical history")

        let boot = ProjectBrowserSession(owner: owner, peer: nil, history: history, isCurrent: { true })
        await boot.open("http://localhost:4400/app")
        let bootInitial = BrowserPageHistoryItem(id: UUID(), url: boot.transportURL)
        let bootPush = BrowserPageHistoryItem(id: UUID(), url: "http://localhost:4400/boot-route")
        boot.observed(bootPush.url)
        precondition(boot.observedHistory(.snapshot, items: [bootInitial, bootPush],
            currentID: bootPush.id, generation: boot.navigationGeneration) && boot.canGoBack,
                     "A router push during document loading disappeared at completion")
        await boot.goBack()
        precondition(boot.historyItemToRestore == bootInitial.id && boot.targetURL == bootInitial.url)
        boot.close()

        let native = ProjectBrowserSession(owner: owner, peer: nil, history: history, isCurrent: { true })
        await native.open("http://localhost:4500/a")
        native.observed(native.transportURL)
        let nativeA = BrowserPageHistoryItem(id: UUID(), url: native.transportURL)
        let nativeB = BrowserPageHistoryItem(id: UUID(), url: native.transportURL)
        native.observedHistory(.snapshot, items: [nativeA], currentID: nativeA.id, generation: native.navigationGeneration)
        // A new full document can reuse the same URL as the current document.
        native.observed(nativeB.url, registered: false, nativeHistoryID: nativeB.id)
        native.observedHistory(.snapshot, items: [nativeA, nativeB], currentID: nativeB.id, generation: native.navigationGeneration)
        await native.goBack()
        precondition(native.historyItemToRestore == nativeA.id && !native.canGoBack,
                     "A same-URL full document replaced the preceding page")
        native.observedHistory(.pop, items: [nativeA, nativeB], currentID: nativeA.id, generation: native.navigationGeneration)
        precondition(!native.canGoBack && native.canGoForward)
        // A popup registers its load, but is a new page rather than Reload.
        let popup = BrowserPageHistoryItem(id: UUID(), url: "http://localhost:4500/popup")
        native.observed(popup.url, registered: true, nativeHistoryID: popup.id)
        native.observedHistory(.snapshot, items: [nativeA, popup], currentID: popup.id, generation: native.navigationGeneration)
        precondition(native.canGoBack && !native.canGoForward, "A popup discarded its source page")
        native.observed(popup.url, registered: true, nativeHistoryID: popup.id)
        await native.goBack()
        native.observedHistory(.pop, items: [nativeA, popup], currentID: nativeA.id, generation: native.navigationGeneration)
        precondition(!native.canGoBack, "Reload appended an extra canonical entry")
        native.close()

        let delayed = ProjectBrowserSession(owner: owner, peer: nil, history: history, isCurrent: { true })
        await delayed.open("http://localhost:4600/a")
        delayed.observed(delayed.transportURL)
        let delayedA = BrowserPageHistoryItem(id: UUID(), url: delayed.transportURL)
        let delayedB = BrowserPageHistoryItem(id: UUID(), url: "http://localhost:4600/b")
        delayed.observedHistory(.snapshot, items: [delayedA], currentID: delayedA.id, generation: delayed.navigationGeneration)
        delayed.observedHistory(.push, items: [delayedA, delayedB], currentID: delayedA.id, generation: delayed.navigationGeneration)
        delayed.observedHistory(.pop, items: [delayedA, delayedB], currentID: delayedA.id, generation: delayed.navigationGeneration)
        precondition(!delayed.canGoBack && delayed.canGoForward, "pushState followed by Back lost native Forward")
        await delayed.goForward()
        precondition(delayed.historyItemToRestore == delayedB.id)
        delayed.close()

        let pageBack = ProjectBrowserSession(owner: owner, peer: "page-back-host", history: history, isCurrent: { true })
        await pageBack.open("http://localhost:4700/a")
        pageBack.observed(pageBack.transportURL)
        let pageA = BrowserPageHistoryItem(id: UUID(), url: pageBack.transportURL)
        pageBack.observedHistory(.snapshot, items: [pageA], currentID: pageA.id, generation: pageBack.navigationGeneration)
        await pageBack.open("http://localhost:4800/b")
        pageBack.observed(pageBack.transportURL)
        let pageB = BrowserPageHistoryItem(id: UUID(), url: pageBack.transportURL)
        pageBack.observedHistory(.snapshot, items: [pageA, pageB], currentID: pageB.id, generation: pageBack.navigationGeneration)
        Bridge.listenerOffset = 2
        precondition(pageBack.intercept(URLRequest(url: URL(string: pageA.url)!), isMainFrame: true, historyItemID: pageA.id))
        await wait { pageBack.targetURL == "http://localhost:4700/a" }
        pageBack.observed(pageBack.transportURL)
        let replayA = BrowserPageHistoryItem(id: UUID(), url: pageBack.transportURL)
        pageBack.observedHistory(.snapshot, items: [pageA, pageB, replayA], currentID: replayA.id, generation: pageBack.navigationGeneration)
        precondition(!pageBack.canGoBack && pageBack.canGoForward,
                     "Page history.back replay appended its retired listener and trapped Back")
        // The original native ID still identifies the same canonical entry.
        pageBack.observedHistory(.pop, items: [pageA, pageB, replayA], currentID: pageA.id, generation: pageBack.navigationGeneration)
        precondition(!pageBack.canGoBack && pageBack.canGoForward, "Replay lost its original native history alias")
        await pageBack.goForward()
        pageBack.observed(pageBack.transportURL)
        let replayB = BrowserPageHistoryItem(id: UUID(), url: pageBack.transportURL)
        pageBack.observedHistory(.snapshot, items: [pageA, pageB, replayA, replayB], currentID: replayB.id, generation: pageBack.navigationGeneration)
        precondition(pageBack.intercept(URLRequest(url: URL(string: pageB.url)!), isMainFrame: true,
            historyItemID: pageB.id, historyDirection: -1))
        await wait { pageBack.targetURL == "http://localhost:4700/a" }
        pageBack.observed(pageBack.transportURL)
        precondition(!pageBack.canGoBack && pageBack.canGoForward,
                     "Page Back became trapped on a native copy of the current canonical page")
        let revisionAtStart = pageBack.loadRevision
        precondition(pageBack.intercept(URLRequest(url: URL(string: replayB.url)!), isMainFrame: true,
            historyItemID: replayB.id, historyDirection: -1))
        await Task.yield()
        precondition(pageBack.loadRevision == revisionAtStart && pageBack.targetURL == "http://localhost:4700/a",
                     "Native Back at canonical start followed a forward alias")
        // Canonical replay physically has no native Forward item. Site Forward
        // still traverses the saved entry through the scoped History API hook.
        precondition(pageBack.traverseHistory(1, generation: pageBack.navigationGeneration))
        await wait { pageBack.targetURL == "http://localhost:4800/b" }
        pageBack.observed(pageBack.transportURL)
        precondition(!pageBack.canGoForward && pageBack.canGoBack)
        precondition(!pageBack.traverseHistory(Int.max, generation: pageBack.navigationGeneration)
                     && !pageBack.traverseHistory(-1, generation: pageBack.navigationGeneration - 1))
        await pageBack.goBack()
        pageBack.observed(pageBack.transportURL)
        let replacedA = BrowserPageHistoryItem(id: UUID(), url: pageBack.transportURL.replacingOccurrences(of: "/a", with: "/replaced"))
        pageBack.observedHistory(.snapshot, items: [pageA, pageB, replayA, replayB, replacedA],
            currentID: replacedA.id, generation: pageBack.navigationGeneration)
        pageBack.observedHistory(.replace, items: [pageA, pageB, replayA, replayB, replacedA],
            currentID: replacedA.id, generation: pageBack.navigationGeneration)
        await pageBack.goForward()
        pageBack.observed(pageBack.transportURL)
        precondition(pageBack.intercept(URLRequest(url: URL(string: pageA.url)!), isMainFrame: true,
            historyItemID: pageA.id, historyDirection: -1))
        await wait { pageBack.targetURL == "http://localhost:4700/replaced" }
        pageBack.observed(pageBack.transportURL)
        precondition(!pageBack.canGoBack, "An old native alias reverted replaceState's canonical URL")
        pageBack.close()
        Bridge.listenerOffset = 0

        let direction = ProjectBrowserSession(owner: owner, peer: nil, history: history, isCurrent: { true })
        var directionItems: [BrowserPageHistoryItem] = []
        for path in ["a", "b", "c"] {
            await direction.open("http://localhost:4900/\(path)")
            direction.observed(direction.transportURL)
            let item = BrowserPageHistoryItem(id: UUID(), url: direction.transportURL)
            directionItems.append(item)
            direction.observedHistory(.snapshot, items: directionItems, currentID: item.id, generation: direction.navigationGeneration)
        }
        await direction.goBack()
        direction.observed(direction.transportURL)
        precondition(direction.targetURL == "http://localhost:4900/b")
        // Native replay can put old C physically behind the current B.
        precondition(direction.intercept(URLRequest(url: URL(string: directionItems[2].url)!), isMainFrame: true,
            historyItemID: directionItems[2].id, historyDirection: -1))
        await wait { direction.targetURL == "http://localhost:4900/a" }
        direction.observed(direction.transportURL)
        precondition(!direction.canGoBack && direction.canGoForward,
                     "Native Back followed a forward alias even on the live listener")
        direction.close()

        let rapid = ProjectBrowserSession(owner: owner, peer: "rapid-back-host", history: history, isCurrent: { true })
        for port in [5001, 5002, 5003] {
            await rapid.open("http://localhost:\(port)/")
            rapid.observed(rapid.transportURL)
        }
        Bridge.block = true
        Bridge.blockedPort = 5002
        let slowBack = Task { await rapid.goBack() }
        await wait { Bridge.pending != nil && rapid.isOpening }
        let blockedReply = Bridge.pending
        Bridge.pending = nil
        await rapid.goBack()
        precondition(rapid.targetURL == "http://localhost:5001/", "Two quick Back actions both targeted the same pending entry")
        rapid.observed(rapid.transportURL)
        Bridge.block = false
        Bridge.blockedPort = nil
        blockedReply?.resume(returning: Bridge.Reply(url: "http://127.0.0.1:45002/"))
        await slowBack.value
        precondition(rapid.targetURL == "http://localhost:5001/" && !rapid.canGoBack,
                     "A late intermediate listener response replaced the final Back")
        rapid.close()

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
        print("Project browser: explicit opening, shared listeners, canonical/native Back/Forward, SPA history and stale cleanup passed")
    }
}
