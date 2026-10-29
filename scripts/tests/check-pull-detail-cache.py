#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Verify production detail working-set eviction and owner isolation."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Features/Workspaces/Pulls/PullsView.swift').read_text()
start = source.index('@MainActor\nfinal class PullDetailCache')
end = source.index('/// Connection boundary for the pull-request workspace.', start)
cache = source[start:end]
start = source.index('@MainActor @Observable\nfinal class PullCountStore')
end = source.index('/// A small, memory-only working set', start)
count_store = source[start:end]
harness = r'''
import Foundation
import Observation
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var generation: UInt64 = 1
}
struct PullAvailability: Hashable { var login: String; var repository: String }
@MainActor final class PullDetailModel {
    var preparations = 0
    func prepareForCache() { preparations += 1 }
}
'''
checks = r'''
@main struct Check {
    @MainActor static func main() {
        let cache = PullDetailCache()
        let owner = PullDetailCache.Owner(workspace: "repo", peer: "host", sessionGeneration: 1,
                                          availability: .init(login: "alice", repository: "first"))
        let one = cache.model(number: 1, owner: owner)
        let two = cache.model(number: 2, owner: owner)
        precondition(cache.model(number: 1, owner: owner) === one)
        _ = cache.model(number: 3, owner: owner)
        precondition(two.preparations == 1 && cache.model(number: 2, owner: owner) !== two)
        let anotherSession = PullDetailCache.Owner(workspace: "repo", peer: "host", sessionGeneration: 2,
                                                   availability: owner.availability)
        precondition(cache.model(number: 1, owner: anotherSession) !== one)
        precondition(one.preparations == 1)
        let secondOwner = PullDetailCache.Owner(workspace: "repo", peer: "host", sessionGeneration: 2,
                                               availability: .init(login: "alice", repository: "second"))
        let second = cache.model(number: 1, owner: secondOwner)
        let otherPeer = PullDetailCache.Owner(workspace: "repo", peer: "other", sessionGeneration: 2,
                                              availability: secondOwner.availability)
        precondition(cache.model(number: 1, owner: otherPeer) !== second && second.preparations == 1)
        cache.clear()
        let counts = PullCountStore()
        counts.set(4, workspaceID: "repo", peer: "host")
        precondition(counts.count(key: "remote:host:repo") == 4)
        WorkSessionContext.shared.generation = 2
        precondition(counts.count(workspaceID: "repo", peer: "host") == nil)
        counts.set(3, workspaceID: "repo", peer: "other")
        precondition(counts.count(workspaceID: "repo", peer: "host") == nil)
        precondition(counts.count(workspaceID: "repo", peer: "other") == 3)
        counts.clear(workspaceID: "repo", peer: "other")
        precondition(counts.count(workspaceID: "repo", peer: "other") == nil)
        print("Pull detail cache: bounded LRU, session, repository and host isolation passed")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'Check.swift').write_text(harness + count_store + cache + checks)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
