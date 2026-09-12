// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with GitPushModels.swift GitCommitModels.swift GitPushSession.swift
// WorkbenchDraftFile.swift OriginalFileCoordination.swift WorkReference.swift.
import Foundation

struct FileDiff: Codable, Sendable {}
struct WorkspaceFolder: Codable, Sendable {}
enum FixtureError: Error { case disconnected, unexpectedTransport }
enum Bridge {
    static func onPeer<T: Decodable & Sendable>(_ peer: String, _ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
    static func localReviewedGit<T: Decodable & Sendable>(_ method: String, _ params: [String: Any], as type: T.Type) async throws -> T { throw FixtureError.unexpectedTransport }
}
enum RemoteHostFeature {
    case selectedCommit, reviewedPush
    func isSupported(peer: String?) async -> Bool { true }
}
@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    var scope: WorkReference.Scope?
    var localHostIdentity: String?
}

actor FixturePush: GitPushService {
    var submissions: [GitPushSubmission] = []
    var receipt: GitPushReceipt?
    func supportsReviewedPush() async -> Bool { true }
    func pushReview() async throws -> GitPushReview {
        GitPushReview(branch: "refs/heads/main", head: "reviewed-head", remote: "origin", remoteRef: "refs/heads/main",
                      endpointDigest: "endpoint", remoteHead: nil, outgoing: 2, setUpstream: true)
    }
    func push(_ submission: GitPushSubmission, retry: Bool) async throws -> GitPushReceipt {
        submissions.append(submission)
        receipt = GitPushReceipt(operationID: submission.operationID, review: submission.review, state: "succeeded",
                                 message: "Pushed", retryAllowed: false)
        throw FixtureError.disconnected
    }
    func pushReceipt(operationID: String, recover: Bool) async throws -> GitPushReceipt? { receipt }
}

@main struct GitPushSessionTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FixturePush()
        func session(host: String = "fixture-computer") -> GitPushSession {
            GitPushSession(target: GitCommitTarget(peer: host, workspaceID: "project"),
                           scope: .local(installationID: "fixture"), hostIdentity: host,
                           service: service, draftDirectory: directory)
        }
        let first = session()
        let stale = session()
        await first.load()
        await stale.load()
        await first.prepare()
        await first.submit()
        assert(first.draft.submitted != nil)
        assert(first.errorMessage != nil)
        await first.submit()
        let firstCount = await service.submissions.count
        assert(firstCount == 1)
        await stale.prepare()
        await stale.submit()
        let staleCount = await service.submissions.count
        assert(staleCount == 1, "Another window cannot replace a submitted push")
        assert(stale.draft.submitted == first.draft.submitted)
        let restored = session()
        await restored.load()
        assert(restored.draft.submitted == first.draft.submitted)
        await restored.checkOutcome()
        assert(restored.outcome?.succeeded == true && restored.draft.submitted == nil)
        let count = await service.submissions.count
        assert(count == 1, "Receipt checking never pushes again")
        let other = session(host: "another-computer")
        await other.load()
        assert(other.draft.submitted == nil)
        print("Push sessions: durable identity, duplicate prevention, stale-window protection and read-only recovery passed")
    }
}
