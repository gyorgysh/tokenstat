// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// An exact, expiring request for the paired Watch, with any chat-only rule visible.
struct EcosystemApproval: Codable, Equatable, Sendable, Identifiable {
    var id: String { peer + ":" + requestID }
    let requestID: String
    let conversationID: String
    let peer: String
    let host: String
    let verb: String
    let preview: String
    let fingerprint: String
    let expiresAt: Date
    var requiresPhoneReview = false
    var alwaysAllowScope: String? = nil

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case conversationID = "conversationId"
        case peer, host, verb, preview, fingerprint, expiresAt, requiresPhoneReview, alwaysAllowScope
    }

    var isValid: Bool {
        [requestID, conversationID, peer, verb].allSatisfy { !$0.isEmpty && $0.utf8.count <= 2048 }
            && host.utf8.count <= 512 && preview.utf8.count <= 8192
            && fingerprint.count == 64 && fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && expiresAt.timeIntervalSince1970.isFinite
            && (alwaysAllowScope.map { !$0.isEmpty && $0.utf8.count <= 2048 } ?? true)
    }
    func allows(_ choice: String, at date: Date = Date()) -> Bool {
        isValid && date < expiresAt && (choice == "deny" || (!requiresPhoneReview
            && (choice == "allow" || (choice == "allowAlways" && alwaysAllowScope != nil))))
    }
}

#if os(iOS) && !ECOSYSTEM_QA
import CryptoKit

@MainActor enum EcosystemApprovalService {
    private static var cachedOwner: String?
    private static var cached: [EcosystemApproval] = []
    private static var revision = UUID()
    static func clear() { revision = UUID(); cachedOwner = nil; cached = [] }

    static func requests(for owner: String?) -> [EcosystemApproval] {
        guard let owner, owner == cachedOwner else { return [] }
        return cached.filter { $0.expiresAt > Date() && EcosystemPublisher.isAuthorizedPeer($0.peer) }
    }

    private static func authorize(owner: String?) async throws -> (Account, EcosystemPublicationLease) {
        BridgeLaunch.begin()
        await BridgeLaunch.wait()
        let before = EcosystemPublisher.lease
        let account = try await Bridge.account()
        guard before == EcosystemPublisher.lease else { throw EcosystemIntentError.sessionChanged }
        WorkSessionContext.shared.update(account: account)
        EcosystemPublisher.verifyOwner(account: account, loadInitial: false)
        guard account.signedIn, let lease = EcosystemPublisher.lease,
              owner == nil || owner == lease.owner else { throw EcosystemIntentError.sessionChanged }
        return (account, lease)
    }

    static func load(owner: String?) async throws -> [EcosystemApproval] {
        let (account, lease) = try await authorize(owner: owner)
        let requestedRevision = UUID()
        revision = requestedRevision
        let allowed = Set(account.machines.filter { $0.trustState != "revoked" }.compactMap(\.publicIdentity))
        let peers = try await Bridge.peers().filter { $0.trust == .approved && allowed.contains($0.key) }
        var requests: [EcosystemApproval] = []
        var successful = peers.isEmpty
        // These are existing, approved connections. Never pair or grant a
        // device access merely because the Watch asks to refresh.
        let results = await withTaskGroup(of: [EcosystemApproval]?.self) { group in
            for peer in peers.prefix(8) {
                group.addTask {
                    guard let rows = try? await Bridge.pendingChatApprovals(peer: peer.key) else { return nil }
                    return rows.filter { $0.decision == nil && Double($0.expiresAtMs) / 1000 > Date().timeIntervalSince1970 }
                        .map { request($0, peer: peer.key, host: peer.label) }
                }
            }
            var results: [[EcosystemApproval]?] = []
            for await result in group { results.append(result) }
            return results
        }
        guard EcosystemPublisher.isCurrent(lease), revision == requestedRevision else { throw EcosystemIntentError.sessionChanged }
        for rows in results {
            if let rows {
                successful = true
                requests += rows
            }
        }
        guard successful else { throw EcosystemIntentError.usageUnavailable }
        cachedOwner = lease.owner
        var seen = Set<String>()
        cached = Array(requests.filter { $0.isValid && seen.insert($0.id).inserted }
            .sorted { $0.expiresAt < $1.expiresAt }.prefix(12))
        return cached
    }

    static func resolve(_ viewed: EcosystemApproval, owner: String, choice: String) async throws {
        guard viewed.allows(choice) else { throw EcosystemIntentError.projectUnavailable }
        let (account, lease) = try await authorize(owner: owner)
        guard account.machines.contains(where: { $0.publicIdentity == viewed.peer && $0.trustState != "revoked" }),
              try await Bridge.peers().contains(where: { $0.key == viewed.peer && $0.trust == .approved }) else {
            throw EcosystemIntentError.projectUnavailable
        }
        let live = try await Bridge.pendingChatApprovals(peer: viewed.peer)
        guard EcosystemPublisher.isCurrent(lease),
              let current = live.first(where: { $0.id == viewed.requestID && $0.decision == nil }),
              request(current, peer: viewed.peer, host: viewed.host) == viewed,
              viewed.allows(choice) else { throw EcosystemIntentError.projectUnavailable }
        // The host applies a persistent rule only within this conversation.
        revision = UUID()
        _ = try await Bridge.resolveChatApproval(id: viewed.requestID, choice: choice, peer: viewed.peer)
        guard EcosystemPublisher.isCurrent(lease) else { throw EcosystemIntentError.sessionChanged }
        revision = UUID()
        cached.removeAll { $0.id == viewed.id }
    }

    nonisolated private static func request(_ row: ChatApproval, peer: String, host: String) -> EcosystemApproval {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try? encoder.encode(row)
        let fingerprint = SHA256.hash(data: data ?? Data()).map { String(format: "%02x", $0) }.joined()
        let oversized = row.preview.utf8.count > 8192
        let prefix = row.shellPrefix
        let name = row.verb.lowercased()
        let isShell = ["bash", "shell", "command", "terminal"].contains(where: name.contains)
            || name.split(whereSeparator: { !$0.isASCII || !$0.isLetter && !$0.isNumber })
                .contains { ["sh", "zsh", "exec", "run"].contains(String($0)) }
        let scope = prefix ?? (isShell ? nil : row.verb)
        return .init(requestID: row.id, conversationID: row.conversationID, peer: peer, host: String(host.prefix(128)),
                     verb: row.verb, preview: oversized ? String(row.preview.prefix(1024)) : row.preview,
                     fingerprint: fingerprint, expiresAt: Date(timeIntervalSince1970: Double(row.expiresAtMs) / 1000),
                     requiresPhoneReview: oversized,
                     alwaysAllowScope: scope.flatMap { !$0.isEmpty && $0.utf8.count <= 2048 ? $0 : nil })
    }
}
#endif
