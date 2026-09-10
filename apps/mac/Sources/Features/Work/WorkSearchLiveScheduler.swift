// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Session-only opt-in. Canceled transports keep their slots until completion;
/// replacing a query cannot accumulate more than two in-flight host requests.
@MainActor
final class WorkSearchLiveScheduler {
    typealias Fetch = @MainActor (String, String, Set<WorkReference.Kind>, String?) async throws -> WorkSearchLive.Page
    typealias Receive = @MainActor (String, String?, Result<WorkSearchLive.Page, Error>) -> Void
    private let fetch: Fetch
    private let receive: Receive
    private let ownsSession: @MainActor () -> Bool
    private let debounce: @MainActor () async throws -> Void
    private var selected: Set<String> = []
    private var generation = UUID()
    private struct Job { let host: String; let cursor: String? }
    private var pending: [Job] = []
    private var activeHosts: [UUID: String] = [:]
    private var cursors: [String: String] = [:]
    private var active: [UUID: Task<Void, Never>] = [:]
    private var delay: Task<Void, Never>?
    private var query = ""
    private var kinds: Set<WorkReference.Kind> = []
    private var closed = false

    init(fetch: @escaping Fetch, receive: @escaping Receive,
         ownsSession: @escaping @MainActor () -> Bool,
         debounce: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(nanoseconds: 250_000_000)
         }) {
        self.fetch = fetch
        self.receive = receive
        self.ownsSession = ownsSession
        self.debounce = debounce
    }

    /// Called only by the explicit selected-machines action. Empty selection
    /// withdraws opt-in and cancels the current generation.
    func select(_ hosts: Set<String>) {
        selected = hosts
        update(query: query, kinds: kinds)
    }

    func update(query: String, kinds: Set<WorkReference.Kind>) {
        guard !closed else { return }
        generation = UUID()
        self.query = query
        self.kinds = kinds
        delay?.cancel()
        pending.removeAll()
        cursors = [:]
        for task in active.values { task.cancel() }
        guard ownsSession(), !selected.isEmpty,
              let parsed = try? WorkSearchQuery(query), !parsed.terms.isEmpty else { return }
        let expected = generation
        delay = Task { [weak self] in
            guard let self else { return }
            do { try await debounce() } catch { return }
            guard !Task.isCancelled, !closed, ownsSession(), expected == generation else { return }
            pending = selected.sorted().map { Job(host: $0, cursor: nil) }
            drain()
        }
    }

    /// Continuations share the same queue and slots as first pages. A repeated
    /// tap cannot enqueue the same host while its page is queued or running.
    @discardableResult
    func more(_ hosts: Set<String>) -> Set<String> {
        guard !closed, ownsSession() else { return [] }
        var queued = Set<String>()
        for host in hosts.intersection(selected).sorted() {
            guard let cursor = cursors[host],
                  !pending.contains(where: { $0.host == host }),
                  !activeHosts.values.contains(host) else { continue }
            pending.append(Job(host: host, cursor: cursor))
            queued.insert(host)
        }
        drain()
        return queued
    }

    func close() {
        closed = true
        generation = UUID()
        selected.removeAll()
        pending.removeAll()
        delay?.cancel()
        for task in active.values { task.cancel() }
    }

    private func drain() {
        guard !closed, ownsSession() else { close(); return }
        while active.count < 2, let next = pending.firstIndex(where: { !activeHosts.values.contains($0.host) }) {
            let job = pending.remove(at: next)
            let host = job.host
            let token = UUID()
            let expected = generation
            let query = query
            let kinds = kinds
            let fetch = fetch
            activeHosts[token] = host
            active[token] = Task { [weak self] in
                let result: Result<WorkSearchLive.Page, Error>
                do { result = .success(try await fetch(host, query, kinds, job.cursor)) }
                catch { result = .failure(error) }
                guard let self else { return }
                active[token] = nil
                activeHosts[token] = nil
                if !closed, ownsSession(), expected == generation, !Task.isCancelled {
                    if case .success(let page) = result { cursors[host] = page.nextCursor }
                    receive(host, job.cursor, result)
                }
                drain()
            }
        }
    }
}
