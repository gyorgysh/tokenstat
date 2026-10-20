// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum TeamFixtureData {
    enum State: String { case ready, empty, authorization, unavailable, failure, paused, member, invitation, expiredInvitation }
    static let state: State = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--fixture-state"), args.indices.contains(index + 1) else { return .ready }
        return State(rawValue: args[index + 1]) ?? .ready
    }()
    static let timestamp = "2026-01-01T00:00:00.000Z"
    static let organization = TeamOrganization(id: "org_fixture", slug: "example-studio", name: "Example Studio", ownerId: "fixture-owner", role: state == .member ? .member : .owner, revision: 5, epoch: 5, state: state == .paused ? "paused" : "active", eligible: true, membershipRevision: 1, createdAt: timestamp)
    static let repository = TeamRepository(id: "repo_fixture", organizationId: organization.id, name: "Website", role: .maintainer, revision: 1, createdAt: timestamp)
    static let member = TeamMember(id: "fixture-member", name: "Márta Nagy", handle: "example-marta", avatar: nil, role: .member, revision: 1, eligible: true, ownershipEligible: true, joinedAt: timestamp)
    static let invitation = TeamInvitation(id: "invite_fixture", organizationId: "org_partner", recipient: nil, role: .member, assignments: [TeamAssignment(repositoryId: "repo_partner", role: .viewer)], expiresAt: timestamp, revision: 1, state: state == .expiredInvitation ? "expired" : "pending", createdAt: timestamp, organizationName: "Partner Studio", organizationSlug: "partner-studio")
    static let members = [TeamMember(id: "fixture-owner", name: "Example owner", handle: "example-owner", avatar: nil, role: .owner, revision: 1, eligible: true, ownershipEligible: true, joinedAt: timestamp), member,
        TeamMember(id: "fixture-admin", name: "Alex Morgan", handle: "example-alex", avatar: nil, role: .admin, revision: 1, eligible: true, ownershipEligible: false, joinedAt: timestamp),
        TeamMember(id: "fixture-downgraded", name: "山田 太郎", handle: "example-taro", avatar: nil, role: .member, revision: 1, eligible: false, ownershipEligible: false, joinedAt: timestamp)]
    static func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    static let api = TeamAPI { method, params, _ in
        switch method {
        case .capabilities:
            if state == .failure { throw TeamRequestFailure(code: "teams_unreachable", message: "The fictional account server is unavailable.") }
            return .object(["enabled":.bool(state != .unavailable), "ready":.bool(state != .authorization), "authorizationRequired":.bool(state == .authorization), "actorId":.string(state == .member ? "fixture-member" : "fixture-owner"), "version":.int(1)])
        case .authorizationPreview: return .object(["deviceName":.string("Example Mac"),"deviceKey":.string(String(repeating:"ab",count:32))])
        case .prepareAuthorization: return .object(["authorizationURL":.string("https://accounts.example.test/settings/teams/devices/fixture"),"deviceName":.string("Example Mac"),"deviceKey":.string(String(repeating:"ab",count:32))])
        case .directory:
            guard case let .object(fields) = params, case let .string(operation)? = fields["operation"] else { throw TeamRequestFailure(code: "fixture_request", message: "Choose a fixture action.") }
            switch operation {
            case "organizations.list": return .object(["organizations":.array(state == .empty ? [] : [try json(organization)]),"nextOffset":.null])
            case "organizations.get": return .object(["organization":try json(organization),"ownershipRequest":.null])
            case "members.list": return .object(["members":.array(try members.map { try json($0) }),"nextOffset":.null])
            case "repositories.list": return .object(["repositories":.array([try json(repository)]),"nextOffset":.null])
            case "repositories.members": return .object(["members":.array(try members.map { try json(TeamRepositoryMember(id: $0.id, name: $0.name, handle: $0.handle, avatar: nil, role: $0.role == .owner ? .maintainer : nil, revision: 1, eligible: $0.eligible)) }),"nextOffset":.null])
            case "inbox.list": return .object(["invitations":.array(state == .invitation || state == .expiredInvitation ? [try json(invitation)] : []),"nextOffset":.null])
            case "invitations.list": return .object(["invitations":.array([]),"nextOffset":.null])
            case "inbox.get": return .object(["invitation":try json(invitation),"eligible":.bool(true),"available":.bool(state != .expiredInvitation),"unavailableReason":.null,"repositoryAccess":.array(state == .expiredInvitation ? [] : [try json(TeamInvitationRepositoryAccess(repositoryId: "repo_partner", name: "Partner website", role: .viewer))])])
            default: throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.")
            }
        }
    }
}
