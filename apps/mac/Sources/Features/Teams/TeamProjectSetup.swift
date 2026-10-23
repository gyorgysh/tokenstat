// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Host-owned progress; opening this review never resumes a write.
struct TeamProjectSetup: Decodable, Sendable, Identifiable {
    let id: String
    let organizationId: String
    let workspaceId: String
    let name: String
    let repositoryId: String?
    let memberIds: [String]
    let role: TeamRepositoryRole
    let phase: String
    let needsRepositoryChoice: Bool
    let sharesExistingChats: Bool
    let allowsAgentRuns: Bool
}
struct TeamProjectSetupResult: Decodable, Sendable {
    let setup: TeamProjectSetup?
    var repository: TeamRepository? = nil
    var publication: TeamLocalPublication? = nil
    var workspace: TeamLocalWorkspace? = nil
}
