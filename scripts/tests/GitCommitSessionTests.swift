// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with GitCommitModels.swift GitCommitSession.swift WorkbenchDraftFile.swift
// OriginalFileCoordination.swift WorkReference.swift.
import Foundation

struct FileDiff: Codable, Sendable {}
struct WorkspaceFolder: Codable, Sendable {}
enum FixtureError: Error { case disconnected, unexpectedTransport }
enum Bridge {
    static func onPeer<T: Decodable & Sendable>(_ peer: String, _ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
    static func localReviewedGit<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
}
enum RemoteHostFeature {
    case selectedCommit
    func isSupported(peer: String?) async -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}

actor FixtureGit: GitCommitService {
    func status() async throws -> WorkspaceFolder { WorkspaceFolder() }
    var submissions = 0
    var last: GitCommitReceipt?
    func supportsReviewedCommit() async -> Bool { true }
    func review(paths: [String]) async throws -> GitCommitReview {
        GitCommitReview(branch: "refs/heads/main", head: "before", baseTree: "before-tree", indexDigest: "index", tree: "reviewed-tree", paths: paths, includedPaths: paths)
    }
    func diff(_ review: GitCommitReview, path: String) async throws -> FileDiff { FileDiff() }
    func commit(_ submission: GitCommitSubmission) async throws -> GitCommitReceipt {
        submissions += 1
        last = GitCommitReceipt(operationID: submission.operationID, state: "succeeded", commit: "landed", message: "Committed")
        throw FixtureError.disconnected
    }
    func receipt(operationID: String, recover: Bool) async throws -> GitCommitReceipt? { last }
}

@main struct GitCommitSessionTests {
    @MainActor static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scope = WorkReference.Scope.local(installationID: "fixture")
        let service = FixtureGit()
        func session(host: String = "fixture-computer") -> GitCommitSession {
            GitCommitSession(target: GitCommitTarget(peer: host, workspaceID: "project"), scope: scope,
                             hostIdentity: host, service: service, draftDirectory: dir)
        }
        let first = session()
        await first.load()
        first.draft.title = "Keep this commit title"
        first.draft.details = "A longer description"
        first.select("chosen.swift")
        await first.persist()
        await first.prepareReview()
        assert(first.canCommit)
        await first.submit()
        assert(first.draft.submitted != nil, "A lost response retains the submitted identity")
        assert(first.draft.title == "Keep this commit title")
        assert(!first.canCommit)
        await first.submit()
        let count = await service.submissions
        assert(count == 1, "A repeated tap must not start another commit")

        let restored = session()
        await restored.load()
        assert(restored.draft.submitted == first.draft.submitted)
        assert(restored.draft.title == first.draft.title)
        await restored.checkOutcome()
        assert(restored.outcome?.succeeded == true)
        assert(restored.draft.submitted == nil && restored.draft.title.isEmpty)
        let confirmedCount = await service.submissions
        assert(confirmedCount == 1, "Checking the receipt must not submit again")

        let other = session(host: "another-computer")
        await other.load()
        assert(other.draft.paths.isEmpty && other.draft.title.isEmpty)
        // The first process still holds the old revision. It cannot resurrect
        // its pending operation over the second process's confirmed result.
        first.draft.details = "More writing in the old window"
        let staleSaved = await first.persist()
        assert(!staleSaved && first.saveError != nil)
        assert(first.draft.details == "More writing in the old window")

        let clean = session()
        await clean.load()
        assert(clean.draft == GitCommitDraft())
        clean.draft.title = "Saved in another window"
        await clean.persist()
        restored.draft.title = "Writing to retain"
        let conflictingSave = await restored.persist()
        assert(!conflictingSave)
        await restored.compareSavedVersion()
        assert(restored.savedAlternative?.draft.title == "Saved in another window")
        assert(restored.canUseSavedVersion && restored.canKeepCurrentVersion)
        await restored.keepCurrentVersion()
        let compared = session()
        await compared.load()
        assert(compared.draft.title == "Writing to retain")
        // An unresolved submission cannot disappear through draft comparison.
        await first.compareSavedVersion()
        assert(!first.canUseSavedVersion)
        print("Git commit sessions: saved writing, host isolation, lost response, duplicate taps and cross-instance conflict passed")
    }
}
