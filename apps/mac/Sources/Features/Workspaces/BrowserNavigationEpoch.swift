// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum BrowserPageHistoryMutation: String {
    case push, replace, pop, snapshot
}

/// IDs belong to native history items, including different states at one URL.
struct BrowserPageHistoryItem {
    let id: UUID
    let url: String
}

struct BrowserPageHistoryTraversal {
    let id: UUID
    let direction: Int
}


/// A completion belongs to the navigation that started it, even after a new Go.
struct BrowserNavigationEpoch {
    struct Completion: Equatable {
        let generation: Int
        let registered: Bool
        var nativeHistoryID: UUID? = nil
    }
    var current = 0
    private var owners: [ObjectIdentifier: Completion] = [:]
    private var startedOwners = Set<ObjectIdentifier>()
    mutating func register(_ navigation: AnyObject?, generation: Int) {
        guard let navigation else { return }
        owners[ObjectIdentifier(navigation)] = Completion(generation: generation, registered: true)
    }
    mutating func started(_ navigation: AnyObject?) -> Bool {
        guard let navigation else { return false }
        let id = ObjectIdentifier(navigation)
        if owners[id] == nil { owners[id] = Completion(generation: current, registered: false) }
        startedOwners.insert(id)
        return owners[id]?.generation == current
    }
    mutating func finish(_ navigation: AnyObject?) -> Completion? {
        guard let navigation else { return nil }
        let id = ObjectIdentifier(navigation)
        startedOwners.remove(id)
        guard let owner = owners.removeValue(forKey: id),
              owner.generation == current else { return nil }
        return owner
    }

    /// Same-document native history emits popstate without navigation callbacks.
    mutating func abandonIfNotStarted(_ navigation: AnyObject?) {
        guard let navigation else { return }
        let id = ObjectIdentifier(navigation)
        if !startedOwners.contains(id) { owners.removeValue(forKey: id) }
    }
}

#if canImport(WebKit)
import WebKit

/// Shared by both project browsers; page messages never supply trusted URLs.
@MainActor
final class BrowserNativeHistory: NSObject, WKScriptMessageHandler {
    var generation = 0
    var onChange: (BrowserPageHistoryMutation, [BrowserPageHistoryItem], UUID, Int) -> Bool
    var onTraverse: ((Int, Int) -> Bool)?
    var onAbandon: (AnyObject?) -> Void
    private weak var webView: WKWebView?
    private var items: [UUID: WKBackForwardListItem] = [:]
    private var currentID: UUID?
    private var historyNavigation: WKNavigation?

    init(onChange: @escaping (BrowserPageHistoryMutation, [BrowserPageHistoryItem], UUID, Int) -> Bool,
         onTraverse: ((Int, Int) -> Bool)?, onAbandon: @escaping (AnyObject?) -> Void) {
        self.onChange = onChange
        self.onTraverse = onTraverse
        self.onAbandon = onAbandon
    }

    func install(in configuration: WKWebViewConfiguration) {
        let script = Self.script.replacingOccurrences(of: "CANONICAL_TRAVERSAL", with: onTraverse == nil ? "false" : "true")
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(self, name: Self.handler)
    }

    func attach(_ view: WKWebView, generation: Int) {
        webView = view
        self.generation = generation
    }

    func dismantle(_ view: WKWebView) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        onAbandon(historyNavigation)
        historyNavigation = nil
        items.removeAll()
        webView = nil
    }

    func load(_ view: WKWebView, url: URL, restoring id: UUID?) -> WKNavigation? {
        onAbandon(historyNavigation)
        historyNavigation = nil
        if let id, let item = items[id], item.url == url {
            // Live native items retain History API state and cached documents.
            let navigation = view.go(to: item)
            historyNavigation = navigation
            return navigation
        }
        return view.load(URLRequest(url: url))
    }

    func traversal(for action: WKNavigationAction, in view: WKWebView) -> BrowserPageHistoryTraversal? {
        guard action.navigationType == .backForward, let target = view.backForwardList.currentItem,
              target.url == action.request.url, let id = items.first(where: { $0.value === target })?.key else { return nil }
        // Policy sees the destination item while webView.url is still source.
        let list = view.backForwardList.backList + [target] + view.backForwardList.forwardList
        let source = currentID.flatMap { items[$0] }
        let sourceIndex = list.firstIndex(where: { $0 === source })
        let destinationIndex = view.backForwardList.backList.count
        let direction = sourceIndex.map { destinationIndex == $0 ? 0 : (destinationIndex < $0 ? -1 : 1) } ?? 0
        return BrowserPageHistoryTraversal(id: id, direction: direction)
    }

    @discardableResult
    func report(_ mutation: BrowserPageHistoryMutation, in view: WKWebView, generation: Int) -> UUID? {
        guard self.generation == generation, let current = view.backForwardList.currentItem,
              let actual = view.url?.absoluteString else { return nil }
        let list = view.backForwardList.backList + [current] + view.backForwardList.forwardList
        var selected: UUID?
        var live: [UUID: WKBackForwardListItem] = [:]
        let observations = list.map { item -> BrowserPageHistoryItem in
            let id = items.first(where: { $0.value === item })?.key ?? UUID()
            live[id] = item
            if item === current { selected = id }
            return BrowserPageHistoryItem(id: id, url: item === current ? actual : item.url.absoluteString)
        }
        items = live
        if let selected, onChange(mutation, observations, selected, generation) {
            currentID = selected
            if mutation == .pop {
                onAbandon(historyNavigation)
                historyNavigation = nil
            }
        }
        return selected
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = webView,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String,
              let documentID = body["documentID"] as? String else { return }
        let mutation = BrowserPageHistoryMutation(rawValue: kind)
        let delta = (body["delta"] as? NSNumber)?.intValue
        guard mutation != .snapshot, mutation != nil || (kind == "traverse" && delta != nil) else { return }
        let generation = self.generation
        // Late messages from a replaced document must not affect the new Go.
        view.evaluateJavaScript("window.__tokenstatHistoryDocument") { [weak self, weak view] active, _ in
            guard let self, let view, self.webView === view, self.generation == generation,
                  active as? String == documentID else { return }
            if let mutation { self.report(mutation, in: view, generation: generation) }
            else if let delta { _ = self.onTraverse?(delta, generation) }
        }
    }

    private static let handler = "tokenstatPageHistory"
    private static let script = """
    (() => {
        const documentID = String(Date.now()) + ":" + Math.random();
        window.__tokenstatHistoryDocument = documentID;
        const report = (kind, delta) => {
            const message = { kind, documentID };
            if (delta !== undefined) message.delta = delta;
            window.webkit.messageHandlers.tokenstatPageHistory.postMessage(message);
        };
        for (const [method, kind] of [["pushState", "push"], ["replaceState", "replace"]]) {
            const original = history[method];
            history[method] = function(...args) {
                const result = Reflect.apply(original, this, args);
                report(kind);
                return result;
            };
        }
        addEventListener("popstate", () => report("pop"));
        addEventListener("hashchange", () => report("push"));
        if (CANONICAL_TRAVERSAL) {
            for (const [method, step] of [["back", -1], ["forward", 1], ["go", 0]]) {
                const original = history[method];
                history[method] = function(...args) {
                    const delta = method === "go" ? Number(args[0]) | 0 : step;
                    if (delta === 0) return Reflect.apply(original, this, args);
                    report("traverse", delta);
                };
            }
        }
    })();
    """
}
#endif
