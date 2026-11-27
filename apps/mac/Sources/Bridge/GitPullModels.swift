// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct GitPullReview: Codable, Sendable, Equatable {
    let branch: String
    let head: String
    let remote: String
    let remoteRef: String
    let upstreamHead: String?
    let incoming: UInt64
    let outgoing: UInt64
    let state: State
    var lfs: GitLFSStatus? = nil

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

protocol GitPullService: GitLFSService {
    func supportsReviewedPull() async -> Bool
    func pullReview() async throws -> GitPullReview
    func pull(_ review: GitPullReview) async throws -> GitPullOutcome
}

extension GitCommitTarget: GitPullService {
    func supportsReviewedPull() async -> Bool {
        await RemoteHostFeature.reviewedPull.isSupported(peer: peer)
    }
    func pullReview() async throws -> GitPullReview {
        try await call("workspace.pullReview", [:], patience: Bridge.Patience.long, as: GitPullReview.self)
    }
    func pull(_ review: GitPullReview) async throws -> GitPullOutcome {
        let reviewed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review))
        return try await call("workspace.pullReviewed", ["review": reviewed], patience: Bridge.Patience.long, as: GitPullOutcome.self)
    }
}

struct BranchPull: Codable, Sendable, Hashable {
    let number: UInt32
    let title: String
    let url: String
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

struct ChatPull: Codable, Sendable, Hashable, Identifiable {
    var id: String { url }
    let number: UInt32
    let title: String
    let url: String
    let state: String
    let draft: Bool
    var repo: String?
    var additions: UInt32?
    var deletions: UInt32?
    var opened: Bool?
    var workspaceId: String?

    init(_ pull: BranchPull) {
        number = pull.number
        title = pull.title
        url = pull.url
        state = pull.state
        draft = pull.draft
    }

    init(_ pull: PullSummary, url: String, workspaceID: String) {
        number = pull.number
        title = pull.title
        self.url = url
        state = pull.state
        draft = pull.draft
        additions = pull.additions
        deletions = pull.deletions
        workspaceId = workspaceID
    }

    var webURL: URL? {
        guard let value = URL(string: url), value.scheme?.lowercased() == "https", value.host != nil else { return nil }
        return value
    }

    var name: String {
        let parts = webURL?.pathComponents.filter { $0 != "/" } ?? []
        guard let repo = repo ?? (parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil) else { return "#\(number)" }
        return "\(repo) #\(number)"
    }

    var stateLabel: String {
        if draft, state == "open" { return L10n.text("apple.branchpull.draft") }
        switch state {
        case "merged": return L10n.text("apple.branchpull.merged")
        case "closed": return L10n.text("apple.branchpull.closed")
        default: return L10n.text("apple.branchpull.open")
        }
    }

    static func lead(of pulls: [ChatPull]) -> ChatPull? {
        pulls.first { $0.state == "open" && !$0.draft } ?? pulls.first { $0.state == "open" }
            ?? pulls.first { $0.state == "merged" } ?? pulls.first
    }
}

@MainActor @Observable
final class PullOpenPreference {
    enum Choice: String, CaseIterable, Sendable { case ask, here, browser }

    static let shared = PullOpenPreference()
    private static let key = "pulls.openIn"

    var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
    }

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.key).flatMap(Choice.init) ?? .ask
    }

    static func label(_ choice: Choice) -> String {
        switch choice {
        case .ask: L10n.text("common.pulls.open_in_ask")
        case .here: "tokenstat"
        case .browser: L10n.text("common.pulls.open_in_browser")
        }
    }
}

@MainActor @Observable
final class PullOpenRequest {
    static let shared = PullOpenRequest()

    struct Pending: Equatable {
        let id = UUID()
        let folderID: String
        let pull: ChatPull
    }

    var pending: Pending?
}

extension PullSummary {
    init(_ pull: ChatPull) {
        self.init(number: pull.number, title: pull.title, author: "", authorAvatar: nil, createdAt: "", updatedAt: "",
                  headRef: "", baseRef: "", additions: pull.additions ?? 0, deletions: pull.deletions ?? 0,
                  changedFiles: 0, state: pull.state, draft: pull.draft, reviewDecision: nil, labels: [],
                  comments: 0, checks: nil)
    }
}

struct BranchPullAnswer: Codable, Sendable, Equatable {
    let branch: String?
    let pull: BranchPull?
    let connected: Bool
}
