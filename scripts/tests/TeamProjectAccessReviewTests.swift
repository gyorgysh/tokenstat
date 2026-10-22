// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamProjectAccessReview.swift TeamStore.swift TeamModels.swift WorkReference.swift JSONValue.swift.
import Foundation

private func member(_ id: String, role: TeamRepositoryRole? = nil, revision: UInt64 = 0, eligible: Bool = true) -> TeamRepositoryMember {
    TeamRepositoryMember(id: id, name: "Example teammate", handle: nil, avatar: nil, role: role, revision: revision, eligible: eligible)
}
@main struct TeamProjectAccessReviewTests {
    static func main() throws {
        let reviewed: Set<String> = ["alpha", "beta"]
        let first = try TeamProjectAccessReview.grants(reviewed: reviewed, role: .contributor, members: [member("alpha"), member("beta"), member("later")])
        precondition(Set(first.map(\.id)) == reviewed, "A new, unreviewed teammate received access")
        let retry = try TeamProjectAccessReview.grants(reviewed: reviewed, role: .contributor, members: [member("alpha", role: .contributor, revision: 1), member("beta")])
        precondition(retry.map(\.id) == ["beta"], "Retry rewrote an already applied grant")
        let maintainer = try TeamProjectAccessReview.grants(reviewed: ["alpha"], role: .viewer, members: [member("alpha", role: .maintainer, revision: 3)])
        precondition(maintainer.isEmpty, "Setup downgraded an existing maintainer")
        for members in [[member("alpha")], [member("alpha"), member("beta", revision: 2)],
            [member("alpha"), member("beta", role: .viewer, revision: 1)], [member("alpha"), member("beta", eligible: false)]] {
            do {
                _ = try TeamProjectAccessReview.grants(reviewed: reviewed, role: .contributor, members: members)
                preconditionFailure("Setup restored revoked access, widened a changed role, or ignored changed membership")
            } catch let failure as TeamRequestFailure { precondition(failure.code == "access_changed") }
        }
        do {
            _ = try TeamProjectAccessReview.grants(reviewed: ["alpha"], role: .maintainer, members: [member("alpha")])
            preconditionFailure("The sharing review granted administrative project access")
        } catch let failure as TeamRequestFailure { precondition(failure.code == "access_changed") }
        print("Project sharing consent, retries, revocation and membership checks passed")
    }
}
