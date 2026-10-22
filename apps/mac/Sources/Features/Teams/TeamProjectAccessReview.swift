// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Only the people reviewed for this new project may receive a grant. A
/// retry can accept an identical grant, but cannot restore a revoked one.
enum TeamProjectAccessReview {
    static func grants(reviewed: Set<String>, role: TeamRepositoryRole, members: [TeamRepositoryMember]) throws -> [TeamRepositoryMember] {
        guard role == .viewer || role == .contributor,
            reviewed.isSubset(of: Set(members.map(\.id))) else { throw changed() }
        return try members.filter { member in
            guard reviewed.contains(member.id) else { return false }
            guard member.eligible else { throw changed() }
            if member.role == role || member.role == .maintainer { return false }
            guard member.role == nil, member.revision == 0 else { throw changed() }
            return true
        }
    }
    private static func changed() -> TeamRequestFailure {
        TeamRequestFailure(code: "access_changed", message: L10n.text("common.teams.project_access_changed"))
    }
}
