// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct GitPushReview: Codable, Sendable, Equatable {
    let branch: String
    let head: String
    let remote: String
    let remoteRef: String
    let endpointDigest: String
    let remoteHead: String?
    let outgoing: UInt64?
    let setUpstream: Bool

    var branchName: String { String(branch.dropFirst("refs/heads/".count)) }
    var destination: String { remote + "/" + remoteRef.replacingOccurrences(of: "refs/heads/", with: "") }
    var upToDate: Bool { remoteHead == head }
}

struct GitPushSubmission: Codable, Sendable, Equatable {
    let operationID: String
    let review: GitPushReview
    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case review
    }
}

struct GitPushReceipt: Codable, Sendable, Equatable {
    let operationID: String
    let review: GitPushReview
    let state: String
    let message: String
    let retryAllowed: Bool
    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case review, state, message, retryAllowed
    }
    var succeeded: Bool { state == "succeeded" }
    var finished: Bool { succeeded || state == "failed" }
}

protocol GitPushService: Sendable {
    func supportsReviewedPush() async -> Bool
    func pushReview() async throws -> GitPushReview
    func push(_ submission: GitPushSubmission, retry: Bool) async throws -> GitPushReceipt
    func pushReceipt(operationID: String, recover: Bool) async throws -> GitPushReceipt?
}

extension GitCommitTarget: GitPushService {
    func supportsReviewedPush() async -> Bool {
        await RemoteHostFeature.reviewedPush.isSupported(peer: peer)
    }
    func pushReview() async throws -> GitPushReview {
        try await call("workspace.pushReview", [:], as: GitPushReview.self)
    }
    func push(_ submission: GitPushSubmission, retry: Bool) async throws -> GitPushReceipt {
        let review = try JSONSerialization.jsonObject(with: JSONEncoder().encode(submission.review))
        return try await call("workspace.pushReviewed", ["operationId": submission.operationID, "review": review, "retry": retry], as: GitPushReceipt.self)
    }
    func pushReceipt(operationID: String, recover: Bool) async throws -> GitPushReceipt? {
        try await call(recover ? "workspace.pushRecover" : "workspace.pushReceipt", ["operationId": operationID], as: GitPushReceipt?.self)
    }
}
