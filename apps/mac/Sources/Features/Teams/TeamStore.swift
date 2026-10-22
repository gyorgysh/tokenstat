// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

struct TeamDirectorySnapshot: Sendable {
    var details: TeamOrganizationDetails
    var members: TeamMembers
    var repositories: TeamRepositories
    var invitations: TeamInvitations
}

@MainActor @Observable
final class TeamStore {
    enum Phase: Equatable { case signedOut, loading, unavailable, authorization, ready, failed }
    private(set) var owner: TeamAccountOwner?
    private(set) var phase: Phase = .signedOut
    private(set) var capabilities: TeamCapabilities?
    /// Last verified person for local draft recovery in this login lifetime.
    /// Losing organization access must not hide this person's own writing.
    private(set) var localDraftPersonId: String?
    private(set) var organizations: [TeamOrganization] = []
    private(set) var organizationsNextOffset: Int?
    private(set) var inbox: [TeamInvitation] = []
    private(set) var inboxNextOffset: Int?
    private(set) var selectedOrganizationId: String?
    private(set) var directory: TeamDirectorySnapshot?
    private(set) var isRefreshing = false
    private(set) var isLoadingDirectory = false
    private(set) var isMutating = false
    private(set) var error: String?
    var section: TeamSection = .overview
    var selectedRepositoryId: String?
    private(set) var browsingProjects = false
    private(set) var focusedProject: TeamRepository?
    private(set) var preferredCheckoutId: String?
    private(set) var localProjects: [TeamLocalPublication] = []
    private(set) var localProjectsError: String?
    private var projectsRevision: UInt64 = 0
    private var projectOpenRevision: UInt64 = 0

    private let api: TeamAPI
    private var loadRevision: UInt64 = 0
    private var directoryRevision: UInt64 = 0
    private var cachedDirectories: [String: TeamDirectorySnapshot] = [:]
    private var cacheOrder: [String] = []
    private var inFlightSelection: TeamSelectionKey?
    private var mutationId: UUID?
    private var selectionSummary: TeamOrganization?
    private var formLifetime: UInt64 = 0

    init(api: TeamAPI) { self.api = api }
    var selectionKey: TeamSelectionKey { .init(owner: owner, organizationId: selectedOrganizationId) }
    var selectedOrganization: TeamOrganization? {
        if let directory, directory.details.organization.id == selectedOrganizationId { return directory.details.organization }
        return organizations.first { $0.id == selectedOrganizationId } ?? selectionSummary
    }
    var mutationContext: TeamMutationContext? { owner.map { .init(owner: $0, organizationId: selectedOrganizationId, lifetime: formLifetime) } }

    func bind(to next: TeamAccountOwner?, refresh: Bool = false) async {
        let changed = owner != next
        guard changed || refresh else { return }
        loadRevision &+= 1
        let revision = loadRevision
        if changed {
            formLifetime &+= 1
            owner = next; capabilities = nil; localDraftPersonId = next?.personId; organizations = []; inbox = []
            organizationsNextOffset = nil; inboxNextOffset = nil
            selectedOrganizationId = nil; selectedRepositoryId = nil; selectionSummary = nil
            directory = nil; cachedDirectories = [:]; cacheOrder = []; inFlightSelection = nil
            directoryRevision &+= 1; mutationId = nil; isMutating = false; isLoadingDirectory = false
            section = .overview
            clearProjects()
        }
        error = nil
        guard let next else { phase = .signedOut; isRefreshing = false; return }
        isRefreshing = true
        if changed || phase != .ready { phase = .loading }
        defer { if isCurrent(next, revision) { isRefreshing = false } }
        do {
            let capabilities: TeamCapabilities = try await api.request(.capabilities, owner: next)
            guard isCurrent(next, revision) else { return }
            if let person = next.personId, let actor = capabilities.actorId, person != actor {
                localDraftPersonId = nil
                throw TeamRequestFailure(code: "account_changed", message: L10n.text("common.teams.account_changed"))
            }
            self.capabilities = capabilities
            localDraftPersonId = capabilities.actorId ?? next.personId
            guard capabilities.enabled else { clearAuthorization(); phase = .unavailable; return }
            guard capabilities.ready else { clearAuthorization(); phase = .authorization; return }
            let api = api
            async let organizations: TeamOrganizations = api.request(.directory, ["operation": .string("organizations.list"), "page": Self.page()], owner: next)
            async let invitations: TeamInvitations = api.request(.directory, ["operation": .string("inbox.list"), "page": Self.page()], owner: next)
            let (orgs, inbox) = try await (organizations, invitations)
            guard isCurrent(next, revision) else { return }
            self.organizations = orgs.organizations; organizationsNextOffset = orgs.nextOffset
            self.inbox = inbox.invitations; inboxNextOffset = inbox.nextOffset
            phase = .ready
            await refreshLocalProjects()
            guard isCurrent(next, revision) else { return }
            // A directory refresh is not proof that an unreturned later page
            // was revoked. Keep a selected organization until its own lookup.
            if let selectedOrganizationId, let returned = self.organizations.first(where: { $0.id == selectedOrganizationId }), !returned.isActive {
                cachedDirectories.removeValue(forKey: selectedOrganizationId); directory = nil
            }
        } catch is CancellationError {
            if isCurrent(next, revision), phase == .loading { phase = .failed }
        } catch {
            guard isCurrent(next, revision) else { return }
            self.error = error.localizedDescription
            if !retireAuthorization(for: error), phase != .ready { phase = .failed }
        }
    }

    func select(_ organization: TeamOrganization?) {
        projectOpenRevision &+= 1; browsingProjects = false
        selectionSummary = organization
        guard selectedOrganizationId != organization?.id else { return }
        formLifetime &+= 1
        directoryRevision &+= 1; inFlightSelection = nil; isLoadingDirectory = false
        mutationId = nil; isMutating = false
        selectedOrganizationId = organization?.id; selectedRepositoryId = nil
        focusedProject = nil; preferredCheckoutId = nil; browsingProjects = false
        directory = organization.flatMap { cachedDirectories[$0.id] }
        section = organization == nil ? .overview : .members
        error = nil
    }
    func show(_ section: TeamSection) { projectOpenRevision &+= 1; browsingProjects = false; self.section = section }
    func showProjects() { projectOpenRevision &+= 1; browsingProjects = true }
    func openProject(_ repository: TeamRepository, in organization: TeamOrganization, checkout: String? = nil) {
        guard phase == .ready, organization.isActive, repository.role != nil, repository.organizationId == organization.id else { return }
        select(organization)
        focusedProject = repository; selectedRepositoryId = repository.id
        preferredCheckoutId = checkout; browsingProjects = false; section = .chats
    }
    func localProjects(for workspace: String) -> [TeamLocalPublication] {
        localProjects.filter { $0.workspaceId == workspace && $0.phase == "active" }
    }
    /// This directory belongs to the signed-in person and physical host, not
    /// the selected team. Never infer sharing from a folder name or Git URL.
    func refreshLocalProjects() async {
        guard let owner, phase == .ready, capabilities?.canPublishCheckouts == true else { return }
        projectsRevision &+= 1
        let revision = projectsRevision
        var rows: [TeamLocalPublication] = [], offset = 0
        do {
            while true {
                let page: TeamLocalPublications = try await api.request(.checkoutList, ["page": Self.page(offset: offset)], owner: owner)
                guard self.owner == owner, phase == .ready, projectsRevision == revision else { return }
                rows += page.publications.filter { next in !rows.contains { $0.id == next.id } }
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.load_failed")) }
                offset = next
            }
            localProjects = rows; localProjectsError = nil
        } catch is CancellationError {} catch {
            guard self.owner == owner, projectsRevision == revision else { return }
            // A failed refresh is not proof that the folder became private.
            localProjectsError = error.localizedDescription
            _ = retireAuthorization(for: error)
        }
    }
    private func clearProjects() {
        projectOpenRevision &+= 1
        projectsRevision &+= 1; localProjects = []; localProjectsError = nil
        focusedProject = nil; preferredCheckoutId = nil; browsingProjects = false
    }
    func openLocalProject(_ publication: TeamLocalPublication) async -> Bool {
        guard let owner, phase == .ready else { return false }
        let revision = loadRevision
        projectOpenRevision &+= 1
        let request = projectOpenRevision
        do {
            var offset = 0
            var organization: TeamOrganization?
            repeat {
                let page: TeamOrganizations = try await api.request(.directory, ["operation": .string("organizations.list"), "page": Self.page(offset: offset)], owner: owner)
                guard isCurrent(owner, revision), phase == .ready, projectOpenRevision == request else { return false }
                organization = page.organizations.first { $0.id == publication.organizationId }
                if organization != nil { break }
                guard let next = page.nextOffset, next > offset else { return false }
                offset = next
            } while true
            guard let organization, organization.isActive else { return false }
            offset = 0
            repeat {
                let page: TeamRepositories = try await api.request(.directory, ["operation": .string("repositories.list"),
                    "organization": .string(organization.id), "page": Self.page(offset: offset)], owner: owner)
                guard isCurrent(owner, revision), phase == .ready, projectOpenRevision == request else { return false }
                if let repository = page.repositories.first(where: { $0.id == publication.repositoryId && $0.organizationId == organization.id && $0.role != nil }) {
                    openProject(repository, in: organization, checkout: publication.id)
                    return true
                }
                guard let next = page.nextOffset, next > offset else { return false }
                offset = next
            } while true
        } catch is CancellationError {} catch {
            if isCurrent(owner, revision), projectOpenRevision == request { self.error = error.localizedDescription; _ = retireAuthorization(for: error) }
        }
        return false
    }
    func clearError() { error = nil }

    func refreshSelected() async {
        let key = selectionKey
        guard let owner = key.owner, let org = key.organizationId, phase == .ready, inFlightSelection != key else { return }
        inFlightSelection = key; isLoadingDirectory = true
        directoryRevision &+= 1
        let revision = directoryRevision
        defer {
            if selectionKey == key && directoryRevision == revision { inFlightSelection = nil; isLoadingDirectory = false }
        }
        do {
            let details: TeamOrganizationDetails = try await directoryRequest("organizations.get", fields: ["organization": .string(org)], owner: owner)
            guard selectionKey == key, directoryRevision == revision else { return }
            let api = api, organization = details.organization
            async let members: TeamMembers = organization.eligible || organization.role == .owner
                ? api.request(.directory, ["operation": .string("members.list"), "organization": .string(org), "page": Self.page()], owner: owner)
                : TeamMembers(members: [], nextOffset: nil)
            async let repositories: TeamRepositories = organization.isActive
                ? api.request(.directory, ["operation": .string("repositories.list"), "organization": .string(org), "page": Self.page()], owner: owner)
                : TeamRepositories(repositories: [], nextOffset: nil)
            async let invitations: TeamInvitations = organization.role.canManage && (organization.eligible || organization.role == .owner)
                ? api.request(.directory, ["operation": .string("invitations.list"), "organization": .string(org), "page": Self.page()], owner: owner)
                : TeamInvitations(invitations: [], nextOffset: nil)
            let (roster, projects, pending) = try await (members, repositories, invitations)
            let snapshot = TeamDirectorySnapshot(details: details, members: roster, repositories: projects, invitations: pending)
            guard selectionKey == key, directoryRevision == revision else { return }
            directory = snapshot; cache(snapshot, for: org)
            if let index = organizations.firstIndex(where: { $0.id == org }) { organizations[index] = organization }
        } catch is CancellationError {
        } catch {
            guard selectionKey == key, directoryRevision == revision else { return }
            self.error = error.localizedDescription
            if retireAuthorization(for: error) { return }
            if let error = error as? TeamRequestFailure, error.code == "not_found" {
                cachedDirectories.removeValue(forKey: org); directory = nil
                organizations.removeAll { $0.id == org }; selectedOrganizationId = nil; selectedRepositoryId = nil; selectionSummary = nil
                section = .overview
            }
        }
    }

    func authorizationPreview() async throws -> TeamAuthorizationPreview {
        guard let owner else { throw CancellationError() }
        let result: Result<TeamAuthorizationPreview, Error>
        do { result = .success(try await api.request(.authorizationPreview, owner: owner)) }
        catch { result = .failure(error) }
        guard self.owner == owner else { throw CancellationError() }
        return try result.get()
    }
    func prepareAuthorization(expectedDeviceKey: String) async throws -> TeamAuthorization {
        guard let owner else { throw CancellationError() }
        let result: Result<TeamAuthorization, Error>
        do { result = .success(try await api.request(.prepareAuthorization, ["confirmMetadata": .bool(true), "expectedDeviceKey":.string(expectedDeviceKey)], owner: owner)) }
        catch { result = .failure(error) }
        guard self.owner == owner else { throw CancellationError() }
        return try result.get()
    }
    func perform<T: Decodable & Sendable>(_ operation: String, fields: [String: JSONValue], context: TeamMutationContext, as: T.Type = T.self) async throws -> T {
        var fields = fields; fields["operation"] = .string(operation)
        return try await perform(.directory, fields: fields, context: context, as: T.self)
    }
    func perform<T: Decodable & Sendable>(_ method: TeamHostMethod, fields: [String: JSONValue], context: TeamMutationContext, as: T.Type = T.self) async throws -> T {
        guard phase == .ready, !isMutating, mutationContext == context else { throw CancellationError() }
        let id = UUID(); mutationId = id; isMutating = true; error = nil
        defer { if mutationId == id { mutationId = nil; isMutating = false } }
        let result: Result<T, Error>
        do { result = .success(try await api.request(method, fields, owner: context.owner)) }
        catch { result = .failure(error) }
        guard phase == .ready, mutationContext == context else { throw CancellationError() }
        if case let .failure(error) = result { _ = retireAuthorization(for: error) }
        return try result.get()
    }
    func read<T: Decodable & Sendable>(_ operation: String, fields: [String: JSONValue], context: TeamMutationContext, as: T.Type = T.self) async throws -> T {
        var fields = fields; fields["operation"] = .string(operation)
        return try await read(.directory, fields: fields, context: context, as: T.self)
    }
    func read<T: Decodable & Sendable>(_ method: TeamHostMethod, fields: [String: JSONValue], context: TeamMutationContext, as: T.Type = T.self) async throws -> T {
        guard phase == .ready, mutationContext == context else { throw CancellationError() }
        let result: Result<T, Error>
        do { result = .success(try await api.request(method, fields, owner: context.owner)) }
        catch { result = .failure(error) }
        guard phase == .ready, mutationContext == context else { throw CancellationError() }
        if case let .failure(error) = result { _ = retireAuthorization(for: error) }
        return try result.get()
    }
    func reloadAfterChange() async {
        guard let owner else { return }
        await bind(to: owner, refresh: true)
        await refreshSelected()
    }
    func loadMoreOrganizations() async {
        guard let owner, let offset = organizationsNextOffset, !isRefreshing else { return }
        let revision = loadRevision; isRefreshing = true
        defer { if isCurrent(owner, revision) { isRefreshing = false } }
        do {
            let result: TeamOrganizations = try await directoryRequest("organizations.list", fields: ["page": Self.page(offset: offset)], owner: owner)
            guard isCurrent(owner, revision) else { return }
            organizations = Self.appendUnique(organizations, result.organizations); organizationsNextOffset = result.nextOffset
        } catch is CancellationError {} catch { if isCurrent(owner, revision) { self.error = error.localizedDescription; _ = retireAuthorization(for: error) } }
    }
    func loadMoreInbox() async {
        guard let owner, let offset = inboxNextOffset, !isRefreshing else { return }
        let revision = loadRevision; isRefreshing = true
        defer { if isCurrent(owner, revision) { isRefreshing = false } }
        do {
            let result: TeamInvitations = try await directoryRequest("inbox.list", fields: ["page": Self.page(offset: offset)], owner: owner)
            guard isCurrent(owner, revision) else { return }
            inbox = Self.appendUnique(inbox, result.invitations); inboxNextOffset = result.nextOffset
        } catch is CancellationError {} catch { if isCurrent(owner, revision) { self.error = error.localizedDescription; _ = retireAuthorization(for: error) } }
    }
    func loadMore(_ section: TeamSection) async {
        guard let context = mutationContext, let org = context.organizationId, let directory, !isLoadingDirectory else { return }
        let operation: String, offset: Int?
        switch section {
        case .members: operation = "members.list"; offset = directory.members.nextOffset
        case .invitations: operation = "invitations.list"; offset = directory.invitations.nextOffset
        case .repositories: operation = "repositories.list"; offset = directory.repositories.nextOffset
        default: return
        }
        guard let offset else { return }
        let key = selectionKey, revision = directoryRevision
        isLoadingDirectory = true
        defer { if selectionKey == key && directoryRevision == revision { isLoadingDirectory = false } }
        do {
            let fields: [String: JSONValue] = ["organization": .string(org), "page": Self.page(offset: offset)]
            var next = directory
            switch section {
            case .members:
                let result: TeamMembers = try await read(operation, fields: fields, context: context)
                next.members = TeamMembers(members: Self.appendUnique(next.members.members, result.members), nextOffset: result.nextOffset)
            case .invitations:
                let result: TeamInvitations = try await read(operation, fields: fields, context: context)
                next.invitations = TeamInvitations(invitations: Self.appendUnique(next.invitations.invitations, result.invitations), nextOffset: result.nextOffset)
            case .repositories:
                let result: TeamRepositories = try await read(operation, fields: fields, context: context)
                next.repositories = TeamRepositories(repositories: Self.appendUnique(next.repositories.repositories, result.repositories), nextOffset: result.nextOffset)
            default: return
            }
            guard selectionKey == key, directoryRevision == revision else { return }
            self.directory = next; cache(next, for: org)
        } catch is CancellationError {} catch { if selectionKey == key { self.error = error.localizedDescription } }
    }
    private func directoryRequest<T: Decodable & Sendable>(_ operation: String, fields: [String: JSONValue], owner: TeamAccountOwner) async throws -> T {
        var fields = fields; fields["operation"] = .string(operation)
        return try await api.request(.directory, fields, owner: owner)
    }
    private func isCurrent(_ owner: TeamAccountOwner, _ revision: UInt64) -> Bool { self.owner == owner && loadRevision == revision }
    @discardableResult private func retireAuthorization(for error: Error) -> Bool {
        guard let failure = error as? TeamRequestFailure else { return false }
        let retired: Bool
        switch failure.code {
        case "teams_authorization_required", "device_required":
            clearAuthorization(); capabilities = nil; phase = .authorization; retired = true
        case "auth", "unauthorized", "account_changed":
            clearAuthorization(); capabilities = nil; phase = .failed; retired = true
        case "forbidden", "not_found", "organization_paused", "patron_required":
            clearAuthorization(); phase = .failed; retired = true
        case "teams_unavailable":
            clearAuthorization(); capabilities = nil; phase = .unavailable; retired = true
        default: retired = false
        }
        if retired { self.error = failure.message }
        return retired
    }
    private func clearAuthorization() {
        clearProjects()
        loadRevision &+= 1; formLifetime &+= 1; isRefreshing = false
        organizations = []; inbox = []; organizationsNextOffset = nil; inboxNextOffset = nil
        cachedDirectories = [:]; cacheOrder = []; directory = nil; selectedOrganizationId = nil; selectedRepositoryId = nil; selectionSummary = nil
        mutationId = nil; isMutating = false; section = .overview
        directoryRevision &+= 1; inFlightSelection = nil; isLoadingDirectory = false
    }
    private func cache(_ snapshot: TeamDirectorySnapshot, for organization: String) {
        cachedDirectories[organization] = snapshot
        cacheOrder.removeAll { $0 == organization }; cacheOrder.append(organization)
        while cacheOrder.count > 8 { cachedDirectories.removeValue(forKey: cacheOrder.removeFirst()) }
    }
    static func page(offset: Int = 0) -> JSONValue { .object(["limit": .int(100), "offset": .int(Int64(offset))]) }
    private static func appendUnique<T: Identifiable>(_ first: [T], _ second: [T]) -> [T] where T.ID: Hashable {
        var ids = Set(first.map(\.id)); return first + second.filter { ids.insert($0.id).inserted }
    }
}

/// Kept separate from BridgeError so fixture transports can exercise the same
/// recovery states without loading the FFI or opening an account connection.
struct TeamRequestFailure: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
