// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// What a pull would do, as of the fetch review just made on the host.
struct GitPullReview: Codable, Sendable, Equatable {
    let branch: String
    let head: String
    let remote: String
    let remoteRef: String
    let upstreamHead: String?
    let incoming: UInt64
    let outgoing: UInt64
    let state: State

    enum State: String, Codable, Sendable {
        case upToDate, ahead, fastForward, diverged, missing
    }

    var branchName: String { String(branch.dropFirst("refs/heads/".count)) }
    var source: String { remote + "/" + remoteRef.replacingOccurrences(of: "refs/heads/", with: "") }
}

struct GitPullOutcome: Codable, Sendable, Equatable {
    let ok: Bool
    let message: String
    let head: String?
}

protocol GitPullService: Sendable {
    func supportsReviewedPull() async -> Bool
    func pullReview() async throws -> GitPullReview
    func pull(_ review: GitPullReview) async throws -> GitPullOutcome
}

extension GitCommitTarget: GitPullService {
    func supportsReviewedPull() async -> Bool {
        await RemoteHostFeature.reviewedPull.isSupported(peer: peer)
    }
    func pullReview() async throws -> GitPullReview {
        try await call("workspace.pullReview", [:], as: GitPullReview.self)
    }
    func pull(_ review: GitPullReview) async throws -> GitPullOutcome {
        let reviewed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review))
        return try await call("workspace.pullReviewed", ["review": reviewed], as: GitPullOutcome.self)
    }
}

/// The pull request a branch belongs to, in the few words a chip needs.
struct BranchPull: Codable, Sendable, Hashable {
    let number: UInt32
    let title: String
    let url: String
    /// `open`, `merged` or `closed`.
    let state: String
    let draft: Bool
    let baseRef: String

    var webURL: URL? {
        guard let value = URL(string: url), value.scheme?.lowercased() == "https", value.host != nil else { return nil }
        return value
    }

    var symbol: String {
        if draft, state == "open" { return "pencil.line" }
        switch state {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark.circle"
        default: return "arrow.triangle.pull"
        }
    }

    var stateLabel: String {
        if draft, state == "open" { return L10n.text("apple.branchpull.draft") }
        switch state {
        case "merged": return L10n.text("apple.branchpull.merged")
        case "closed": return L10n.text("apple.branchpull.closed")
        default: return L10n.text("apple.branchpull.open")
        }
    }
}

struct BranchPullAnswer: Codable, Sendable, Equatable {
    let branch: String?
    let pull: BranchPull?
    let connected: Bool
}
