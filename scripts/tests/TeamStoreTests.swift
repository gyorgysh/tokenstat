// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamStore.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
private func owner(_ name: String) -> TeamAccountOwner {
    TeamAccountOwner(scope: .account(origin: "https://accounts.example.test", handle: name)!, generation: 1, session: "fixture-\(name)")
}
private func organization(_ id: String, _ account: String = "alpha", eligible: Bool = true, ownerRecovery: Bool = false) -> JSONValue {
    .object(["id":.string(id), "slug":.string(id), "name":.string("Example \(id)"), "ownerId":.string("fixture-owner"),
        "role":.string(eligible || ownerRecovery ? "owner" : "member"), "revision":.int(1), "epoch":.int(1), "membershipRevision":.int(2),
        "state":.string(ownerRecovery ? "paused" : "active"), "eligible":.bool(eligible), "createdAt":.string("2026-01-01T00:00:00.000Z")])
}
private actor Fixture {
    var calls: [(String, String)] = []
    var delayed = Set<String>()
    var waiting: [String: CheckedContinuation<JSONValue, Error>] = [:]
    var enabled = true
    var authorized = true
    var eligible = true
    var ownerRecovery = false
    var paginate = false
    var publishing = false
    var failures: [String: String] = [:]
    func api() -> TeamAPI { TeamAPI { method, params, owner in try await self.send(method, params, owner) } }
    func delay(_ key: String) { delayed.insert(key) }
    func hasWaiter(_ key: String) -> Bool { waiting[key] != nil }
    func release(_ key: String, value: JSONValue) { waiting.removeValue(forKey: key)?.resume(returning: value) }
    func reject(_ key: String) { waiting.removeValue(forKey: key)?.resume(throwing: TeamRequestFailure(code: "fixture_error", message: "Previous organization failure")) }
    func revoke() { authorized = false }
    func downgrade() { eligible = false }
    func recoverOwner() { eligible = false; ownerRecovery = true }
    func usePages() { paginate = true }
    func usePublishing() { publishing = true }
    func fail(_ operation: String, code: String) { failures[operation] = code }
    func send(_ method: TeamHostMethod, _ params: JSONValue, _ owner: TeamAccountOwner) async throws -> JSONValue {
        guard case let .object(fields) = params else { fatalError("Fixture parameters must be an object") }
        let operation = method == .capabilities ? "capabilities" : fields["operation"].flatString ?? method.rawValue
        let org = fields["organization"].flatString ?? ""
        let key = "\(owner.scope.identity)|\(operation)|\(org)"
        calls.append((operation, org))
        if let code = failures[operation] { throw TeamRequestFailure(code: code, message: "Fixture authorization changed") }
        if delayed.contains(key) { return try await withCheckedThrowingContinuation { waiting[key] = $0 } }
        switch operation {
        case "capabilities": return .object(["enabled":.bool(enabled), "actorId":.string("fixture-owner"), "ready":.bool(authorized), "version":.int(1), "authorizationRequired":.bool(!authorized), "canPublishCheckouts":.bool(publishing)])
        case "organizations.list":
            let page = fields["page"]
            if case let .object(values) = page, values["offset"] == .int(100) {
                return .object(["organizations":.array([organization("org_a", eligible: eligible, ownerRecovery: ownerRecovery), organization("org_c", eligible: eligible, ownerRecovery: ownerRecovery)]), "nextOffset":.null])
            }
            return .object(["organizations":.array(owner.scope.identity == "alpha" ? [organization("org_a", eligible: eligible, ownerRecovery: ownerRecovery), organization("org_b", eligible: eligible, ownerRecovery: ownerRecovery)] : [organization("org_z", "beta")]), "nextOffset":paginate ? .int(100) : .null])
        case "inbox.list", "invitations.list": return .object(["invitations":.array([]), "nextOffset":.null])
        case "organizations.get": return .object(["organization":organization(org, eligible: eligible, ownerRecovery: ownerRecovery), "ownershipRequest":.null])
        case "members.list": return members(org)
        case "repositories.list":
            if publishing, org == "org_c" {
                if case let .object(page) = fields["page"], page["offset"] == .int(100) {
                    return .object(["repositories": .array([.object(["id": .string("project_late"), "organizationId": .string(org),
                        "name": .string("Shared example"), "role": .string("maintainer"), "revision": .int(1), "createdAt": .string("2026-01-01T00:00:00Z")])]), "nextOffset": .null])
                }
                return .object(["repositories": .array([]), "nextOffset": .int(100)])
            }
            return .object(["repositories":.array([]), "nextOffset":.null])
        case "teams.checkout.list":
            let later: Bool
            if case let .object(page) = fields["page"] { later = page["offset"] == .int(100) } else { later = false }
            let row: JSONValue = .object(["id": .string(later ? "checkout_late" : "checkout_first"), "organizationId": .string("org_c"),
                "repositoryId": .string("project_late"), "workspaceId": .string(later ? "folder_late" : "folder_first"),
                "phase": .string("active"), "revision": .int(1), "accountCleanupPending": .bool(false)])
            return .object(["publications": .array([row]), "nextOffset": later ? .null : .int(100)])
        case "members.remove": return .object(["removed":.bool(true)])
        case "teams.ask": return params
        default: fatalError("Unexpected fixture operation: \(operation)")
        }
    }
    func members(_ org: String) -> JSONValue {
        .object(["members":.array([.object(["id":.string("member_\(org)"), "name":.string("Example member"), "handle":.null, "avatar":.null,
            "role":.string("member"), "revision":.int(1), "eligible":.bool(true), "joinedAt":.string("2026-01-01T00:00:00.000Z")])]), "nextOffset":.null])
    }
}
private extension Optional where Wrapped == JSONValue {
    var flatString: String? { if case let .string(value) = self { value } else { nil } }
}
private func waitFor(_ key: String, fixture: Fixture) async {
    let deadline = Date().addingTimeInterval(3)
    while !(await fixture.hasWaiter(key)) {
        precondition(Date() < deadline, "Fixture did not reach its expected suspended request")
        await Task.yield()
    }
}
@main struct TeamStoreTests {
    @MainActor static func main() async throws {
        try await lateAccountResponse()
        try await lateOrganizationResponse()
        try await mutationOwnership()
        try await lateError()
        await revokedConsent()
        await lowerTierRecovery()
        await ownerInvitationRecovery()
        await paginatedDirectory()
        try await selectionOutsideFirstPage()
        try await authorizationRevokedDuringWrite()
        try await authorityLossRetiresPendingReadsAndOldForms()
        try await offlineDraftOwnership()
        try await savedAskWithoutDirectory()
        await sharedProjectDiscovery()
        await lateSharedProjectAccountResponse()
        await staleSharedProjectNavigation()
        await projectCatalogRefresh()
        avatars()
        try messageAuthors()
        print("Team directory ownership, recovery, pagination and avatar tests passed")
    }
    @MainActor static func projectCatalogRefresh() async {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        let account = owner("alpha")
        await store.bind(to: account)
        let first = store.catalogRefresh
        await store.bind(to: account, refresh: true)
        check(store.catalogRefresh > first, "A successful refresh did not invalidate visible project cards")
        let refreshed = store.catalogRefresh
        await fixture.fail("organizations.list", code: "teams_unreachable")
        await store.bind(to: account, refresh: true)
        check(store.catalogRefresh == refreshed && !store.organizations.isEmpty, "A failed refresh discarded the cached project directory or pretended it was fresh")
    }
    @MainActor static func sharedProjectDiscovery() async {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await fixture.usePublishing(); await fixture.usePages()
        await store.bind(to: owner("alpha"))
        check(store.localProjects(for: "folder_late").first?.id == "checkout_late", "The later publication page lost the folder's shared badge")
        check(store.localProjects(for: "unrelated").isEmpty, "A different folder inherited sharing")
        store.showProjects()
        check(store.browsingProjects && store.selectedOrganization == nil, "Shared projects required switching account scope")
        let opened = await store.openLocalProject(store.localProjects(for: "folder_late")[0])
        check(opened && store.selectedOrganizationId == "org_c" && store.selectedRepositoryId == "project_late", "The folder opened the wrong project beyond the first team/project pages")
        check(store.preferredCheckoutId == "checkout_late" && store.focusedProject?.id == "project_late" && !store.browsingProjects, "The folder lost its exact computer or focused project")
        await fixture.fail("teams.checkout.list", code: "teams_unreachable")
        await store.refreshLocalProjects()
        check(!store.localProjects(for: "folder_late").isEmpty && store.localProjectsError != nil, "An outage falsely marked the shared folder private")
        await store.bind(to: owner("beta"))
        check(store.localProjects.isEmpty && store.focusedProject == nil && store.preferredCheckoutId == nil, "An account switch retained another person's project state")
    }
    @MainActor static func lateSharedProjectAccountResponse() async {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await fixture.usePublishing()
        let key = "alpha|teams.checkout.list|"
        await fixture.delay(key)
        let pending = Task { await store.bind(to: owner("alpha")) }
        await waitFor(key, fixture: fixture)
        await store.bind(to: nil)
        await fixture.release(key, value: .object(["publications": .array([]), "nextOffset": .null]))
        await pending.value
        check(store.phase == .signedOut && store.localProjects.isEmpty, "A late sharing response revived the signed-out account")
    }
    @MainActor static func staleSharedProjectNavigation() async {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await fixture.usePublishing(); await fixture.usePages()
        await store.bind(to: owner("alpha"))
        let key = "alpha|repositories.list|org_c"
        await fixture.delay(key)
        let publication = store.localProjects(for: "folder_late")[0]
        let pending = Task { await store.openLocalProject(publication) }
        await waitFor(key, fixture: fixture)
        store.select(store.organizations.first { $0.id == "org_a" })
        await fixture.release(key, value: .object(["repositories": .array([]), "nextOffset": .null]))
        let opened = await pending.value
        check(!opened && store.selectedOrganizationId == "org_a" && store.focusedProject == nil, "A slow folder lookup replaced the user's later team selection")
    }
    @MainActor static func savedAskWithoutDirectory() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        let account = TeamAccountOwner(scope: owner("alpha").scope, generation: 1, session: "fixture-alpha", personId: "fixture-owner")
        await fixture.fail("capabilities", code: "teams_unreachable")
        await store.bind(to: account)
        check(store.phase == .failed && store.localDraftPersonId == "fixture-owner", "Outage hid local Ask recovery")
        let target = JSONValue.object(["organization":.string("org_removed"), "repository":.string("repo_removed"), "checkout":.string("checkout_original"), "share":.string("share_original")])
        let input: [String: JSONValue] = ["fence":.object(["runId":.string("run_original"), "incarnation":.string("original")])]
        let response = try await store.recoverAsk(origin: account.scope.origin, person: "fixture-owner", target: target, owner: account, method: "team.chat.ask.status", input: input)
        check(response == .object(["target":target, "method":.string("team.chat.ask.status"), "params":.object(input)]), "Global recovery changed original resource or fence")
        let before = await fixture.calls.count
        for (origin, person, method) in [(account.scope.origin, "other-person", "team.chat.ask"), ("https://other.example.test", "fixture-owner", "team.chat.ask"), (account.scope.origin, "fixture-owner", "team.chat.ask.review")] {
            do {
                _ = try await store.recoverAsk(origin: origin, person: person, target: target, owner: account, method: method, input: input)
                preconditionFailure("Recovery crossed accounts or requested a new review")
            } catch is CancellationError { }
        }
        let after = await fixture.calls.count
        check(before == after, "Invalid recovery made a host request")
        await fixture.delay("alpha|teams.ask|")
        let pending = Task { try await store.recoverAsk(origin: account.scope.origin, person: "fixture-owner", target: target, owner: account, method: "team.chat.ask.status", input: input) }
        await waitFor("alpha|teams.ask|", fixture: fixture)
        await store.bind(to: owner("beta"))
        await fixture.release("alpha|teams.ask|", value: .object(["running":.bool(false)]))
        do { _ = try await pending.value; preconditionFailure("An old login's recovered result reached the new account") } catch is CancellationError { }
    }
    @MainActor static func offlineDraftOwnership() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await fixture.fail("capabilities", code: "teams_unreachable")
        let scope = owner("alpha")
        let known = TeamAccountOwner(scope: scope.scope, generation: scope.generation, session: scope.session, personId: "fixture-owner")
        await store.bind(to: known)
        check(store.phase == .failed && store.localDraftPersonId == "fixture-owner", "A Team outage hid writing owned by the already verified account")
        check(store.capabilities == nil && store.organizations.isEmpty, "Local recovery identity granted Team access")
        await store.bind(to: owner("beta"))
        check(store.localDraftPersonId == nil, "Another account inherited the previous person's recovery identity")
        await store.bind(to: nil)
        check(store.owner == nil && store.localDraftPersonId == nil, "Signed-out recovery exposed an account's writing")
        let mismatch = TeamStore(api: await Fixture().api())
        let wrong = TeamAccountOwner(scope: known.scope, generation: known.generation, session: known.session, personId: "different_person")
        await mismatch.bind(to: wrong)
        check(mismatch.phase == .failed && mismatch.localDraftPersonId == nil && mismatch.capabilities == nil, "A different server actor overrode the captured profile identity")
        check(mismatch.organizations.isEmpty, "Mismatched identity reached the Team directory")
    }
    static func messageAuthors() throws {
        let named = JSONValue.object(["kind":.string("user"),"seq":.int(42),"mode":.string("comment"),"author":.object(["kind":.string("person"),"id":.string("fixture-member"),"name":.string("Márta Nagy"),"handle":.null,"avatar":.null])])
        let legacy = JSONValue.object(["kind":.string("user"),"seq":.int(1),"author":.object(["kind":.string("localBeforeTeams")])])
        let authors = try TeamMessageAttribution.people([legacy, named])
        check(authors.count == 1 && authors["user-s42"]?.name == "Márta Nagy", "Named author was mapped to the wrong chat row")
        if case var .object(ask) = named {
            ask["mode"] = .string("ask"); ask["seq"] = .int(43)
            let events = [named, JSONValue.object(ask)]
            let askAuthors = try TeamMessageAttribution.people(events)
            check(askAuthors.count == 2, "An attributed Ask hid the shared transcript")
            check(TeamMessageAttribution.asks(events) == ["user-s43"], "An Ask received the Comment label")
            ask["mode"] = .string("forged")
            do { _ = try TeamMessageAttribution.people([.object(ask)]); preconditionFailure("Unknown message mode was accepted") } catch {}
        }
        let initiator: JSONValue = .object(["kind":.string("person"),"id":.string("fixture-member"),"name":.string("Fictional member")])
        var proof: [String: JSONValue] = ["kind":.string("agent"),"backend":.string("claude"),"runId":.string("run_" + String(repeating: "a", count: 32)),"initiatedBy":initiator]
        var agent: [String: JSONValue] = ["kind":.string("agent"),"backend":.string("claude"),"seq":.int(44),"mode":.string("agent"),"author":.object(proof)]
        let namedAgent = try TeamMessageAttribution.agents([.object(agent)])
        check(namedAgent["text-s44"]?.name == "Fictional member", "Verified agent initiator was lost")
        proof["initiatedBy"] = .object(["kind":.string("formerMember"),"name":.string("Must not appear")]); agent["author"] = .object(proof)
        let formerAgent = try TeamMessageAttribution.agents([.object(agent)])
        check(formerAgent["text-s44"]?.name == nil && formerAgent["text-s44"]?.backend == "claude", "Former agent initiator retained a name")
        agent["backend"] = .string("codex")
        do { _ = try TeamMessageAttribution.agents([.object(agent)]); preconditionFailure("Agent backend mismatch was accepted") } catch {}
        do { _ = try TeamMessageAttribution.people([named, named]); preconditionFailure("Duplicate author sequence was accepted") } catch {}
        let unverified = JSONValue.object(["kind":.string("user"),"seq":.int(42),"author":.object(["kind":.string("person"),"id":.string("forged"),"name":.string("Unverified")])])
        do { _ = try TeamMessageAttribution.people([unverified]); preconditionFailure("Unverified user fields became a named Comment") } catch {}
    }
    @MainActor static func lateError() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await store.bind(to: owner("alpha")); store.select(store.organizations[0])
        let context = store.mutationContext!
        await fixture.delay("alpha|members.remove|org_a")
        let old = Task { () -> Bool in
            do { let _: JSONValue = try await store.perform("members.remove", fields: ["organization":.string("org_a")], context: context); return false }
            catch is CancellationError { return true } catch { return false }
        }
        await waitFor("alpha|members.remove|org_a", fixture: fixture)
        store.select(store.organizations[1]); await fixture.reject("alpha|members.remove|org_a")
        let retired = await old.value
        check(retired && store.error == nil, "A previous organization's failure appeared in the new view")
    }
    @MainActor static func lateAccountResponse() async throws {
        let fixture = Fixture(), api = await fixture.api(), first = owner("alpha"), second = owner("beta")
        await fixture.delay("alpha|organizations.list|")
        let store = TeamStore(api: api)
        let old = Task { await store.bind(to: first) }
        await waitFor("alpha|organizations.list|", fixture: fixture)
        await store.bind(to: second)
        await fixture.release("alpha|organizations.list|", value: .object(["organizations":.array([organization("old_org")]),"nextOffset":.null]))
        await old.value
        check(store.owner == second, "Late response changed the account")
        check(store.organizations.map(\.id) == ["org_z"], "Late response published another account's directory")
        check(store.phase == .ready && !store.isRefreshing, "Old cleanup changed the new account's loading state")
    }
    @MainActor static func lateOrganizationResponse() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api()), account = owner("alpha")
        await store.bind(to: account)
        store.select(store.organizations[0])
        await fixture.delay("alpha|members.list|org_a")
        let old = Task { await store.refreshSelected() }
        await waitFor("alpha|members.list|org_a", fixture: fixture)
        store.select(store.organizations[1]); await store.refreshSelected()
        await fixture.release("alpha|members.list|org_a", value: fixture.members("org_a"))
        await old.value
        check(store.directory?.details.organization.id == "org_b", "Old organization replaced the selection")
        check(store.directory?.members.members.first?.id == "member_org_b", "A roster appeared under another organization")
        check(store.owner == account && store.owner?.generation == 1, "Directory switching changed login ownership")
        check(!store.isLoadingDirectory, "Old cleanup changed the new selection's loading state")
    }
    @MainActor static func mutationOwnership() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await store.bind(to: owner("alpha")); store.select(store.organizations[0])
        let first = store.mutationContext!
        store.select(store.organizations[1])
        let before = await fixture.calls.count
        do { let _: JSONValue = try await store.perform("members.remove", fields: [:], context: first); preconditionFailure("Stale form was submitted") } catch is CancellationError {}
        let after = await fixture.calls.count
        check(after == before, "Stale form reached the account API")
        store.select(store.organizations[0]); await fixture.delay("alpha|members.remove|org_a")
        do { let _: JSONValue = try await store.perform("members.remove", fields: [:], context: first); preconditionFailure("Returning to an organization revived an old form") } catch is CancellationError {}
        let returned = store.mutationContext!
        let old = Task { () -> Bool in do { let _: JSONValue = try await store.perform("members.remove", fields: ["organization":.string("org_a")], context: returned); return false } catch is CancellationError { return true } catch { return false } }
        await waitFor("alpha|members.remove|org_a", fixture: fixture)
        store.select(store.organizations[1]); let second = store.mutationContext!
        await fixture.delay("alpha|members.remove|org_b")
        let current = Task { let _: JSONValue = try await store.perform("members.remove", fields: ["organization":.string("org_b")], context: second) }
        await waitFor("alpha|members.remove|org_b", fixture: fixture)
        await fixture.release("alpha|members.remove|org_a", value: .object(["removed":.bool(true)]))
        let discarded = await old.value
        check(discarded, "Old mutation response was accepted under another organization")
        check(store.isMutating, "Old response cleared the current form's saving state")
        await fixture.release("alpha|members.remove|org_b", value: .object(["removed":.bool(true)]))
        try await current.value
        check(!store.isMutating, "Current mutation did not finish")
    }
    @MainActor static func revokedConsent() async {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api()), account = owner("alpha")
        await store.bind(to: account); store.select(store.organizations[0]); await store.refreshSelected()
        check(store.directory != nil, "Fixture did not load")
        await fixture.revoke(); await store.bind(to: account, refresh: true)
        check(store.phase == .authorization && store.organizations.isEmpty && store.directory == nil, "Revoked consent left directory data visible")
        check(store.selectedOrganizationId == nil && store.owner == account, "Consent recovery changed the signed-in account")
    }
    @MainActor static func lowerTierRecovery() async {
        let fixture = Fixture(); await fixture.downgrade()
        let store = TeamStore(api: await fixture.api()); await store.bind(to: owner("alpha")); store.select(store.organizations[0]); await store.refreshSelected()
        check(store.directory?.details.organization.membershipRevision == 2, "A downgraded member cannot revision-check leaving")
        check(store.directory?.members.members.isEmpty == true, "Ineligible member loaded the roster")
        let operations = await fixture.calls.map(\.0)
        check(!operations.contains("members.list") && !operations.contains("repositories.list"), "Ineligible membership queried project content")
    }
    @MainActor static func paginatedDirectory() async {
        let fixture = Fixture(); await fixture.usePages()
        let store = TeamStore(api: await fixture.api()); await store.bind(to: owner("alpha")); await store.loadMoreOrganizations()
        check(store.organizations.map(\.id) == ["org_a", "org_b", "org_c"], "Directory pagination duplicated or lost organizations")
        check(store.organizationsNextOffset == nil, "Directory kept a completed cursor")
    }
    @MainActor static func ownerInvitationRecovery() async {
        let fixture = Fixture(); await fixture.recoverOwner()
        let store = TeamStore(api: await fixture.api()); await store.bind(to: owner("alpha"))
        store.select(store.organizations[0]); await store.refreshSelected()
        let operations = await fixture.calls.map(\.0)
        check(operations.contains("members.list") && operations.contains("invitations.list"), "A downgraded owner lost recovery access to pending invitations")
        check(!operations.contains("repositories.list"), "A paused organization queried repository content")
        check(store.directory != nil && store.error == nil, "Owner recovery could not load its directory")
    }
    @MainActor static func selectionOutsideFirstPage() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api())
        await store.bind(to: owner("alpha"))
        let newOrganization = try JSONDecoder().decode(TeamOrganization.self, from: JSONEncoder().encode(organization("org_new")))
        store.select(newOrganization)
        check(store.selectedOrganization?.id == "org_new", "A created or accepted organization outside the first page disappeared")
        await store.reloadAfterChange()
        check(store.selectedOrganization?.id == "org_new" && store.directory != nil, "Refreshing the first page discarded the selected organization")
    }
    @MainActor static func authorizationRevokedDuringWrite() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api()), account = owner("alpha")
        await store.bind(to: account); store.select(store.organizations[0]); await store.refreshSelected()
        let context = store.mutationContext!
        await fixture.fail("members.remove", code: "teams_authorization_required")
        do { let _: JSONValue = try await store.perform("members.remove", fields: [:], context: context); preconditionFailure("A revoked device wrote to Teams") }
        catch let error as TeamRequestFailure { check(error.code == "teams_authorization_required", "Wrong permission failure") }
        check(store.phase == .authorization && store.directory == nil && store.organizations.isEmpty, "A failed authorization left stale team data visible")
        check(store.owner == account && !store.isMutating, "Permission recovery changed login ownership or left a busy form")
        check(store.localDraftPersonId == "fixture-owner", "Revoked device consent hid the person's own local drafts")
        await store.bind(to: nil)
        check(store.localDraftPersonId == nil, "Signing out retained another person's draft owner")
    }
    @MainActor static func authorityLossRetiresPendingReadsAndOldForms() async throws {
        let fixture = Fixture(), store = TeamStore(api: await fixture.api()), account = owner("alpha")
        await store.bind(to: account); store.select(store.organizations[0]); await store.refreshSelected()
        let context = store.mutationContext!
        // A fresh directory response must not restore cache after a concurrent
        // scoped request has proved that membership was removed.
        await fixture.delay("alpha|organizations.list|")
        let pending = Task { await store.bind(to: account, refresh: true) }
        await waitFor("alpha|organizations.list|", fixture: fixture)
        await fixture.fail("teams.checkout.options", code: "forbidden")
        do { let _: JSONValue = try await store.read(.checkoutOptions, fields: [:], context: context); preconditionFailure("Removed membership read local sharing options") }
        catch let error as TeamRequestFailure { check(error.code == "forbidden", "Wrong authority failure") }
        check(store.directory == nil && store.organizations.isEmpty && store.phase == .failed, "Authority loss left cached organization data")
        check(store.localDraftPersonId == "fixture-owner", "Removed membership hid local draft recovery")
        await fixture.release("alpha|organizations.list|", value: .object(["organizations":.array([organization("org_a")]),"nextOffset":.null]))
        await pending.value
        check(store.directory == nil && store.organizations.isEmpty && !store.isRefreshing, "A late refresh restored revoked cache")
        let oldCapabilities = try JSONDecoder().decode(TeamCapabilities.self, from: JSONEncoder().encode(JSONValue.object(["enabled":.bool(true),"ready":.bool(true),"actorId":.string("fixture-owner"),"version":.int(1),"authorizationRequired":.bool(false)])))
        check(oldCapabilities.ready && !oldCapabilities.canPublishCheckouts, "An older account server enabled unsupported checkout publication")
    }
    static func avatars() {
        let account = owner("alpha")
        check(teamAvatarURL("/avatar/fixture.webp", owner: account)?.host == "accounts.example.test", "First-party avatar was refused")
        for path in ["https://another.example.test/image", "//another.example.test/avatar", "/avatar/../private", "/avatar/a%2fprivate", "/avatar/x.webp?private", "/avatar/x/y"] {
            check(teamAvatarURL(path, owner: account) == nil, "Unsafe avatar was accepted")
        }
        let bad = TeamAccountOwner(scope: .account(origin: "http://another.example.test", handle: "alpha")!, generation: 1, session: "fixture")
        check(teamAvatarURL("/avatar/fixture.webp", owner: bad) == nil, "Avatar exposed identity over cleartext remote HTTP")
    }
}
