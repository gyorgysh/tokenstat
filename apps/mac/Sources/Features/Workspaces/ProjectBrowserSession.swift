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
    @ObservationIgnored private var targets: [String: BrowserTarget] = [:]

    init(owner: WorkReference?, peer: String?, history: BrowserHistory? = nil,
         isCurrent: @escaping () -> Bool) {
        self.owner = owner
        self.peer = peer
        self.history = history ?? .shared
        self.isCurrent = isCurrent
        targetURL = self.history.entry(for: owner).lastTarget ?? ""
    }

    var recentPorts: [Int] { history.entry(for: owner).ports }

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

    func intercept(_ request: URLRequest, isMainFrame: Bool) -> Bool {
        guard let url = request.url, intercepts(url) else { return false }
        guard isMainFrame, (request.httpMethod ?? "GET").uppercased() == "GET" else {
            error = L10n.text("apple.projectbrowsersession.open_this_service_s_address_first_this_req.4a65188f")
            return true
        }
        Task { await open(canonicalURL(url.absoluteString)) }
        return true
    }

    func open(_ raw: String) async {
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
            targetURL = target?.url ?? parsed.absoluteString
            transportURL = transport
            loadRevision += 1
            if let target { history.record(target, for: owner) }
        } catch {
            guard navigationGeneration == operation, isCurrent(), !Task.isCancelled else { return }
            pendingExplicitNavigation = false
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func observed(_ actual: String, generation: Int? = nil, registered: Bool = true) -> Bool {
        guard !isClosed, isCurrent(), generation == nil || generation == navigationGeneration,
              registered || !pendingExplicitNavigation else { return false }
        if registered { pendingExplicitNavigation = false }
        let original = canonicalURL(actual)
        targetURL = original
        transportURL = actual
        if let target = BrowserTarget(original) { history.record(target, for: owner) }
        return true
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
