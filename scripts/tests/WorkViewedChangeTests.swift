// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkViewedChange.swift WorkReference.swift WorkCacheMutationQueue.swift.
import Foundation

struct DiffLine: Codable, Sendable { let text: String }
struct DiffHunk: Codable, Sendable { var header: String = "@@"; let lines: [DiffLine] }
struct FileDiff: Codable, Sendable { let path: String; let hunks: [DiffHunk] }
struct ChangedFile: Codable, Sendable { let path: String }
struct CommitDetail: Codable, Sendable {
    let id: String; let subject: String; let body: String; let author: String
    let files: [ChangedFile]; let diffs: [FileDiff]
    var email: String = ""; var parents: [String] = []; var tags: [String]? = nil
}
enum WorkSearchIndex {
    struct Document {
        let reference: WorkReference; let revision: String; let title: String
        let text: String; let folderName: String; let machineName: String
        let updatedAt: Date; let partial: Bool
    }
}
enum WorkCache {
    static func scope(for scope: WorkReference.Scope) -> String { scope.identity }
    static func recordID(for reference: WorkReference) -> String? { reference.itemID }
}
enum WorkDestinationResolver {
    static func route(folderID: String, explicitPeer: String?) -> (peer: String?, workspaceID: String) { (explicitPeer, folderID) }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}
@MainActor final class WorkCacheSettings {
    static let shared = WorkCacheSettings()
    func saves(_ reference: WorkReference) -> Bool { true }
}
actor KeyGate {
    static let shared = KeyGate()
    var paused = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() { paused = true }
    func key() async -> String {
        if paused {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return "fixture-key"
    }
    func resume() { paused = false; waiting = false; continuation?.resume(); continuation = nil }
}
@MainActor enum WorkCacheAccess {
    static func canSave(_ reference: WorkReference) -> Bool { reference.scope == WorkSessionContext.shared.scope }
    static func keyForSaving(_ reference: WorkReference) async -> String? { await KeyGate.shared.key() }
}
actor FixtureWrites {
    static let shared = FixtureWrites()
    var count = 0
    func write() { count += 1 }
}
enum Bridge {
    static func cachePutEncoded(key: String, scope: String, id: String, kind: String, itemId: String,
                                revision: String?, payload: Data, expectedGeneration: UInt64) async throws {
        try await WorkCacheMutationQueue.shared.run(scope: scope, expectedGeneration: expectedGeneration) {
            await FixtureWrites.shared.write()
        }
    }
}

@main enum WorkViewedChangeTests {
    @MainActor static func main() async throws {
        let scope = WorkReference.Scope.local(installationID: "fixture")
        let owner = WorkReference(scope: scope, hostIdentity: "host", workspaceID: "project", kind: .workspace, itemID: nil)
        WorkSessionContext.shared.scope = scope
        let diff = FileDiff(path: "source.swift", hunks: [DiffHunk(lines: [DiffLine(text: "a change")])])
        let commit = CommitDetail(id: "commit", subject: "Read this change", body: "Details", author: "Fixture", files: [ChangedFile(path: diff.path)], diffs: [diff])
        let prepared = WorkViewedChange.prepare(owner: owner, commit: commit, diff: nil)!
        let repeated = WorkViewedChange.prepare(owner: owner, commit: commit, diff: nil)!
        precondition(prepared.revision == repeated.revision)
        let restored = try JSONDecoder().decode(WorkViewedChange.self, from: prepared.payload)
        precondition(restored.valid && restored.commit?.id == commit.id && restored.reference.scope == scope)
        let oversized = FileDiff(path: "generated", hunks: [DiffHunk(lines: [DiffLine(text: String(repeating: "x", count: 8 * 1024 * 1024 + 1))])])
        precondition(WorkViewedChange.prepare(owner: owner, commit: nil, diff: oversized) == nil)
        let escaped = FileDiff(path: "escaped", hunks: [DiffHunk(lines: [DiffLine(text: String(repeating: "\"", count: 5 * 1024 * 1024))])])
        precondition(WorkViewedChange.prepare(owner: owner, commit: nil, diff: escaped) == nil, "the encoded size must also fit")
        let budget = 8 * 1024 * 1024
        let emptyLines = FileDiff(path: "empty-lines", hunks: [DiffHunk(lines: Array(repeating: DiffLine(text: ""), count: 400_000))])
        precondition(!WorkViewedChange.fitsCacheBudget(owner: owner, commit: nil, diff: emptyLines, limit: budget), "structure must be refused before JSON allocation")
        let metadata = FileDiff(path: String(repeating: "p", count: budget), hunks: [])
        precondition(!WorkViewedChange.fitsCacheBudget(owner: owner, commit: nil, diff: metadata, limit: budget))
        let hugeHeader = FileDiff(path: "header", hunks: [DiffHunk(header: String(repeating: "h", count: budget), lines: [])])
        precondition(!WorkViewedChange.fitsCacheBudget(owner: owner, commit: nil, diff: hugeHeader, limit: budget))
        precondition(!WorkViewedChange.fitsCacheBudget(owner: owner, commit: nil, diff: escaped, limit: budget))
        let readable = FileDiff(path: "readable", hunks: [DiffHunk(lines: [DiffLine(text: String(repeating: "x", count: 4 * 1024 * 1024))])])
        precondition(WorkViewedChange.prepare(owner: owner, commit: nil, diff: readable) != nil)

        await WorkViewedChange.save(owner: owner, commit: commit)
        let firstCount = await FixtureWrites.shared.count
        precondition(firstCount == 1)
        await KeyGate.shared.pause()
        let saving = Task { await WorkViewedChange.save(owner: owner, commit: commit) }
        while !(await KeyGate.shared.waiting) { await Task.yield() }
        _ = try await WorkCacheMutationQueue.shared.run(scope: scope.identity, invalidating: true) { }
        await KeyGate.shared.resume()
        await saving.value
        let afterDelete = await FixtureWrites.shared.count
        precondition(afterDelete == 1, "deletion during preparation must prevent the old snapshot from returning")
        WorkSessionContext.shared.scope = nil
        await WorkViewedChange.save(owner: owner, commit: commit)
        let afterSignOut = await FixtureWrites.shared.count
        precondition(afterSignOut == 1)
        print("Viewed changes: round-trip, revision, byte budgets, deletion during preparation and owner refusal passed")
    }
}
