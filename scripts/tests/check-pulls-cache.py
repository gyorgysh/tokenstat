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
struct PullAvailability {
    var state = "ready"; var login: String? = "alice"; var repositoryName: String? = "org/repo"
    var host: String? = "github.com"; var source: String? = "app"; var installationId: UInt64? = 1
}
struct PullDeviceLogin { }
@MainActor final class PullCountStore {
    static let shared = PullCountStore()
    func set(_ count: Int, workspaceID: String, peer: String?) {}
}
enum Failure: Error { case offline }
@MainActor enum Bridge {
    static var availability = PullAvailability()
    static var unavailable = false
    static var listUnavailable = false
    static var calls: [Bool] = []
    static var result = [PullSummary(number: 1)]
    static func pullAvailability(workspaceID: String, peer: String?) async throws -> PullAvailability {
        if unavailable { throw Failure.offline }; return availability
    }
    static func pullList(workspaceID: String, peer: String?, scope: PullScope,
                         state: PullStateFilter, refresh: Bool) async throws -> [PullSummary] {
        calls.append(refresh)
        if listUnavailable { throw Failure.offline }; return result
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
        print("Pull list: cached failure, forced retry, connection identity and workspace isolation passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + model + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
