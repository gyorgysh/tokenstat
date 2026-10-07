// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A bounded read lane. A refresh arriving during an older read retires its
/// publication and requests one fresh pass, without parallel transport work.
@MainActor final class ChatPollLane<Owner: Equatable> {
    private final class Flight {
        let owner: Owner
        let ticket = UUID()
        var revision: UInt64 = 0
        var task: Task<Void, Never>!
        init(owner: Owner) { self.owner = owner }
    }
    private var flight: Flight?
    func start(owner: Owner, refresh: Bool = false,
               operation: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Bool) async -> Void) -> Task<Void, Never>? {
        guard !Task.isCancelled else { return nil }
        if let flight, flight.owner == owner {
            if refresh { flight.revision &+= 1 }
            return flight.task
        }
        cancel()
        let made = Flight(owner: owner)
        flight = made
        made.task = Task { [weak self, weak made] in
            guard let self, let made else { return }
            while !Task.isCancelled, self.flight === made {
                let revision = made.revision
                await operation { [weak self, weak made] in
                    guard let self, let made else { return false }
                    return !Task.isCancelled && self.flight === made && made.revision == revision
                }
                guard made.revision == revision else { continue }
                break
            }
            if self.flight === made { self.flight = nil }
        }
        return made.task
    }
    func cancel(owner: Owner? = nil) {
        guard owner == nil || flight?.owner == owner else { return }
        let previous = flight
        flight = nil
        previous?.task.cancel()
    }
}

/// One polling loop per retained reader. View lifetimes hold exact leases;
/// predecessor cancellation cannot stop a successor using the same reader.
@MainActor final class ChatPollWatcher<Owner: Equatable> {
    private struct Loop {
        let owner: Owner
        let ticket: UUID
        let task: Task<Void, Never>
        let stop: @MainActor () -> Void
    }
    private var loop: Loop?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func watch(owner: Owner, cycle: @escaping @MainActor @Sendable () async -> Void,
               interval: @escaping @MainActor @Sendable () -> Duration,
               stop: @escaping @MainActor () -> Void) async {
        guard !Task.isCancelled else { return }
        let lease = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                if let loop, loop.owner != owner { cancel() }
                waiters[lease] = continuation
                guard loop == nil else { return }
                let ticket = UUID()
                let task = Task { [weak self] in
                    while !Task.isCancelled {
                        guard self?.loop?.ticket == ticket else { return }
                        await cycle()
                        do { try await Task.sleep(for: interval()) } catch { break }
                    }
                    if self?.loop?.ticket == ticket { self?.cancel() }
                }
                loop = Loop(owner: owner, ticket: ticket, task: task, stop: stop)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(lease) }
        }
    }
    private func release(_ lease: UUID) {
        guard let waiter = waiters.removeValue(forKey: lease) else { return }
        waiter.resume()
        if waiters.isEmpty { cancel() }
    }
    func cancel() {
        let previous = loop
        loop = nil
        let previousWaiters = waiters
        waiters.removeAll()
        previous?.task.cancel()
        previous?.stop()
        for waiter in previousWaiters.values { waiter.resume() }
    }
}

/// Monotonic-clock policy; no timer or network work is hidden in this value.
struct ChatPollCadence {
    private var quietReads = 0
    private var failures = 0
    private var progressAt: TimeInterval?
    private var statusAt = -Double.infinity
    private var approvalsAt = -Double.infinity
    mutating func note(success: Bool, changed: Bool, now: TimeInterval) {
        if !success { failures = min(4, failures + 1); return }
        failures = 0
        if changed { quietReads = 0; progressAt = now }
        else { quietReads = min(3, quietReads + 1) }
    }
    func interval(busy: Bool, attachments: Bool, now: TimeInterval) -> Duration {
        if failures > 0 { return .milliseconds([400, 800, 1600, 2000][failures - 1]) }
        let recentlyProgressed = progressAt.map { now - $0 < 1.2 } ?? false
        guard busy || attachments || recentlyProgressed else { return .seconds(2) }
        return .milliseconds([120, 180, 260, 400][quietReads])
    }
    mutating func claimStatus(now: TimeInterval, force: Bool) -> Bool {
        guard force || now - statusAt >= 1 else { return false }
        statusAt = now; return true
    }
    mutating func claimApprovals(now: TimeInterval, force: Bool) -> Bool {
        guard force || now - approvalsAt >= 1 else { return false }
        approvalsAt = now; return true
    }
}

struct ChatPollWatchIdentity<Owner: Hashable>: Hashable {
    let owner: Owner?
    let active: Bool
}
