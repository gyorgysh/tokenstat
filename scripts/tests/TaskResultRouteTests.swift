// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TaskResultRoute.swift.
import Foundation

struct WorkspaceFolder: Equatable {
    var id: String
    var name: String
    var exists: Bool
    var changeCount: Int
}

@main struct TaskResultRouteTests {
    static func main() {
        let website = WorkspaceFolder(id: "website", name: "Website", exists: true, changeCount: 3)
        let gone = WorkspaceFolder(id: "old", name: "Retired", exists: false, changeCount: 0)

        let ready = TaskResultRoute(
            runID: "run-1", workspaceID: "website", folders: [website], hostName: "Studio"
        )
        assert(ready.canReviewWorkspace)
        assert(ready.preservesRun("run-1"))
        assert(!ready.preservesRun("run-2"))
        assert(!ready.preservesRun(nil))
        if case let .folderAutomations(id) = ready.runPlacement {
            assert(id == "website")
        } else {
            assertionFailure("A known folder must open that folder's automations")
        }
        assert(ready.caption(for: .changes) == "3 files to review")
        assert(ready.caption(for: .history) == "Previous commits in this folder")
        assert(ready.folderLabel == "Website")
        assert(TaskResultWorkspaceSurface.changes.title == "Changes")
        assert(TaskResultWorkspaceSurface.history.title == "History")

        var oneFile = ready
        oneFile.changeCount = 1
        assert(oneFile.caption(for: .changes) == "1 file to review")
        oneFile.changeCount = 0
        assert(oneFile.caption(for: .changes) == "Working tree matches the last commit")

        let uncategorized = TaskResultRoute(
            runID: "run-1", workspaceID: "", folders: [website], hostName: "Studio"
        )
        assert(uncategorized.reviewAvailability == .uncategorized)
        assert(!uncategorized.canReviewWorkspace)
        if case .allAutomations = uncategorized.runPlacement {} else {
            assertionFailure("An uncategorized task cannot pretend to have a folder board")
        }
        assert(uncategorized.caption(for: .changes).contains("no folder"))
        assert(uncategorized.folderLabel == "Uncategorized")

        let missing = TaskResultRoute(
            runID: "run-1", workspaceID: "missing", folders: [website], hostName: "Studio"
        )
        assert(missing.reviewAvailability == .folderMissing)
        assert(!missing.canReviewWorkspace)
        assert(missing.caption(for: .history).contains("Studio"))

        let retired = TaskResultRoute(
            runID: "run-1", workspaceID: "old", folders: [gone], hostName: "Studio"
        )
        assert(retired.reviewAvailability == .folderMissing)

        let unknownHost = TaskResultRoute(
            runID: "run-1", workspaceID: "missing", folderName: "", hostName: "", folderMissing: true
        )
        assert(unknownHost.caption(for: .changes).contains("connected computer"))

        let historical = TaskResultRoute(
            runID: "old-run", workspaceID: "website", folders: [website], hostName: "Studio"
        )
        assert(historical.preservesRun("old-run"))
        assert(!historical.preservesRun("run-1"), "A historical result must not become a different live run")

        print("Task result route: folder automations, exact run identity, uncategorized and missing folders passed")
    }
}
