// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Directory scope is independent of login ownership and the origin of a
/// mounted chat. Choosing an organization never changes WorkSessionContext.
struct TeamAccountOwner: Hashable, Sendable {
    let scope: WorkReference.Scope
    let generation: UInt64
    let session: String
    /// Verified account profile identity; usable for local writing recovery,
    /// never as a substitute for current Team capabilities or membership.
    let personId: String?
    init(scope: WorkReference.Scope, generation: UInt64, session: String, personId: String? = nil) {
        self.scope = scope; self.generation = generation; self.session = session
        self.personId = personId.flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil }
    }
}
enum TeamHostMethod: String, Sendable {
    case capabilities = "teams.capabilities"
    case authorizationPreview = "teams.authorizationPreview"
    case prepareAuthorization = "teams.prepareAuthorization"
    case directory = "teams.directory"
    case checkoutOptions = "teams.checkout.options"
    case checkoutPreview = "teams.checkout.preview"
    case checkoutPublish = "teams.checkout.publish"
    case checkoutList = "teams.checkout.list"
    case checkoutWithdraw = "teams.checkout.withdraw"
    case projectSharingRead = "teams.projectSharing.read"
    case projectSharingBegin = "teams.projectSharing.begin"
    case projectSharingResume = "teams.projectSharing.resume"
    case projectSharingDiscard = "teams.projectSharing.discard"
    case connectionCall = "teams.connection.call"
    case commentSend = "teams.comment.send"
    case ask = "teams.ask"
    case lanesGet = "teams.lanes.get"
    case lanesSet = "teams.lanes.set"
    case lanesCatchUp = "teams.lanes.catchUp"
    case chatOptions = "teams.chat.options"
    case chatPreview = "teams.chat.preview"
    case chatPublish = "teams.chat.publish"
    case chatList = "teams.chat.list"
    case chatWithdraw = "teams.chat.withdraw"
    case chatSharingRead = "teams.chatSharing.read"
    case chatSharingBegin = "teams.chatSharing.begin"
    case chatSharingPreview = "teams.chatSharing.preview"
    case chatSharingPublish = "teams.chatSharing.publish"
    case chatSharingSkip = "teams.chatSharing.skip"
    case chatSharingDiscard = "teams.chatSharing.discard"
}
struct TeamAPI: Sendable {
    let send: @Sendable (TeamHostMethod, JSONValue, TeamAccountOwner) async throws -> JSONValue
    func request<T: Decodable & Sendable>(_ method: TeamHostMethod, _ parameters: [String: JSONValue] = [:], owner: TeamAccountOwner, as: T.Type = T.self) async throws -> T {
        try Task.checkCancellation()
        let value = try await send(method, .object(parameters), owner)
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
struct TeamCapabilities: Decodable, Sendable {
    var canPublishCheckouts = false
    var canConnectCheckouts = false
    var canPublishChats = false
    var canResumeProjectSharing = false
    var canReviewChatSelection = false
    var actorId: String?
    var enabled: Bool
    var ready: Bool
    var needsDeviceRegistration: Bool
    var authorizationRequired: Bool
    var version: Int
    init(enabled: Bool = false, ready: Bool = false, needsDeviceRegistration: Bool = false, authorizationRequired: Bool = true, version: Int = 0, actorId: String? = nil) {
        self.actorId = actorId
        self.enabled = enabled; self.ready = ready && enabled && version == 1 && !needsDeviceRegistration && !authorizationRequired && actorId?.isEmpty == false
        self.needsDeviceRegistration = needsDeviceRegistration
        self.authorizationRequired = authorizationRequired; self.version = version
    }
    private enum CodingKeys: String, CodingKey { case enabled, ready, needsDeviceRegistration, authorizationRequired, version, actorId, canPublishCheckouts, canConnectCheckouts, canPublishChats, canResumeProjectSharing, canReviewChatSelection }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actorId = try c.decodeIfPresent(String.self, forKey: .actorId)
        canPublishCheckouts = try c.decodeIfPresent(Bool.self, forKey: .canPublishCheckouts) ?? false
        canConnectCheckouts = try c.decodeIfPresent(Bool.self, forKey: .canConnectCheckouts) ?? false
        canPublishChats = try c.decodeIfPresent(Bool.self, forKey: .canPublishChats) ?? false
        canResumeProjectSharing = try c.decodeIfPresent(Bool.self, forKey: .canResumeProjectSharing) ?? false
        canReviewChatSelection = try c.decodeIfPresent(Bool.self, forKey: .canReviewChatSelection) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        needsDeviceRegistration = try c.decodeIfPresent(Bool.self, forKey: .needsDeviceRegistration) ?? false
        authorizationRequired = try c.decodeIfPresent(Bool.self, forKey: .authorizationRequired) ?? true
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        ready = ready && enabled && version == 1 && !needsDeviceRegistration && !authorizationRequired && actorId?.isEmpty == false
    }
}
enum TeamOrganizationRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case owner, admin, member
    var id: String { rawValue }
    var canManage: Bool { self == .owner || self == .admin }
}
enum TeamRepositoryRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case viewer, contributor, maintainer
    var id: String { rawValue }
}
struct TeamOrganization: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let slug: String
    let name: String
    let ownerId: String
    let role: TeamOrganizationRole
    let revision: UInt64
    let epoch: UInt64
    let state: String
    let eligible: Bool
    let membershipRevision: UInt64
    let createdAt: String
    var isActive: Bool { state == "active" && eligible }
}
struct TeamOwnershipRequest: Codable, Sendable {
    let requestId: String?
    let fromUserId: String
    let toUserId: String
    let expiresAt: String
    let revision: UInt64
    let current: Bool
}
struct TeamOrganizationDetails: Decodable, Sendable {
    let organization: TeamOrganization
    let ownershipRequest: TeamOwnershipRequest?
}
struct TeamMember: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let handle: String?
    let avatar: String?
    let role: TeamOrganizationRole
    let revision: UInt64
    let eligible: Bool
    let ownershipEligible: Bool?
    let joinedAt: String
}
struct TeamRepository: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let organizationId: String
    let name: String
    let role: TeamRepositoryRole?
    let revision: UInt64
    let createdAt: String
}
struct TeamRepositoryMember: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let handle: String?
    let avatar: String?
    let role: TeamRepositoryRole?
    let revision: UInt64
    let eligible: Bool
}
struct TeamAssignment: Codable, Hashable, Sendable { var repositoryId: String; var role: TeamRepositoryRole }
struct TeamPerson: Codable, Identifiable, Hashable, Sendable { let id: String; let name: String; let handle: String?; let avatar: String? }
struct TeamInvitation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let organizationId: String
    let recipient: TeamPerson?
    let role: TeamOrganizationRole
    let assignments: [TeamAssignment]
    let expiresAt: String
    let revision: UInt64
    let state: String
    let createdAt: String
    let organizationName: String?
    let organizationSlug: String?
}
struct TeamInvitationCreated: Decodable, Sendable { let invitation: TeamInvitation; let invitationURL: String }
struct TeamInvitationRepositoryAccess: Codable, Sendable { let repositoryId: String; let name: String; let role: TeamRepositoryRole }
struct TeamInvitationPreview: Decodable, Sendable {
    let invitation: TeamInvitation
    let eligible: Bool
    let available: Bool
    let unavailableReason: String?
    let repositoryAccess: [TeamInvitationRepositoryAccess]
}
struct TeamCheckout: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let organizationId: String
    let repositoryId: String
    let publisherId: String
    let machineId: String
    let hostKey: String
    var deviceName: String? = nil
    var publisher: TeamPerson? = nil
    let revision: UInt64
    let createdAt: String
}
struct TeamActivityEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String; let actorId: String?; let action: String; let resourceId: String?; let at: String
}
struct TeamOrganizations: Decodable, Sendable { var organizations: [TeamOrganization]; let nextOffset: Int? }
struct TeamMembers: Decodable, Sendable { var members: [TeamMember]; let nextOffset: Int? }
struct TeamRepositories: Decodable, Sendable { var repositories: [TeamRepository]; let nextOffset: Int? }
struct TeamRepositoryMembers: Decodable, Sendable { var members: [TeamRepositoryMember]; let nextOffset: Int? }
struct TeamInvitations: Decodable, Sendable { var invitations: [TeamInvitation]; let nextOffset: Int? }
struct TeamCheckouts: Decodable, Sendable { var checkouts: [TeamCheckout]; let nextOffset: Int? }
struct TeamCheckoutAvailability: Decodable, Sendable {
    let checkoutId: String
    let organizationId: String
    let repositoryId: String
    let state: String
}
struct TeamLocalWorkspace: Codable, Identifiable, Hashable, Sendable { let id: String; let name: String; let path: String }
struct TeamCheckoutOptions: Decodable, Sendable { let workspaces: [TeamLocalWorkspace]; let deviceName: String; let nextOffset: Int? }
struct TeamCheckoutPreview: Decodable, Sendable {
    let repository: TeamRepository; let workspaceId: String; let workspaceName: String
    let preview: String; let sharesExistingChats: Bool; let allowsAgentRuns: Bool
}
struct TeamLocalPublication: Codable, Identifiable, Sendable {
    let id: String; let organizationId: String; let repositoryId: String; let workspaceId: String
    let phase: String; let revision: UInt64; let accountCleanupPending: Bool
}
struct TeamLocalPublications: Decodable, Sendable { let publications: [TeamLocalPublication]; let nextOffset: Int? }
struct TeamCheckoutPublished: Decodable, Sendable { let publication: TeamLocalPublication }
struct TeamCheckoutWithdrawn: Decodable, Sendable { let withdrawn: Bool; let accountCleanupPending: Bool?
}
struct TeamActivity: Decodable, Sendable { var events: [TeamActivityEvent]; let nextOffset: Int? }
struct TeamSharedChat: Codable, Identifiable, Hashable, Sendable {
    let id: String; let checkoutId: String; let revision: UInt64; let createdAt: String
    var title: String? = nil
    var backend: String? = nil
}
struct TeamSharedChats: Decodable, Sendable { let shares: [TeamSharedChat]; let nextOffset: Int? }
struct TeamNewChat: Decodable, Sendable {
    let share: String
    /// Opening the exact creation result must not depend on its position in
    /// a paged catalog. The reader fetches authoritative details before use;
    /// this reference carries no publication revision or creation-date claim.
    func openingReference(checkout: String, title: String) -> TeamSharedChat? {
        guard !share.isEmpty, !checkout.isEmpty else { return nil }
        return TeamSharedChat(id: share, checkoutId: checkout, revision: 0, createdAt: "", title: title)
    }
}
struct TeamAttachmentReply: Decodable, Sendable {
    struct File: Decodable, Sendable { let id: String; let name: String; let mediaType: String?; let size: Int64? }
    let shareId: String; let attachment: File; let data: String
}
struct TeamBackendOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    static func read(_ entries: [JSONValue]) -> [Self] {
        var result: [Self] = [], seen: Set<String> = []
        for entry in entries.prefix(32) {
            guard case let .object(row) = entry, case let .string(id) = row["id"],
                  !id.isEmpty, id.utf8.count <= 64,
                  id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { continue }
            let label: String
            switch row["label"] {
            case .none, .some(.null): label = id
            case let .some(.string(value)):
                guard value.utf16.prefix(129).count <= 128,
                      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                label = trimmed
            default: continue
            }
            if seen.insert(id).inserted { result.append(Self(id: id, label: label)) }
        }
        return result
    }
}
struct TeamChatCatalog: Decodable, Sendable {
    let shares: [TeamSharedChat]
    let nextCursor: String?
    let backends: [TeamBackendOption]?
    private enum CodingKeys: String, CodingKey { case shares, nextCursor, backends }
    private struct BackendMetadata: Decodable {
        let choices: [TeamBackendOption]
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            var entries: [JSONValue] = []
            while !values.isAtEnd && entries.count < 32 { entries.append(try values.decode(JSONValue.self)) }
            choices = TeamBackendOption.read(entries)
        }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shares = try values.decode([TeamSharedChat].self, forKey: .shares)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        // Agent discovery is optional on older publishers. Malformed metadata
        // must not hide valid shared chats or silently replace a draft choice.
        backends = (try? values.decode(BackendMetadata.self, forKey: .backends))?.choices
    }
}
struct TeamChatSummary: Codable, Identifiable, Sendable {
    let id: String; let checkoutId: String; let title: String; let backend: String
    let historyTrimmed: Bool; let allowsAgentRuns: Bool
    var allowsComments: Bool? = nil
}
struct TeamCommentReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case unknown, pending, accepted, notAccepted }
    let shareId: String
    let clientMessageId: String
    let state: State
    let sequence: UInt64?
    let acceptedAtMs: Int64?
    func matches(share: String, message: String) -> Bool {
        shareId == share && clientMessageId == message &&
            (state == .accepted ? sequence != nil && (acceptedAtMs ?? 0) > 0 : sequence == nil && acceptedAtMs == nil)
    }
}
struct TeamCommentResult: Decodable, Sendable { let receipt: TeamCommentReceipt }
struct TeamAgentAttribution: Equatable, Sendable {
    let backend: String
    let name: String?
}
enum TeamMessageAttribution {
    static func agents(_ events: [JSONValue]) throws -> [String: TeamAgentAttribution] {
        var result: [String: TeamAgentAttribution] = [:]
        for case let .object(row) in events where row["kind"] == .string("agent") {
            guard let value = row["author"] else { continue }
            guard case let .object(author) = value, author["kind"] == .string("agent"), row["mode"] == .string("agent"),
                  case let .string(backend)? = row["backend"], author["backend"] == .string(backend),
                  case let .int(sequence)? = row["seq"], sequence >= 0,
                  case let .string(run)? = author["runId"], run.hasPrefix("run_"), run.utf8.count == 36,
                  run.dropFirst(4).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  case let .object(person)? = author["initiatedBy"] else { throw CocoaError(.coderReadCorrupt) }
            let attribution: TeamAgentAttribution
            if person["kind"] == .string("formerMember") {
                attribution = .init(backend: backend, name: nil)
            } else {
                guard person["kind"] == .string("person") else { throw CocoaError(.coderReadCorrupt) }
                let actor = try JSONDecoder().decode(TeamPerson.self, from: JSONEncoder().encode(JSONValue.object(person)))
                guard !actor.id.isEmpty, actor.id.utf8.count <= 128, !actor.name.isEmpty, actor.name.count <= 128 else { throw CocoaError(.coderReadCorrupt) }
                attribution = .init(backend: backend, name: actor.name)
            }
            for prefix in ["text", "think", "tool", "edit", "failed", "usage"] {
                guard result.updateValue(attribution, forKey: "\(prefix)-s\(sequence)") == nil else { throw CocoaError(.coderReadCorrupt) }
            }
        }
        return result
    }

    static func people(_ events: [JSONValue]) throws -> [String: TeamPerson] {
        var people: [String: TeamPerson] = [:]
        for case let .object(row) in events where row["kind"] == .string("user") {
            guard case let .object(author)? = row["author"], author["kind"] == .string("person") else { continue }
            guard row["mode"] == .string("comment") || row["mode"] == .string("ask"), case let .int(sequence)? = row["seq"], sequence >= 0 else { throw CocoaError(.coderReadCorrupt) }
            let person = try JSONDecoder().decode(TeamPerson.self, from: JSONEncoder().encode(JSONValue.object(author)))
            guard !person.id.isEmpty, person.id.utf8.count <= 128, !person.name.isEmpty, person.name.count <= 128,
                  people.updateValue(person, forKey: "user-s\(sequence)") == nil else { throw CocoaError(.coderReadCorrupt) }
        }
        return people
    }
    /// Comments and Asks by people who have left the organization. The host
    /// sends no name or id for them, only that they were here.
    static func former(_ events: [JSONValue]) -> Set<String> {
        Set(events.compactMap { event in
            guard case let .object(row) = event, row["kind"] == .string("user"),
                  case let .object(author)? = row["author"], author["kind"] == .string("formerMember"),
                  case let .int(sequence)? = row["seq"], sequence >= 0 else { return nil }
            return "user-s\(sequence)"
        })
    }
    static func asks(_ events: [JSONValue]) -> Set<String> {
        Set(events.compactMap { event in
            guard case let .object(row) = event, row["kind"] == .string("user"), row["mode"] == .string("ask"),
                  case let .int(sequence)? = row["seq"], sequence >= 0 else { return nil }
            return "user-s\(sequence)"
        })
    }
}
struct TeamChatDetails: Decodable, Sendable { let chat: TeamChatSummary }
struct TeamChatHistory: Codable, Sendable {
    let title: String; let backend: String; let historyTrimmed: Bool; let events: [JSONValue]
    var renderId = UUID()
    private enum CodingKeys: String, CodingKey { case title, backend, historyTrimmed, events }
}
struct TeamChatEvents: Decodable, Sendable {
    let shareId: String; let events: [JSONValue]; let nextCursor: String?
    let firstCursor: String?; let lastCursor: String?; let hasMore: Bool; let historyTrimmed: Bool; let asOfMs: Int64
}
struct TeamLocalChat: Codable, Identifiable, Sendable { let id: String; let title: String; let backend: String; let shared: Bool }
struct TeamLocalChats: Decodable, Sendable { let chats: [TeamLocalChat]; let nextOffset: Int? }
struct TeamChatPreview: Decodable, Sendable {
    let conversation: String; let checkoutId: String; let repository: TeamRepository; let deviceName: String
    let history: TeamChatHistory; let preview: String; let audience: String; let allowsAgentRuns: Bool
}
struct TeamChatPublication: Codable, Identifiable, Sendable { let id: String; let checkoutId: String; let revision: UInt64 }
struct TeamChatPublished: Decodable, Sendable { let publication: TeamChatPublication }
struct TeamLocalChatPublication: Decodable, Identifiable, Sendable {
    let id: String; let checkoutId: String; let conversationId: String; let phase: String; let revision: UInt64; let accountCleanupPending: Bool
}
struct TeamLocalChatPublications: Decodable, Sendable { let publications: [TeamLocalChatPublication]; let nextOffset: Int? }
struct TeamAuthorizationPreview: Decodable, Sendable { let deviceKey: String; let deviceName: String }
struct TeamAuthorization: Decodable, Sendable { let authorizationURL: String; let deviceKey: String; let deviceName: String }

enum TeamSection: String, CaseIterable, Identifiable, Sendable {
    case overview, chats, members, invitations, repositories, settings
    var id: String { rawValue }
}
struct TeamSelectionKey: Hashable, Sendable { let owner: TeamAccountOwner?; let organizationId: String? }
struct TeamMutationContext: Equatable, Sendable { let owner: TeamAccountOwner; let organizationId: String?; let lifetime: UInt64 }

@MainActor enum TeamDate {
    private static let fractional: ISO8601DateFormatter = { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter }()
    private static let standard = ISO8601DateFormatter()
    static func parse(_ value: String) -> Date? { fractional.date(from: value) ?? standard.date(from: value) }
}

/// Only the hosted first-party avatar route may be fetched. A profile never
/// chooses a network origin, path traversal, query or external image service.
func teamAvatarURL(_ path: String?, owner: TeamAccountOwner?) -> URL? {
    guard let path, let owner, path.hasPrefix("/avatar/"),
          let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
          !name.isEmpty, name.count <= 128, !name.contains(".."), path == "/avatar/\(name)",
          name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
          let origin = URLComponents(string: owner.scope.origin), let scheme = origin.scheme,
          ["https", "http"].contains(scheme), origin.user == nil, origin.password == nil,
          scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(origin.host ?? ""),
          origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { return nil }
    return URL(string: owner.scope.origin + path)
}
