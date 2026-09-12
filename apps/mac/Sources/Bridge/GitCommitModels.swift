// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// The host's immutable selection, including the branch and index it was read
/// from. Sending this back cannot silently commit a newer worktree snapshot.
struct GitCommitReview: Codable, Sendable, Equatable {
    let branch: String
    let head: String?
    let baseTree: String
    let indexDigest: String
    let tree: String
    let paths: [String]
    let includedPaths: [String]

    var branchName: String { branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch }

    func parameters() throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }
}

struct GitCommitReceipt: Codable, Sendable, Equatable {
    let operationID: String
    let state: String
    let commit: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case state, commit, message
    }

    var succeeded: Bool { state == "succeeded" }
    var unresolved: Bool { state != "succeeded" && state != "failed" }
}

/// A persisted submitted snapshot belongs to its original target and ID.
/// Reopening a composer reconciles this record before allowing another commit.
struct GitCommitSubmission: Codable, Sendable, Equatable {
    let operationID: String
    let review: GitCommitReview
    let message: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case review, message
    }
}

/// Mobile always supplies a peer. Only desktop callers may target the local
/// host, so a failed mobile connection never falls back to another repository.
protocol GitCommitService: Sendable {
    func status() async throws -> WorkspaceFolder
    func supportsReviewedCommit() async -> Bool
    func review(paths: [String]) async throws -> GitCommitReview
    func diff(_ review: GitCommitReview, path: String) async throws -> FileDiff
    func commit(_ submission: GitCommitSubmission) async throws -> GitCommitReceipt
    func receipt(operationID: String, recover: Bool) async throws -> GitCommitReceipt?
}

struct GitCommitTarget: Hashable, Sendable, GitCommitService {
    static let didChange = Notification.Name("tokenstat.workspaceGitDidChange")
    let peer: String?
    let workspaceID: String

    @MainActor func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func status() async throws -> WorkspaceFolder {
        try await call("workspace.status", [:], as: WorkspaceFolder.self)
    }

    func supportsReviewedCommit() async -> Bool {
        await RemoteHostFeature.selectedCommit.isSupported(peer: peer)
    }

    func review(paths: [String]) async throws -> GitCommitReview {
        try await call("workspace.commitReview", ["paths": paths], as: GitCommitReview.self)
    }

    func diff(_ review: GitCommitReview, path: String) async throws -> FileDiff {
        try await call("workspace.commitReviewDiff", ["review": review.parameters(), "path": path], as: FileDiff.self)
    }

    func commit(_ submission: GitCommitSubmission) async throws -> GitCommitReceipt {
        try await call("workspace.commitSelected", [
            "operationId": submission.operationID,
            "review": submission.review.parameters(), "message": submission.message,
        ], as: GitCommitReceipt.self)
    }

    func receipt(operationID: String, recover: Bool = false) async throws -> GitCommitReceipt? {
        try await call(recover ? "workspace.commitRecover" : "workspace.commitReceipt",
                       ["operationId": operationID], as: GitCommitReceipt?.self)
    }

    func call<T: Decodable & Sendable>(_ method: String, _ values: [String: Any], as type: T.Type) async throws -> T {
        var params = values
        params["id"] = workspaceID
        if let peer {
            return try await Bridge.onPeer(peer, method, params, as: type)
        }
        #if os(macOS)
        return try await Bridge.localReviewedGit(method, params, as: type)
        #else
        throw CocoaError(.fileReadNoSuchFile)
        #endif
    }
}
