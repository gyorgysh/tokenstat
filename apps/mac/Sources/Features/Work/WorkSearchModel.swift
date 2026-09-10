// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

/// One search presentation owns one index and one set of access facts. Query
/// changes only consult memory. Refreshing saved pages is a separate action.
@MainActor @Observable
final class WorkSearchModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", conversations = "Conversations", folders = "Folders", changes = "Changes"
        var id: Self { self }
        var kinds: Set<WorkReference.Kind> {
            switch self {
            case .all: []
            case .conversations: [.conversation]
            case .folders: [.workspace]
            case .changes: [.commit, .savedDiff]
            }
        }
    }

    let history: WorkSearchHistory
    var recentDestinations: [WorkSearchHistory.Destination] {
        guard ownsSession() else { return [] }
        return history.payload.destinations.filter {
            $0.reference.scope == scope && folders[.init(hostIdentity: $0.reference.hostIdentity, workspaceID: $0.reference.workspaceID)] != nil
        }
    }

    func rememberOpen(_ reference: WorkReference) {
        guard isCurrent(), reference.scope == scope else { return }
        let title = results.first { $0.reference == reference }?.title.text
            ?? recentDestinations.first { $0.reference == reference }?.title
        guard let title else { return }
        let query = query
        Task { await history.remember(query: query, destination: .init(reference: reference, title: title)) }
    }

    var ownsSavedPresentation: Bool { !closed && ownsSession() }

    func savedChange(_ reference: WorkReference) async -> WorkViewedChange? {
        guard isCurrent(), reference.scope == scope, WorkCacheAccess.canRead(reference),
              folders[.init(hostIdentity: reference.hostIdentity, workspaceID: reference.workspaceID)] != nil,
              machines[reference.hostIdentity] != nil,
              let id = WorkCache.recordID(for: reference),
              let key = WorkCacheKey.existingKey(for: WorkCache.scope(for: scope)) else { return nil }
        let record = try? await Bridge.cachedChange(key: WorkCacheKey.encoded(key),
                                                   scope: WorkCache.scope(for: scope), id: id)
        guard isCurrent(), !Task.isCancelled, WorkCacheAccess.canRead(reference), let record, record.matches(reference) else { return nil }
        return record.payload
    }

    var coverageNotice: String?
    var query = ""
    var filter: Filter = .all
    var host: String?
    var selected: WorkReference?
    private(set) var results: [WorkSearchIndex.Hit] = []
    private(set) var coverage: WorkSearchSavedLoader.Coverage?
    private(set) var loading = false
    private(set) var searching = false
    private(set) var failure: String?
    private(set) var queryFailure: String?
    private(set) var savedWorkChanged = false
    private(set) var total = 0
    private(set) var hasUpdatedResults = false
    private(set) var canLoadMore = false
    let machines: [String: String]
    let liveMachines: [String: String]

    private(set) var liveHosts: Set<String> = []
    private(set) var liveFailures: Set<String> = []
    private(set) var liveAnswered: Set<String> = []
    private(set) var livePages: [String: WorkSearchLive.Page] = [:]
    private var liveHits: [String: [WorkSearchIndex.Hit]] = [:]
    private var savedHits: [WorkSearchIndex.Hit] = []
    private var savedGeneration: UUID?
    private var liveIdentity: QueryIdentity?
    private var liveScheduler: WorkSearchLiveScheduler?
    private var liveConnections: [String: WorkSearchLiveConnection] = [:]

    private let localHost: String?
    private var searchableHosts: Set<String> { liveHosts.union(localHost.map { [$0] } ?? []) }
    var activeLiveHosts: Set<String> { host.map { searchableHosts.intersection([$0]) } ?? searchableHosts }
    var liveCoverageText: String? {
        guard !activeLiveHosts.isEmpty else { return nil }
        let localOnly = localHost.map { activeLiveHosts == [$0] } == true
        guard let parsed = try? WorkSearchQuery(query), !parsed.terms.isEmpty else {
            return localOnly ? "Search includes conversations stored on this Mac." : "Enter words to search the selected computers."
        }
        let successful = liveAnswered.subtracting(liveFailures).intersection(activeLiveHosts).count
        let waiting = activeLiveHosts.subtracting(liveAnswered).count
        let partial = livePages.filter { activeLiveHosts.contains($0.key) }.values.contains {
            $0.coverage.partial || $0.nextCursor != nil
        }
        let summary = localOnly
            ? (successful == 1 ? "This Mac searched." : (waiting > 0 ? "Searching this Mac…" : "This Mac’s work could not be searched."))
            : "\(successful) of \(activeLiveHosts.count) computers answered."
        return summary
            + (waiting > 0 && !localOnly ? " Searching…" : "")
            + (partial ? " Results cover the available pages." : "")
    }

    var canLoadMoreLive: Bool {
        results.count < 200 && !hasUpdatedResults && activeLiveHosts.contains {
            livePages[$0]?.nextCursor != nil && liveAnswered.contains($0)
        }
    }

    func loadMoreLive() {
        guard isCurrent(), canLoadMoreLive else { return }
        let queued = liveScheduler?.more(activeLiveHosts) ?? []
        liveAnswered.subtract(queued)
        liveFailures.subtract(queued)
    }

    func selectLiveHosts(_ hosts: Set<String>) {
        guard isCurrent() else { return }
        liveHosts = hosts.intersection(Set(liveMachines.keys))
        liveHits = liveHits.filter { searchableHosts.contains($0.key) }
        livePages = livePages.filter { searchableHosts.contains($0.key) }
        liveFailures = []
        liveAnswered = []
        if liveScheduler == nil {
            liveScheduler = WorkSearchLiveScheduler(fetch: { [weak self] host, query, kinds, cursor in
                guard let self, self.isCurrent() else { throw CancellationError() }
                if let fetch = self.liveFetch { return try await fetch(host, query, kinds, cursor) }
                let connection: WorkSearchLiveConnection
                if let existing = self.liveConnections[host] { connection = existing }
                else {
                    connection = Bridge.workSearchConnection(host: host, scope: self.scope, local: host == self.localHost, ownsSession: { [weak self] in
                        guard let self else { return false }
                        return self.isCurrent() && self.searchableHosts.contains(host)
                    })
                    self.liveConnections[host] = connection
                }
                return try await connection.search(query: query, kinds: kinds, cursor: cursor)
            }, receive: { [weak self] host, requestedCursor, result in
                guard let self, self.isCurrent(), self.searchableHosts.contains(host),
                      let query = try? WorkSearchQuery(self.query),
                      self.liveIdentity == QueryIdentity(query: query, filter: self.filter, host: self.host) else { return }
                self.liveAnswered.insert(host)
                switch result {
                case .success(let page):
                    self.liveFailures.remove(host)
                    self.livePages[host] = page
                    let incoming = WorkSearchMerge.live(page, query: query,
                        machineName: self.machines[host] ?? "Computer")
                    self.liveHits[host] = requestedCursor == nil ? incoming
                        : WorkSearchMerge.combine(saved: [], live: (self.liveHits[host] ?? []) + incoming)
                case .failure: self.liveFailures.insert(host)
                }
                Task { await self.search(preservingLoaded: true) }
            }, ownsSession: { [weak self] in self?.isCurrent() == true })
        }
        if let parsed = try? WorkSearchQuery(query) {
            liveIdentity = QueryIdentity(query: parsed, filter: filter, host: host)
        }
        liveScheduler?.update(query: query, kinds: filter.kinds)
        liveScheduler?.select(activeLiveHosts)
        Task { await search(preservingLoaded: true) }
    }

    private let liveFetch: WorkSearchLiveScheduler.Fetch?
    private let scope: WorkReference.Scope
    /// Folders this index will answer for. Widened when a connected machine
    /// lists what it holds, see `adopt(folders:live:)`.
    private var folders: [WorkSearchIndex.Folder: String]
    private let metadata: [WorkSearchIndex.Document]
    /// Whether saved conversation text is part of the index, which decides
    /// whether an empty result means "nothing matches" or "only folder names
    /// were searched".
    private(set) var includesSavedText: Bool
    private let ownsSession: () -> Bool
    private let cache: WorkSearchCache
    private var subscription: WorkSearchCache.Subscription?
    private var loader: WorkSearchSavedLoader?
    private var observation: Task<Void, Never>?
    private var queryGeneration = UUID()
    private var cursor: WorkSearchIndex.Cursor?
    private var pendingPage: WorkSearchIndex.Results?
    private struct QueryIdentity: Equatable {
        let query: WorkSearchQuery
        let filter: Filter
        let host: String?
    }
    private var displayedQuery: QueryIdentity?
    private var closed = false
    private var starting = false

    private func isCurrent() -> Bool {
        guard !closed else { return false }
        guard ownsSession() else { close(); return false }
        return true
    }

    init(scope: WorkReference.Scope, folders: [WorkSearchIndex.Folder: String],
         machines: [String: String], metadata: [WorkSearchIndex.Document] = [],
         includesSavedText: Bool = true, liveHosts: Set<String> = [], localHost: String? = nil,
         liveFetch: WorkSearchLiveScheduler.Fetch? = nil, cache: WorkSearchCache = .shared,
         ownsSession: @escaping () -> Bool) {
        self.scope = scope
        self.history = WorkSearchHistory.shared(for: scope)
        self.localHost = localHost.flatMap { machines[$0] == nil ? nil : $0 }
        self.liveFetch = liveFetch
        self.folders = folders
        self.machines = machines
        self.liveMachines = machines.filter { liveHosts.contains($0.key) }
        self.metadata = metadata
        self.includesSavedText = includesSavedText
        self.cache = cache
        self.ownsSession = ownsSession
    }

    func start() async {
        guard subscription == nil, !starting, isCurrent() else { return }
        starting = true
        defer { starting = false }
        let subscription = await cache.subscribe(scope: scope, folders: Set(folders.keys))
        guard isCurrent() else { await cache.unsubscribe(subscription); return }
        self.subscription = subscription
        for document in metadata {
            guard isCurrent(), !Task.isCancelled else { return }
            if let ticket = await cache.beginRead(subscription, reference: document.reference) {
                _ = await cache.finishRead(ticket, documents: [document])
            }
        }
        loader = WorkSearchSavedLoader(cache: cache, subscription: subscription, scope: scope,
                                      folders: folders, machines: machines)
        let updates = await cache.changes()
        observation = Task { [weak self] in
            for await _ in updates {
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.savedWorkChanged = true
                // Removal takes effect immediately. New content is loaded only
                // when the person asks to refresh the saved-work snapshot.
                await self.search()
            }
        }
        await history.load()
        guard isCurrent() else { return }
        if localHost != nil { selectLiveHosts([]) }
        if includesSavedText { await refresh() } else { await search() }
    }

    /// Folders a connected machine listed after the sheet opened.
    ///
    /// Finding a folder by name must not require having opened it on this
    /// device first: the pins and recent places a phone knows are a fraction
    /// of what is on the machine. The names come from the machine that owns
    /// them, once when search opens rather than once per keystroke, and they
    /// are labels only, no conversation text.
    ///
    /// Access is not granted here. A host is asked only when it is already
    /// verified, so this widens what the index will answer for within
    /// permission that was established before.
    func adopt(folders newFolders: [WorkSearchCatalog.KnownFolder], live: Set<String>) async {
        guard isCurrent(), let subscription else { return }
        var labels = folders
        var documents: [WorkSearchIndex.Document] = []
        for folder in newFolders {
            let reference = folder.reference
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reference.scope == scope, machines[reference.hostIdentity] != nil,
                  !reference.workspaceID.isEmpty, !name.isEmpty else { continue }
            let key = WorkSearchIndex.Folder(hostIdentity: reference.hostIdentity,
                                             workspaceID: reference.workspaceID)
            guard labels[key] == nil else { continue }
            labels[key] = name
            documents.append(.init(
                reference: WorkReference(scope: scope, hostIdentity: reference.hostIdentity,
                                         workspaceID: reference.workspaceID, kind: .workspace, itemID: nil),
                revision: "metadata", title: name, text: "", folderName: name,
                machineName: machines[reference.hostIdentity] ?? "", updatedAt: folder.updatedAt, partial: false))
        }
        if !documents.isEmpty {
            folders = labels
            await subscription.index.setAccess(Set(labels.keys))
            for document in documents {
                guard isCurrent(), !Task.isCancelled else { return }
                if let ticket = await cache.beginRead(subscription, reference: document.reference) {
                    _ = await cache.finishRead(ticket, documents: [document])
                }
            }
            guard isCurrent() else { return }
            loader = WorkSearchSavedLoader(cache: cache, subscription: subscription, scope: scope,
                                          folders: folders, machines: machines)
        }
        let hosts = live.intersection(Set(liveMachines.keys)).subtracting(liveHosts)
        // A machine that answered is a machine that is reachable and still
        // letting this device in, which is exactly the one worth searching as
        // it is now. `selectLiveHosts` runs the query again on its own.
        if !hosts.isEmpty { selectLiveHosts(liveHosts.union(hosts)) }
        else if !documents.isEmpty { await search() }
    }

    func refresh() async {
        guard isCurrent(), !loading, let loader else { return }
        guard includesSavedText else { await search(); return }
        loading = true
        failure = nil
        savedWorkChanged = false
        defer { loading = false }
        do {
            let coverage = try await loader.load()
            guard isCurrent(), !Task.isCancelled else { return }
            self.coverage = coverage
            savedWorkChanged = savedWorkChanged || coverage.interrupted
            await search()
        } catch is CancellationError {
        } catch WorkSearchSavedLoader.Failure.locked {
            guard isCurrent() else { return }
            results = []
            failure = "Unlock this device to search saved conversations, then try again."
        } catch {
            guard isCurrent() else { return }
            failure = "Saved work could not be searched. Try again when this device is ready."
        }
    }

    func search(more: Bool = false, preservingLoaded: Bool = false) async {
        guard isCurrent(), let subscription else { return }
        guard !more || cursor != nil else { return }
        let run = UUID()
        queryGeneration = run
        queryFailure = nil
        searching = true
        defer { if queryGeneration == run { searching = false } }
        do {
            let query = try WorkSearchQuery(query)
            let identity = QueryIdentity(query: query, filter: filter, host: host)
            if liveIdentity != identity {
                liveIdentity = identity
                liveHits = [:]
                livePages = [:]
                liveFailures = []
                liveAnswered = []
                liveScheduler?.update(query: self.query, kinds: filter.kinds)
                liveScheduler?.select(activeLiveHosts)
            }
            let localPage = try await subscription.index.search(query, kinds: filter.kinds,
                hosts: host.map { [$0] } ?? [], cursor: more ? cursor : nil)
            guard run == queryGeneration, isCurrent(), !Task.isCancelled else { return }
            let retainLoaded = preservingLoaded && displayedQuery == identity && savedGeneration == localPage.generation
            savedHits = more || retainLoaded
                ? WorkSearchMerge.combine(saved: savedHits + localPage.hits, live: []) : localPage.hits
            savedGeneration = localPage.generation
            let incomingLive = liveHits.filter { host == nil || $0.key == host }.values.flatMap { $0 }
            let merged = WorkSearchMerge.combine(saved: savedHits, live: incomingLive)
            let page = WorkSearchIndex.Results(hits: merged, total: min(200, max(localPage.total, merged.count)),
                generation: localPage.generation, nextCursor: retainLoaded ? cursor : localPage.nextCursor)
            if displayedQuery == identity, selected != nil {
                let order = WorkSearchResultOrder.retained(previous: results.map(\.reference), incoming: page.hits.map(\.reference))
                let lookup = Dictionary(page.hits.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
                results = order.compactMap { lookup[$0] }
                pendingPage = order == page.hits.map(\.reference) ? nil : page
            } else {
                results = page.hits
                pendingPage = nil
                if displayedQuery != identity { selected = nil }
            }
            displayedQuery = identity
            total = page.total
            cursor = page.nextCursor
            hasUpdatedResults = pendingPage != nil
            canLoadMore = cursor != nil && !hasUpdatedResults
            if let selected {
                self.selected = results.first {
                    WorkSearchResultOrder.destination($0.reference) == WorkSearchResultOrder.destination(selected)
                }?.reference
            }
        } catch WorkSearchQuery.Invalid.tooLong {
            liveScheduler?.update(query: query, kinds: filter.kinds)
            // The scheduler cancelled this query. Returning to the previous
            // valid text must schedule it again, even if its identity matches.
            liveIdentity = nil
            liveHits = [:]
            livePages = [:]
            liveFailures = []
            liveAnswered = []
            guard run == queryGeneration, isCurrent() else { return }
            total = 0
            pendingPage = nil
            hasUpdatedResults = false
            results = []
            canLoadMore = false
            queryFailure = "Use 512 characters or fewer to search work."
        } catch WorkSearchIndex.PageError.staleCursor {
            guard run == queryGeneration, isCurrent() else { return }
            savedWorkChanged = true
            canLoadMore = false
        } catch {
            guard run == queryGeneration, isCurrent() else { return }
            queryFailure = "Search could not finish. Try again."
        }
    }

    func acceptUpdatedResults(refreshIfChanged: Bool = true) async {
        guard isCurrent(), let page = pendingPage else { return }
        guard let query = try? WorkSearchQuery(query),
              displayedQuery == QueryIdentity(query: query, filter: filter, host: host) else {
            pendingPage = nil
            hasUpdatedResults = false
            return
        }
        let expectedIdentity = displayedQuery
        guard let subscription, let epoch = await cache.snapshotEpoch(),
              await subscription.index.isCurrent(generation: page.generation),
              await cache.snapshotEpoch() == epoch else {
            pendingPage = nil
            hasUpdatedResults = false
            savedWorkChanged = true
            if refreshIfChanged {
                await search()
                guard displayedQuery == expectedIdentity else { return }
                await acceptUpdatedResults(refreshIfChanged: false)
            }
            return
        }
        guard isCurrent(), let currentQuery = try? WorkSearchQuery(self.query),
              displayedQuery == expectedIdentity,
              expectedIdentity == QueryIdentity(query: currentQuery, filter: filter, host: host),
              pendingPage?.generation == page.generation else { return }
        // A newer live reply may have updated the pending page while the
        // local generation was being checked. Adopt that current page.
        guard let page = pendingPage else { return }
        results = page.hits
        cursor = page.nextCursor
        canLoadMore = cursor != nil
        pendingPage = nil
        hasUpdatedResults = false
    }

    func moveSelection(_ direction: Int) {
        guard !results.isEmpty else { return }
        let current = selected.flatMap { value in results.firstIndex { $0.reference == value } }
        let next = current.map { min(max($0 + direction, 0), results.count - 1) }
            ?? (direction > 0 ? 0 : results.count - 1)
        selected = results[next].reference
    }

    func close() {
        closed = true
        liveScheduler?.close()
        liveScheduler = nil
        liveConnections.values.forEach { $0.close() }
        liveConnections = [:]
        liveHits = [:]
        livePages = [:]
        savedHits = []
        queryGeneration = UUID()
        observation?.cancel()
        observation = nil
        results = []
        pendingPage = nil
        hasUpdatedResults = false
        let subscription = subscription
        let loader = loader
        self.subscription = nil
        self.loader = nil
        Task { [cache] in
            await loader?.cancel()
            if let subscription { await cache.unsubscribe(subscription) }
        }
    }
}
