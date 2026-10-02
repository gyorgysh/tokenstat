// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// Shared listeners survive closing one of several pages using the same port.
@MainActor
private final class ProjectBrowserBridges {
    static let shared = ProjectBrowserBridges()
    struct Lease {
        let key: String
        let token: UUID
        let url: String
    }
    private final class Entry {
        let peer: String
        let target: BrowserTarget
        let scope: WorkReference.Scope?
        let task: Task<String, Error>
        var tokens = Set<UUID>()
        var closing: Task<Void, Error>?
        init(peer: String, target: BrowserTarget, scope: WorkReference.Scope?, isCurrent: @escaping () -> Bool) {
            self.peer = peer
            self.target = target
            self.scope = scope
            task = Task {
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                return try await Bridge.proxyListen(peer: peer, host: target.bridgeHost, port: target.port).url
            }
        }
    }
    private var entries: [String: Entry] = [:]

    func acquire(peer: String, target: BrowserTarget, scope: WorkReference.Scope?, isCurrent: @escaping () -> Bool) async throws -> Lease {
        let key = [peer, target.bridgeHost, String(target.port)].map(WorkReferenceKey.encode).joined(separator: "|")
        while let prior = entries[key] {
            if prior.scope != scope || prior.tokens.isEmpty { retire(key: key, entry: prior) }
            guard let closing = prior.closing else { break }
            do { try await closing.value }
            catch {
                if entries[key] === prior { prior.closing = nil }
                throw error
            }
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            if entries[key] === prior { entries[key] = nil }
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let entry = entries[key] ?? Entry(peer: peer, target: target, scope: scope, isCurrent: isCurrent)
        entries[key] = entry
        let token = UUID()
        entry.tokens.insert(token)
        do {
            return Lease(key: key, token: token, url: try await entry.task.value)
        } catch {
            release(key: key, token: token)
            throw error
        }
    }

    func release(_ lease: Lease) { release(key: lease.key, token: lease.token) }
    private func release(key: String, token: UUID) {
        guard let entry = entries[key], entry.tokens.remove(token) != nil, entry.tokens.isEmpty else { return }
        retire(key: key, entry: entry)
    }
    private func retire(key: String, entry: Entry) {
        guard entry.closing == nil else { return }
        entry.tokens.removeAll()
        entry.closing = Task {
            _ = try? await entry.task.value
            try await Bridge.proxyUnlistenConfirmed(peer: entry.peer, host: entry.target.bridgeHost, port: entry.target.port)
            if self.entries[key] === entry { self.entries[key] = nil }
        }
    }
}

/// One explicitly opened browser, with a canonical address and transport ownership.
@MainActor @Observable
final class ProjectBrowserSession: Identifiable {
    let id = UUID()
    let owner: WorkReference?
    let peer: String?
    private(set) var targetURL: String
    private(set) var transportURL = ""
    private(set) var error: String?
    private(set) var isOpening = false
    private(set) var isClosed = false
    private(set) var navigationGeneration = 0
    private(set) var loadRevision = 0
    @ObservationIgnored private let isCurrent: () -> Bool
    @ObservationIgnored private let history: BrowserHistory
    @ObservationIgnored private var leases: [String: ProjectBrowserBridges.Lease] = [:]
    @ObservationIgnored private var pendingExplicitNavigation = false
    @ObservationIgnored private var pendingHistoryIndex: Int?
    @ObservationIgnored private var targets: [String: BrowserTarget] = [:]
    private struct Page {
        var url: String
        var nativeID: UUID?
        var nativeIDs = Set<UUID>()
        init(url: String, nativeID: UUID?) {
            self.url = url
            self.nativeID = nativeID
            if let nativeID { nativeIDs.insert(nativeID) }
        }
    }
    private var pageHistory: [Page] = []
    private var pageHistoryIndex = -1

    init(owner: WorkReference?, peer: String?, history: BrowserHistory? = nil,
         isCurrent: @escaping () -> Bool) {
        self.owner = owner
        self.peer = peer
        self.history = history ?? .shared
        self.isCurrent = isCurrent
        targetURL = self.history.entry(for: owner).lastTarget ?? ""
    }

    var recentPorts: [Int] { history.entry(for: owner).ports }
    private var requestedHistoryIndex: Int { pendingHistoryIndex ?? pageHistoryIndex }
    var canGoBack: Bool { requestedHistoryIndex > 0 }
    var canGoForward: Bool { requestedHistoryIndex + 1 < pageHistory.count }
    var historyItemToRestore: UUID? {
        guard let index = pendingHistoryIndex, pageHistory.indices.contains(index) else { return nil }
        return pageHistory[index].nativeID
    }

    @discardableResult
    func traverseHistory(_ delta: Int, generation: Int) -> Bool {
        guard !isClosed, isCurrent(), !pendingExplicitNavigation, generation == navigationGeneration,
              pageHistory.indices.contains(pageHistoryIndex), delta != 0,
              delta >= -pageHistoryIndex, delta <= pageHistory.count - 1 - pageHistoryIndex else { return false }
        let index = pageHistoryIndex + delta
        let address = pageHistory[index].url
        Task {
            guard navigationGeneration == generation else { return }
            await open(address, restoringHistoryAt: index)
        }
        return true
    }

    func goBack() async {
        guard canGoBack else { return }
        let index = requestedHistoryIndex - 1
        await open(pageHistory[index].url, restoringHistoryAt: index)
    }

    func goForward() async {
        guard canGoForward else { return }
        let index = requestedHistoryIndex + 1
        await open(pageHistory[index].url, restoringHistoryAt: index)
    }

    func canonicalURL(_ actual: String) -> String {
        for (listener, target) in targets {
            if let original = target.originalURL(for: actual, through: listener) { return original }
        }
        return actual
    }

    /// Remote loopback requests must use this page's live listener or be intercepted.
    func intercepts(_ actual: URL) -> Bool {
        guard peer != nil, let host = actual.host, BrowserTarget.isLoopback(host),
              ["http", "https"].contains(actual.scheme?.lowercased() ?? "") else { return false }
        guard !isClosed, isCurrent(), BrowserTarget(actual.absoluteString) != nil else { return true }
        return !leases.values.contains { lease in
            URLComponents(string: lease.url)?.host == actual.host && URLComponents(string: lease.url)?.port == actual.port
        }
    }

    func intercept(_ request: URLRequest, isMainFrame: Bool, historyItemID: UUID? = nil, historyDirection: Int = 0) -> Bool {
        guard let url = request.url else { return false }
        let mappedIndex = historyItemID.flatMap { pageIndex(for: $0) }
        let redirectsHistory = !pendingExplicitNavigation && historyDirection != 0
            && (mappedIndex == nil || (historyDirection < 0 ? mappedIndex! >= pageHistoryIndex : mappedIndex! <= pageHistoryIndex))
        let replaysHistory = mappedIndex.map { canonicalURL(url.absoluteString) != pageHistory[$0].url } ?? false
        guard redirectsHistory || replaysHistory || intercepts(url) else { return false }
        guard isMainFrame, (request.httpMethod ?? "GET").uppercased() == "GET" else {
            error = L10n.text("apple.projectbrowsersession.open_this_service_s_address_first_this_req.4a65188f")
            return true
        }
        var restoring = pendingExplicitNavigation ? pendingHistoryIndex : mappedIndex
        var address = restoring.map { pageHistory[$0].url } ?? canonicalURL(url.absoluteString)
        if redirectsHistory {
            // Replaying a retired listener creates another native copy of the
            // same canonical entry. Native traversal can also select an alias
            // on the opposite side of canonical history; skip those copies.
            let index = pageHistoryIndex + (historyDirection < 0 ? -1 : 1)
            guard pageHistory.indices.contains(index) else { return true }
            restoring = index
            address = pageHistory[index].url
        }
        let generation = navigationGeneration
        Task {
            guard navigationGeneration == generation else { return }
            await open(address, restoringHistoryAt: restoring)
        }
        return true
    }

    func open(_ raw: String, waitsForService: Bool = false) async {
        await open(raw, waitsForService: waitsForService, restoringHistoryAt: nil)
    }

    private func open(_ raw: String, waitsForService: Bool = false, restoringHistoryAt: Int?) async {
        guard !isClosed, isCurrent() else { return }
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = BrowserTarget(original)
        guard !original.isEmpty, original.count <= 4096,
              original.rangeOfCharacter(from: .controlCharacters) == nil,
              let parsed = URL(string: target?.url ?? original),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil,
              (1...65535).contains(parsed.port ?? (parsed.scheme?.lowercased() == "https" ? 443 : 80)) else {
            error = L10n.text("apple.projectbrowsersession.enter_a_valid_web_address_or_a_port_from_1.e9b5ccfb")
            return
        }
        if peer != nil {
            guard owner != nil else {
                error = L10n.text("apple.projectbrowsersession.account_and_computer_details_are_still_loa.b02ad4d1")
                return
            }
            if let target, !["127.0.0.1", "::1"].contains(target.bridgeHost) {
                error = L10n.text("apple.projectbrowsersession.use_localhost_127_0_0_1_or_1_for_a_service.2d6046af")
                return
            }
        }
        navigationGeneration += 1
        pendingExplicitNavigation = true
        pendingHistoryIndex = restoringHistoryAt
        let operation = navigationGeneration
        isOpening = true
        error = nil
        defer { if navigationGeneration == operation { isOpening = false } }
        do {
            var transport = parsed.absoluteString
            if let peer, let target {
                let endpoint = "\(target.bridgeHost)|\(target.port)"
                // A page needs one live endpoint. Keep old address mappings for Back,
                // which reacquires its listener instead of retaining every visited port.
                for (key, old) in leases where key != endpoint {
                    ProjectBrowserBridges.shared.release(old)
                    leases[key] = nil
                }
                let lease: ProjectBrowserBridges.Lease
                if let existing = leases[endpoint] { lease = existing }
                else {
                    lease = try await ProjectBrowserBridges.shared.acquire(peer: peer, target: target, scope: owner?.scope, isCurrent: isCurrent)
                    guard navigationGeneration == operation, isCurrent(), !Task.isCancelled else {
                        ProjectBrowserBridges.shared.release(lease)
                        return
                    }
                    leases[endpoint] = lease
                }
                targets[lease.url] = target
                guard let bridged = target.transportURL(through: lease.url) else { return }
                transport = bridged
            }
            guard navigationGeneration == operation, isCurrent(), !Task.isCancelled else { return }
            if waitsForService, peer != nil, let url = URL(string: transport) {
                _ = await BrowserServiceReadiness.wait(url, isCurrent: {
                    !self.isClosed && self.navigationGeneration == operation && self.isCurrent()
                })
                guard navigationGeneration == operation, isCurrent(), !Task.isCancelled else { return }
            }
            targetURL = target?.url ?? parsed.absoluteString
            transportURL = transport
            loadRevision += 1
            if let target { history.record(target, for: owner) }
        } catch {
            guard navigationGeneration == operation, isCurrent(), !Task.isCancelled else { return }
            pendingExplicitNavigation = false
            pendingHistoryIndex = nil
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func observed(_ actual: String, generation: Int? = nil, registered: Bool = true, nativeHistoryID: UUID? = nil) -> Bool {
        guard !isClosed, isCurrent(), generation == nil || generation == navigationGeneration,
              registered || !pendingExplicitNavigation else { return false }
        let original = canonicalURL(actual)
        // Only completed pages enter canonical history. The native history
        // contains disposable listener addresses, so replaying it after a
        // port change would append a replacement page and trap Back in a loop.
        if pendingExplicitNavigation, let index = pendingHistoryIndex, pageHistory.indices.contains(index) {
            pageHistoryIndex = index
            pageHistory[index].url = original
        } else if registered && !pendingExplicitNavigation, pageHistory.indices.contains(pageHistoryIndex),
                  nativeHistoryID == nil || nativeHistoryID == pageHistory[pageHistoryIndex].nativeID {
            pageHistory[pageHistoryIndex].url = original
        } else if pendingExplicitNavigation || !pageHistory.indices.contains(pageHistoryIndex)
                    || pageHistory[pageHistoryIndex].url != original
                    || (nativeHistoryID != nil && nativeHistoryID != pageHistory[pageHistoryIndex].nativeID) {
            pageHistory = Array(pageHistory.prefix(pageHistoryIndex + 1))
            pageHistory.append(Page(url: original, nativeID: nil))
            pageHistoryIndex = pageHistory.count - 1
        }
        if registered {
            pendingExplicitNavigation = false
            pendingHistoryIndex = nil
        }
        targetURL = original
        transportURL = actual
        if let target = BrowserTarget(original) { history.record(target, for: owner) }
        return true
    }

    /// WebKit remains authoritative for same-document history and its states.
    /// Canonical entries only replay a URL when its native listener has retired.
    @discardableResult
    func observedHistory(_ mutation: BrowserPageHistoryMutation, items: [BrowserPageHistoryItem],
                         currentID: UUID, generation: Int) -> Bool {
        guard !isClosed, isCurrent(), generation == navigationGeneration,
              let current = items.first(where: { $0.id == currentID }) else { return false }
        if pendingExplicitNavigation {
            guard mutation == .pop, let index = pendingHistoryIndex,
                  pageHistory.indices.contains(index), pageHistory[index].nativeIDs.contains(currentID) else { return false }
            return observed(current.url, generation: generation)
        }
        guard pageHistory.indices.contains(pageHistoryIndex) else { return false }
        let end = items.firstIndex(where: { $0.id == currentID })!
        switch mutation {
        case .push, .replace, .pop:
            // A snapshot can already include later pushes or a following Back.
            // Reconcile native IDs, including items currently in Forward.
            if let index = pageIndex(for: currentID) {
                pageHistoryIndex = index
            } else if let prior = items[..<end].lastIndex(where: { pageIndex(for: $0.id) != nil }),
                      let index = pageIndex(for: items[prior].id) {
                pageHistoryIndex = appendHistory(Array(items[(prior + 1)...end]), after: index)
            } else if mutation == .push {
                pageHistoryIndex = appendHistory([current], after: pageHistoryIndex)
            } else if mutation == .pop {
                return false
            }
        case .snapshot:
            if pageHistory[pageHistoryIndex].nativeID == nil {
                // Routers can push before the first completed document load.
                let previous = pageHistoryIndex > 0 ? items[..<end].lastIndex(where: {
                    pageHistory[pageHistoryIndex - 1].nativeIDs.contains($0.id)
                }) : nil
                let start = previous.map { $0 + 1 } ?? (pageHistoryIndex == 0 ? 0 : end)
                pageHistoryIndex = appendHistory(Array(items[start...end]), after: pageHistoryIndex - 1)
            }
        }
        attach(current, at: pageHistoryIndex)
        let selected = pageHistoryIndex
        var forwardIndex = selected
        for item in items.dropFirst(end + 1) {
            if let index = pageIndex(for: item.id) { forwardIndex = index }
            else if forwardIndex >= selected {
                forwardIndex = appendHistory([item], after: forwardIndex)
            }
        }
        pageHistoryIndex = pageIndex(for: currentID) ?? selected
        targetURL = pageHistory[pageHistoryIndex].url
        transportURL = current.url
        if let target = BrowserTarget(targetURL) { history.record(target, for: owner) }
        return true
    }

    private func pageIndex(for nativeID: UUID) -> Int? {
        pageHistory.firstIndex(where: { $0.nativeIDs.contains(nativeID) })
    }

    private func attach(_ item: BrowserPageHistoryItem, at index: Int) {
        pageHistory[index].url = canonicalURL(item.url)
        pageHistory[index].nativeID = item.id
        pageHistory[index].nativeIDs.insert(item.id)
    }

    private func appendHistory(_ items: [BrowserPageHistoryItem], after index: Int) -> Int {
        pageHistory = Array(pageHistory.prefix(index + 1))
        pageHistory.append(contentsOf: items.map { Page(url: canonicalURL($0.url), nativeID: $0.id) })
        return pageHistory.count - 1
    }

    func close() {
        isClosed = true
        navigationGeneration += 1
        isOpening = false
        transportURL = ""
        for lease in leases.values { ProjectBrowserBridges.shared.release(lease) }
        leases.removeAll()
        targets.removeAll()
    }

    #if WORKBENCH_QA
    func showFixture() {
        targetURL = "about:blank"
        transportURL = "about:blank"
    }
    #endif

    deinit {
        let held = Array(leases.values)
        Task { @MainActor in
            for lease in held { ProjectBrowserBridges.shared.release(lease) }
        }
    }
}

/// Agent web UIs can bind well after their terminal starts. A bridge's 502
/// means the service is still starting, so wait before loading its first page.
@MainActor enum BrowserServiceReadiness {
    static func wait(_ url: URL, isCurrent: () -> Bool, timeout: TimeInterval = 45,
                     probe: (URL) async -> Bool = responseIsReady) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isCurrent(), !Task.isCancelled else { return false }
            if await probe(url) { return isCurrent() && !Task.isCancelled }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    private static func responseIsReady(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode != 502
    }
}
