// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with BrowserNavigationEpoch.swift.
import Foundation
#if os(macOS)
import AppKit
import WebKit

@MainActor private final class Page: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    var finished = 0
    var epochs = BrowserNavigationEpoch()
    func webView(_ view: WKWebView, start task: WKURLSchemeTask) {
        let data = Data("<html><body>History test</body></html>".utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ view: WKWebView, stop task: WKURLSchemeTask) {}
    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { _ = epochs.started(navigation) }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { _ = epochs.finish(navigation); finished += 1 }
}

@main struct BrowserNativeHistoryTests {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(condition(), "A native browser event timed out")
    }
    @MainActor static func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result) }
            }
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let page = Page()
        page.epochs.current = 1
        var mutations: [BrowserPageHistoryMutation] = []
        var snapshot: [BrowserPageHistoryItem] = []
        var traversals: [Int] = []
        let history = BrowserNativeHistory(onChange: { mutation, items, _, _ in
            mutations.append(mutation)
            snapshot = items
            return true
        }, onTraverse: { delta, _ in traversals.append(delta); return true }, onAbandon: { page.epochs.abandonIfNotStarted($0) })
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(page, forURLScheme: "tokenstat-history-test")
        history.install(in: configuration)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = page
        history.attach(view, generation: 1)
        page.epochs.register(view.load(URLRequest(url: URL(string: "tokenstat-history-test://page/app")!)), generation: 1)
        await wait { page.finished == 1 }
        history.report(.snapshot, in: view, generation: 1)
        let initial = view.backForwardList.currentItem!
        _ = try await js(view, "window.marker = 'cached'; history.replaceState({step:0}, '', location.href); history.pushState({step:1}, '', location.href); history.pushState({step:2}, '', location.href); window.pops = 0; addEventListener('popstate', () => window.pops++); true")
        await wait { mutations.contains(.replace) && mutations.filter { $0 == .push }.count == 2 }
        precondition(snapshot.count == 3 && Set(snapshot.map(\.id)).count == 3,
                     "Same-URL pushes lost native history item identities")
        precondition(view.backForwardList.backList.first === initial, "replaceState changed the native item identity")
        let firstState = snapshot[1]
        page.epochs.current = 2
        history.attach(view, generation: 2)
        let navigation = history.load(view, url: URL(string: firstState.url)!, restoring: firstState.id)
        page.epochs.register(navigation, generation: 2)
        await wait { mutations.contains(.pop) }
        let state = try await js(view, "JSON.stringify({state:history.state,marker:window.marker,pops:window.pops})") as! String
        precondition(state.contains("\"step\":1") && state.contains("\"marker\":\"cached\"") && state.contains("\"pops\":1"), state)
        precondition(page.finished == 1, "A same-document restoration reloaded the page")
        // The scoped traversal hook works independently of native forwardList.
        _ = try await js(view, "history.forward(); history.back(); history.go(-2); true")
        await wait { traversals.count == 3 }
        precondition(traversals == [1, -1, -2])
        _ = try await js(view, "history.go(0); true")
        await wait { page.finished == 2 }
        precondition(traversals.count == 3, "go(0) stopped being a native reload")
        view.load(URLRequest(url: URL(string: "tokenstat-history-test://page/other")!))
        await wait { page.finished == 3 }
        precondition(view.backForwardList.forwardList.isEmpty)
        _ = try await js(view, "history.forward(); true")
        await wait { traversals.count == 4 }
        precondition(traversals.last == 1, "An empty native Forward list swallowed scoped site Forward")
        history.dismantle(view)

        let ordinaryPage = Page()
        var ordinaryPop = false
        let ordinary = BrowserNativeHistory(onChange: { mutation, _, _, _ in
            if mutation == .pop { ordinaryPop = true }
            return true
        }, onTraverse: nil, onAbandon: { _ in })
        let ordinaryConfiguration = WKWebViewConfiguration()
        ordinaryConfiguration.setURLSchemeHandler(ordinaryPage, forURLScheme: "tokenstat-history-test")
        ordinary.install(in: ordinaryConfiguration)
        let ordinaryView = WKWebView(frame: .zero, configuration: ordinaryConfiguration)
        ordinaryView.navigationDelegate = ordinaryPage
        ordinary.attach(ordinaryView, generation: 0)
        ordinaryView.load(URLRequest(url: URL(string: "tokenstat-history-test://page/app")!))
        await wait { ordinaryPage.finished == 1 }
        _ = try await js(ordinaryView, "history.replaceState({step:0}, '', location.href); history.pushState({step:1}, '', location.href); true")
        _ = try await js(ordinaryView, "history.back(); true")
        await wait { ordinaryPop }
        let ordinaryState = try await js(ordinaryView, "history.state.step") as! Int
        precondition(ordinaryState == 0, "An unscoped browser lost its native History API traversal")
        ordinary.dismantle(ordinaryView)
        print("Native browser history: same-URL states, replacement, cached document, popstate, scoped traversal and go(0) passed")
    }
}
#else
@main struct BrowserNativeHistoryTests { static func main() {} }
#endif
