// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

actor TeamFixtureProjects {
    static let shared = TeamFixtureProjects()
    private(set) var hasNewProject = false
    func addProject() { hasNewProject = true }
}

enum TeamFixtureData {
    enum State: String { case ready, empty, authorization, unavailable, failure, paused, member, invitation, expiredInvitation, comment, commentUncertain, commentViewer, draftOffline, askUncertain }
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
    static let chatEvents: [JSONValue] = [.object(["kind":.string("user"),"text":.string("Compare the fictional quarterly totals."),"seq":.int(0),"atMs":.int(1)]),.object(["kind":.string("agent"),"backend":.string("codex"),"seq":.int(100),"atMs":.int(2),"event":.object(["kind":.string("text"),"delta":.string("The fictional total increased from 24 to 42.")])])]
    static let api = TeamAPI { method, params, _ in
        switch method {
        case .capabilities:
            if state == .failure || state == .draftOffline { throw TeamRequestFailure(code: "teams_unreachable", message: "The fictional account server is unavailable.") }
            return .object(["enabled":.bool(state != .unavailable), "ready":.bool(state != .authorization), "authorizationRequired":.bool(state == .authorization), "actorId":.string(state == .member ? "fixture-member" : "fixture-owner"), "version":.int(1),"canPublishCheckouts":.bool(true),"canConnectCheckouts":.bool(true),"canPublishChats":.bool(true)])
        case .authorizationPreview: return .object(["deviceName":.string("Example Mac"),"deviceKey":.string(String(repeating:"ab",count:32))])
        case .prepareAuthorization: return .object(["authorizationURL":.string("https://accounts.example.test/settings/teams/devices/fixture"),"deviceName":.string("Example Mac"),"deviceKey":.string(String(repeating:"ab",count:32))])
        case .checkoutOptions: return .object(["deviceName":.string("Example Mac"),"workspaces":.array([try json(TeamLocalWorkspace(id: "/example/Website", name: "Website", path: "/example/Website")),try json(TeamLocalWorkspace(id: "/example/Feature checkout", name: "Website feature", path: "/example/Feature checkout"))]),"nextOffset":.null])
        case .checkoutPreview:
            guard case let .object(fields) = params, case let .string(workspace)? = fields["workspace"] else { throw CancellationError() }
            return .object(["repository":try json(repository),"workspaceId":.string(workspace),"workspaceName":.string("Website"),"preview":.string(String(repeating:"ab",count:32)),"sharesExistingChats":.bool(false),"allowsAgentRuns":.bool(false)])
        case .checkoutList: return .object(["publications":.array([try json(TeamLocalPublication(id: "checkout_" + String(repeating:"a",count:32), organizationId: organization.id, repositoryId: repository.id, workspaceId: "/example/Website", phase: "active", revision: 2, accountCleanupPending: false))]),"nextOffset":.null])
        case .connectionCall:
            if await TeamFixtureComments.shared.accessRemoved { throw TeamRequestFailure(code: "forbidden", message: "Access to this fictional repository was removed.") }
            guard case let .object(fields) = params, case let .object(target)? = fields["target"], let checkout = target["checkout"], let organization = target["organization"], let repository = target["repository"] else { throw CancellationError() }
            if fields["method"] == .string("team.lanes") { return .object(["lanes": .array([])]) }
            if fields["method"] == .string("team.chat.catalog") {
                guard target["share"] == nil else { throw CancellationError() }
                let own = checkout == .string("checkout_" + String(repeating: "a", count: 32))
                return .object(["shares":.array([.object(["id":.string("share_"+String(repeating: own ? "a" : "b",count:32)),"checkoutId":checkout,"revision":.int(1),"createdAt":.string(timestamp),"title":.string(own ? "Quarterly totals" : "Teammate's feature"),"backend":.string("codex")])]),"nextCursor":.null])
            }
            if case let .string(method)? = fields["method"], let share = target["share"] {
                if method == "team.chat.details" { return .object(["chat":.object(["id":share,"checkoutId":checkout,"title":.string("Quarterly totals"),"backend":.string("codex"),"historyTrimmed":.bool(false),"allowsAgentRuns":.bool(state == .askUncertain),"allowsComments":.bool(state == .comment || state == .commentUncertain)])]) }
                if method == "team.chat.events" { return .object(["shareId":share,"events":.array(chatEvents + (await TeamFixtureComments.shared.events())),"nextCursor":.null,"firstCursor":.null,"lastCursor":.null,"hasMore":.bool(false),"historyTrimmed":.bool(false),"asOfMs":.int(1792500000000)]) }
                if method == "team.chat.receipt" { return await TeamFixtureComments.shared.receipt(params) }
            }
            return .object(["checkoutId":checkout,"organizationId":organization,"repositoryId":repository,"state":.string("available")])
        case .chatOptions: return .object(["chats":.array([try json(TeamLocalChat(id:"chat_fixture",title:"Quarterly totals",backend:"codex",shared:false))]),"nextOffset":.null])
        case .chatPreview: return .object(["conversation":.string("chat_fixture"),"checkoutId":.string("checkout_"+String(repeating:"a",count:32)),"repository":try json(repository),"deviceName":.string("Example Mac"),"preview":.string(String(repeating:"ab",count:32)),"audience":.string("currentAndFutureRepositoryMembers"),"allowsAgentRuns":.bool(false),"history":try json(TeamChatHistory(title:"Quarterly totals",backend:"codex",historyTrimmed:false,events:chatEvents))])
        case .chatList: return .object(["publications":.array([]),"nextOffset":.null])
        case .chatPublish, .chatWithdraw: throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.")
        case .commentSend:
            guard state == .comment || state == .commentUncertain else { throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.") }
            return try await TeamFixtureComments.shared.send(params, uncertain: state == .commentUncertain)
        case .ask:
            guard state == .askUncertain else { throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.") }
            return try await TeamFixtureAsks.shared.call(params)
        case .checkoutPublish, .checkoutWithdraw, .lanesSet, .lanesCatchUp: throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.")
        case .lanesGet: return .object(["settings": .null, "supportsCheckoutUpdates": .bool(true)])
        case .directory:
            if await TeamFixtureComments.shared.accessRemoved { throw TeamRequestFailure(code: "forbidden", message: "Access to this fictional repository was removed.") }
            guard case let .object(fields) = params, case let .string(operation)? = fields["operation"] else { throw TeamRequestFailure(code: "fixture_request", message: "Choose a fixture action.") }
            switch operation {
            case "organizations.list": return .object(["organizations":.array(state == .empty ? [] : [try json(organization)]),"nextOffset":.null])
            case "organizations.get": return .object(["organization":try json(organization),"ownershipRequest":.null])
            case "members.list": return .object(["members":.array(try members.map { try json($0) }),"nextOffset":.null])
            case "repositories.list":
                var rows = [try json(repository)]
                if await TeamFixtureProjects.shared.hasNewProject {
                    rows.append(try json(TeamRepository(id: "repo_refresh_fixture", organizationId: organization.id, name: "New shared project", role: .viewer, revision: 1, createdAt: timestamp)))
                }
                return .object(["repositories": .array(rows), "nextOffset": .null])
            case "checkouts.list": return .object(["checkouts":.array([
                try json(TeamCheckout(id: "checkout_" + String(repeating:"a",count:32), organizationId: organization.id, repositoryId: repository.id, publisherId: "fixture-owner", machineId: "fixture-mac", hostKey: String(repeating:"ab",count:32), deviceName: "Example Mac", publisher: TeamPerson(id: "fixture-owner", name: "Example owner", handle: "example-owner", avatar: nil), revision: 1, createdAt: timestamp)),
                try json(TeamCheckout(id: "checkout_" + String(repeating:"b",count:32), organizationId: organization.id, repositoryId: repository.id, publisherId: member.id, machineId: "fixture-workstation", hostKey: String(repeating:"cd",count:32), deviceName: "Márta’s workstation", publisher: TeamPerson(id: member.id, name: member.name, handle: member.handle, avatar: nil), revision: 1, createdAt: timestamp))]),"nextOffset":.null])
            case "chats.list":
                let checkout = fields["checkout"] ?? .string("checkout_"+String(repeating:"a",count:32))
                return .object(["shares":.array([.object(["id":.string("share_"+String(repeating:"a",count:32)),"checkoutId":checkout,"revision":.int(1),"createdAt":.string(timestamp)])]),"nextOffset":.null])
            case "repositories.members": return .object(["members":.array(try members.map { try json(TeamRepositoryMember(id: $0.id, name: $0.name, handle: $0.handle, avatar: nil, role: $0.role == .owner ? .maintainer : nil, revision: 1, eligible: $0.eligible)) }),"nextOffset":.null])
            case "inbox.list": return .object(["invitations":.array(state == .invitation || state == .expiredInvitation ? [try json(invitation)] : []),"nextOffset":.null])
            case "invitations.list": return .object(["invitations":.array([]),"nextOffset":.null])
            case "inbox.get": return .object(["invitation":try json(invitation),"eligible":.bool(true),"available":.bool(state != .expiredInvitation),"unavailableReason":.null,"repositoryAccess":.array(state == .expiredInvitation ? [] : [try json(TeamInvitationRepositoryAccess(repositoryId: "repo_partner", name: "Partner website", role: .viewer))])])
            default: throw TeamRequestFailure(code: "fixture_read_only", message: "This fixture is read-only. No account changes were sent.")
            }
        }
    }
}
