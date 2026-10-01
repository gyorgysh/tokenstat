// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import CryptoKit

/// An explicitly viewed snapshot. Source text is sealed for reading; only
/// commit metadata and file names enter the disposable search index.
struct WorkViewedChange: Codable, Sendable, Identifiable {
    let reference: WorkReference
    let title: String
    let capturedAt: Date
    let revision: String
    let commit: CommitDetail?
    let diff: FileDiff?
    var id: WorkReference { reference }
    var diffs: [FileDiff] { commit?.diffs ?? diff.map { [$0] } ?? [] }

    struct Record: Decodable, Sendable {
        let scope: String
        let id: String
        let kind: String
        let itemId: String
        let revision: String?
        let payload: WorkViewedChange

        func matches(_ reference: WorkReference) -> Bool {
            scope == WorkCache.scope(for: reference.scope)
                && id == WorkCache.recordID(for: reference) && kind == "diff"
                && itemId == reference.itemID && revision == payload.revision
                && payload.reference == reference && payload.valid
        }
    }

    var valid: Bool {
        switch reference.kind {
        case .commit: commit != nil && diff == nil && commit?.id == reference.itemID
        case .savedDiff: diff != nil && commit == nil && revision == reference.itemID
        default: false
        }
    }

    func documents(folderName: String, machineName: String) -> [WorkSearchIndex.Document] {
        guard valid else { return [] }
        let metadata = commit.map { [$0.body, $0.author, $0.id] + $0.files.map(\.path) }
            ?? diffs.map(\.path)
        return [.init(reference: reference, revision: revision, title: title,
                      text: metadata.joined(separator: "\n"), folderName: folderName,
                      machineName: machineName, updatedAt: capturedAt, partial: false)]
    }

    @MainActor
    static func owner(folderID: String, peer: String? = nil) -> WorkReference? {
        guard let scope = WorkSessionContext.shared.scope else { return nil }
        let route = WorkDestinationResolver.route(folderID: folderID, explicitPeer: peer)
        guard let host = route.peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        return WorkReference(scope: scope, hostIdentity: host, workspaceID: route.workspaceID,
                             kind: .workspace, itemID: nil)
    }

    @MainActor
    static func save(owner: WorkReference?, commit: CommitDetail? = nil, diff: FileDiff? = nil) async {
        guard let owner, WorkCacheAccess.canSave(owner),
              !Task.isCancelled, WorkCacheSettings.shared.saves(owner),
              (commit != nil) != (diff != nil) else { return }
        let scope = WorkCache.scope(for: owner.scope)
        let generation = await WorkCacheMutationQueue.shared.generation(scope: scope)
        let task = Task.detached(priority: .utility) {
            prepare(owner: owner, commit: commit, diff: diff)
        }
        let prepared = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard let prepared, !Task.isCancelled,
              WorkCacheAccess.canSave(owner), WorkCacheSettings.shared.saves(owner),
              let id = WorkCache.recordID(for: prepared.reference),
              let key = await WorkCacheAccess.keyForSaving(prepared.reference) else { return }
        _ = try? await Bridge.cachePutEncoded(key: key, scope: scope,
            id: id, kind: "diff", itemId: prepared.reference.itemID ?? prepared.revision,
            revision: prepared.revision, payload: prepared.payload, expectedGeneration: generation)
    }

    struct Prepared: Sendable {
        let reference: WorkReference
        let revision: String
        let payload: Data
    }

    /// Bound text, metadata and JSON structure before allocating encoded copies.
    static func prepare(owner: WorkReference, commit: CommitDetail?, diff: FileDiff?) -> Prepared? {
        let budget = 8 * 1024 * 1024
        guard (commit != nil) != (diff != nil), fitsCacheBudget(owner: owner, commit: commit, diff: diff, limit: budget) else { return nil }
        guard !Task.isCancelled else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let source = commit.flatMap({ try? encoder.encode($0) }) ?? diff.flatMap({ try? encoder.encode($0) }),
              source.count <= budget, !Task.isCancelled else { return nil }
        let revision = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let reference = WorkReference(scope: owner.scope, hostIdentity: owner.hostIdentity,
            workspaceID: owner.workspaceID, kind: commit == nil ? .savedDiff : .commit,
            itemID: commit?.id ?? revision)
        let copy = Self(reference: reference, title: commit?.subject ?? diff?.path ?? L10n.text("apple.workviewedchange.changes.bbd4b6a8"),
                        capturedAt: Date(), revision: revision, commit: commit, diff: diff)
        guard let data = try? encoder.encode(copy), data.count <= budget, !Task.isCancelled else { return nil }
        return Prepared(reference: reference, revision: revision, payload: data)
    }

    /// Conservative structural allowances include keys, punctuation and numbers.
    /// Empty lines and metadata-only patches cost space even with no source text.
    static func fitsCacheBudget(owner: WorkReference, commit: CommitDetail?, diff: FileDiff?, limit: Int) -> Bool {
        var bytes = ByteBudget(remaining: limit)
        guard bytes.consume(512), bytes.string(owner.scope.origin), bytes.string(owner.scope.identity),
              bytes.string(owner.hostIdentity), bytes.string(owner.workspaceID) else { return false }
        if let commit {
            guard bytes.consume(256), bytes.string(commit.id), bytes.string(commit.id),
                  bytes.string(commit.subject), bytes.string(commit.subject), bytes.string(commit.body),
                  bytes.string(commit.author), bytes.string(commit.email) else { return false }
            for values in [commit.parents, commit.tags ?? []] {
                for value in values {
                    guard bytes.string(value), bytes.consume(1) else { return false }
                }
            }
            for file in commit.files {
                guard bytes.consume(128), bytes.string(file.path) else { return false }
            }
        } else if let diff {
            guard bytes.string(diff.path) else { return false } // The snapshot title repeats the path.
        }
        for file in commit?.diffs ?? diff.map({ [$0] }) ?? [] {
            guard bytes.consume(64), bytes.string(file.path) else { return false }
            for hunk in file.hunks {
                guard bytes.consume(32), bytes.string(hunk.header) else { return false }
                for line in hunk.lines {
                    guard bytes.consume(96), bytes.string(line.text) else { return false }
                }
            }
        }
        return !Task.isCancelled
    }

    private struct ByteBudget {
        var remaining: Int

        mutating func consume(_ count: Int) -> Bool {
            guard !Task.isCancelled, count <= remaining else { return false }
            remaining -= count
            return true
        }

        mutating func string(_ text: String) -> Bool {
            guard consume(2), consume(text.utf8.count) else { return false }
            for byte in text.utf8 {
                // JSON control escapes can take six bytes; slashes, quotes
                // and backslashes take two with JSONEncoder's defaults.
                if byte < 0x20 { remaining -= 5 }
                else if byte == 0x22 || byte == 0x5C || byte == 0x2F { remaining -= 1 }
                if remaining < 0 { return false }
            }
            return !Task.isCancelled
        }
    }
}
