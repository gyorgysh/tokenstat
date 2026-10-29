#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production pull-list model with a controllable bridge."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Pulls/PullsView.swift').read_text()
start = source.index('@MainActor\n@Observable\nprivate final class PullsModel')
end = source.index('    func beginLogin()', start)
model = source[start:end] + '}\n'
harness = r'''
import Foundation
import Observation
enum PullScope: Hashable { case all, mine }
enum PullStateFilter: Hashable { case open, closed }
struct PullSummary: Equatable { var number: Int }
struct PullListPage { var rows: [PullSummary]; var nextCursor: String? }
struct PullAvailability {
    var state = "ready"; var login: String? = "alice"; var repositoryName: String? = "org/repo"
    var host: String? = "github.com"; var source: String? = "app"; var installationId: UInt64? = 1
}
struct PullDeviceLogin { }
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var generation: UInt64 = 1
}
@MainActor final class PullCountStore {
    static let shared = PullCountStore()
    var value: Int?
    func set(_ count: Int, workspaceID: String, peer: String?) { value = count }
    func clear(workspaceID: String, peer: String?) { value = nil }
}
enum Failure: LocalizedError {
    case offline, revoked
    var errorDescription: String? { self == .revoked ? "access was not granted" : "Offline" }
}
enum PullDetailModel {
    static func isAccessLoss(_ error: Error) -> Bool { error.localizedDescription.contains("access was not granted") }
}
enum BridgeError: Error { case core(code: String, message: String) }
enum L10n { static func text(_ key: String) -> String { key } }
@MainActor enum Bridge {
    static var availability = PullAvailability()
    static var unavailable = false
    static var listUnavailable = false
    static var revoked = false
    static var calls: [Bool] = []
    static var result = [PullSummary(number: 1)]
    static var firstCursor: String?
    static var next = PullListPage(rows: [], nextCursor: nil)
    static var pauseMore = false
    static var pauseFirst = false
    static var pauseAvailability = false
    static var pending: CheckedContinuation<PullListPage, Error>?
    static var pendingAvailability: CheckedContinuation<PullAvailability, Error>?
    static func pullAvailability(workspaceID: String, peer: String?) async throws -> PullAvailability {
        if pauseAvailability { return try await withCheckedThrowingContinuation { pendingAvailability = $0 } }
        if unavailable { throw Failure.offline }; return availability
    }
    static func pullListPage(workspaceID: String, peer: String?, scope: PullScope,
                             state: PullStateFilter, cursor: String? = nil, refresh: Bool = false) async throws -> (page: PullListPage, supportsPagination: Bool) {
        calls.append(refresh)
        if revoked { throw Failure.revoked }
        if listUnavailable { throw Failure.offline }
        if cursor == nil && pauseFirst {
            return (try await withCheckedThrowingContinuation { pending = $0 }, true)
        }
        if cursor != nil {
            if pauseMore {
                return (try await withCheckedThrowingContinuation { pending = $0 }, true)
            }
            return (next, true)
        }
        return (PullListPage(rows: result, nextCursor: firstCursor), true)
    }
}
'''
checks = r'''
@main struct Check {
    @MainActor static func main() async {
        let model = PullsModel()
        await model.load(workspaceID: "repo", peer: "host")
        precondition(model.rows == [PullSummary(number: 1)] && model.lastLoadedAt != nil)
        Bridge.unavailable = true
        await model.load(workspaceID: "repo", peer: "host")
        precondition(model.errorMessage != nil && model.rows.count == 1 && model.lastLoadedAt != nil)
        Bridge.unavailable = false; Bridge.listUnavailable = true
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        precondition(model.listError != nil && model.rows.count == 1 && model.lastLoadedAt != nil)
        Bridge.listUnavailable = false; Bridge.result = [PullSummary(number: 2)]
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        precondition(Bridge.calls.last == true && model.rows == Bridge.result && model.listError == nil)
        Bridge.availability.installationId = 2; Bridge.listUnavailable = true
        await model.load(workspaceID: "repo", peer: "host")
        precondition(model.rows.isEmpty && model.lastLoadedAt == nil && model.listError != nil)
        Bridge.listUnavailable = false
        await model.load(workspaceID: "different", peer: "host")
        precondition(model.rows == Bridge.result)
        Bridge.unavailable = true
        await model.load(workspaceID: "other", peer: "host")
        precondition(model.rows.isEmpty && model.lastLoadedAt == nil)
        Bridge.unavailable = false; Bridge.firstCursor = "next"
        Bridge.result = [PullSummary(number: 1)]
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        precondition(PullCountStore.shared.value == nil)
        Bridge.next = PullListPage(rows: [PullSummary(number: 1), PullSummary(number: 2)], nextCursor: nil)
        await model.loadMore(workspaceID: "repo", peer: "host")
        precondition(model.rows == [PullSummary(number: 1), PullSummary(number: 2)] && model.nextCursor == nil)
        // Search ordering can change between pages, so a paginated list is not
        // an authoritative total even when it reaches its last cursor.
        precondition(PullCountStore.shared.value == nil)
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        Bridge.pauseMore = true
        let oldPage = Task { await model.loadMore(workspaceID: "repo", peer: "host") }
        while Bridge.pending == nil { await Task.yield() }
        Bridge.result = [PullSummary(number: 3)]
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        Bridge.pending?.resume(returning: PullListPage(rows: [PullSummary(number: 4)], nextCursor: nil))
        Bridge.pending = nil
        await oldPage.value
        precondition(model.rows == [PullSummary(number: 3)] && !model.isLoadingMore)
        Bridge.pauseMore = false
        Bridge.next = PullListPage(rows: [], nextCursor: "next")
        await model.loadMore(workspaceID: "repo", peer: "host")
        precondition(model.moreError != nil && model.nextCursor == "next")
        Bridge.result = (1...999).map { PullSummary(number: $0) }
        Bridge.next = PullListPage(rows: [PullSummary(number: 1000), PullSummary(number: 1001)], nextCursor: nil)
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        await model.loadMore(workspaceID: "repo", peer: "host")
        precondition(model.rows.count == 1000 && model.reachedLimit)
        model.forgetCachedLists(workspaceID: "repo", peer: "host")
        precondition(model.rows.isEmpty && model.lastLoadedAt == nil && model.nextCursor == nil && PullCountStore.shared.value == nil)
        Bridge.result = [PullSummary(number: 1)]; Bridge.firstCursor = nil
        await model.load(workspaceID: "repo", peer: "host", refresh: true)
        Bridge.revoked = true
        await model.loadList(workspaceID: "repo", peer: "host", refresh: true)
        precondition(model.accessLost && model.rows.isEmpty && model.listError != nil && model.lastLoadedAt == nil)
        Bridge.revoked = false; Bridge.pauseFirst = true
        let previous = PullsModel()
        let pending = Task { await previous.load(workspaceID: "repo", peer: "host", refresh: true) }
        while Bridge.pending == nil { await Task.yield() }
        WorkSessionContext.shared.generation = 2
        PullCountStore.shared.value = 99
        Bridge.pending?.resume(returning: PullListPage(rows: [PullSummary(number: 77)], nextCursor: nil))
        Bridge.pending = nil
        await pending.value
        precondition(previous.rows.isEmpty && PullCountStore.shared.value == 99 && !previous.isLoadingList)
        let oldCallCount = Bridge.calls.count
        Bridge.pauseFirst = false
        await previous.loadList(workspaceID: "repo", peer: "host", refresh: true)
        previous.forgetCachedLists(workspaceID: "repo", peer: "host")
        precondition(Bridge.calls.count == oldCallCount && PullCountStore.shared.value == 99)
        let current = PullsModel()
        Bridge.result = [PullSummary(number: 88)]
        await current.load(workspaceID: "repo", peer: "host", refresh: true)
        precondition(current.rows == [PullSummary(number: 88)] && PullCountStore.shared.value == 1)
        Bridge.firstCursor = "next"
        await current.load(workspaceID: "repo", peer: "host", refresh: true)
        Bridge.pauseMore = true
        let oldMore = Task { await current.loadMore(workspaceID: "repo", peer: "host") }
        while Bridge.pending == nil { await Task.yield() }
        Bridge.pauseAvailability = true
        let retiredAvailability = PullsModel()
        let oldAvailability = Task { await retiredAvailability.load(workspaceID: "repo", peer: "host") }
        while Bridge.pendingAvailability == nil { await Task.yield() }
        WorkSessionContext.shared.generation = 3
        PullCountStore.shared.value = 42
        Bridge.pendingAvailability?.resume(throwing: Failure.revoked)
        Bridge.pendingAvailability = nil
        Bridge.pending?.resume(throwing: Failure.revoked)
        Bridge.pending = nil
        await oldAvailability.value
        await oldMore.value
        precondition(!retiredAvailability.accessLost && !current.accessLost && !current.isLoadingMore
            && PullCountStore.shared.value == 42)
        Bridge.pauseAvailability = false; Bridge.pauseFirst = true
        let cancelledModel = PullsModel()
        let cancelled = Task { await cancelledModel.load(workspaceID: "repo", peer: "host") }
        while Bridge.pending == nil { await Task.yield() }
        PullCountStore.shared.value = 42
        cancelled.cancel()
        Bridge.pending?.resume(returning: PullListPage(rows: [PullSummary(number: 1)], nextCursor: nil))
        Bridge.pending = nil
        await cancelled.value
        precondition(cancelledModel.rows.isEmpty && !cancelledModel.isLoadingList && PullCountStore.shared.value == 42)
        print("Pull list: cache isolation, pagination, stale responses and account-session fencing passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + model + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
