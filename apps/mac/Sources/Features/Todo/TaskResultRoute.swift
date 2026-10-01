// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// Review surfaces that belong to a task result's folder, not to a chat.
enum TaskResultWorkspaceSurface: String, CaseIterable, Identifiable, Hashable, Sendable {
    case changes
    case history

    var id: String { rawValue }

    /// Same words the folder itself uses for these sections.
    var title: String {
        switch self {
        case .changes: return L10n.text("apple.taskresultroute.changes.bbd4b6a8")
        case .history: return L10n.text("common.history")
        }
    }

    /// Same glyphs the folder itself uses for these sections.
    var symbol: String {
        switch self {
        case .changes: return "plusminus"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Where View run should land so the exact run stays selected.
enum TaskResultRunPlacement: Equatable, Sendable {
    case folderAutomations(workspaceID: String)
    case allAutomations
}

enum TaskResultReviewAvailability: Equatable, Sendable {
    case ready
    case uncategorized
    case folderMissing

    func message(hostName: String) -> String? {
        switch self {
        case .ready:
            return nil
        case .uncategorized:
            return L10n.text("apple.taskresultroute.this_task_has_no_folder_assign_one_to_revi.ec78820b")
        case .folderMissing:
            let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty {
                return L10n.text("apple.taskresultroute.this_folder_is_no_longer_available_on_the.be3071ed")
            }
            return L10n.text("apple.taskresultroute.this_folder_is_no_longer_available_on_0.70d7366a", "\(host)")
        }
    }
}

/// One task result: the exact run, and whether its folder can be reviewed.
struct TaskResultRoute: Equatable, Sendable {
    var runID: String
    var workspaceID: String
    var folderName: String
    var hostName: String
    var folderMissing: Bool
    var changeCount: Int? = nil

    init(
        runID: String,
        workspaceID: String,
        folderName: String,
        hostName: String,
        folderMissing: Bool,
        changeCount: Int? = nil
    ) {
        self.runID = runID
        self.workspaceID = workspaceID
        self.folderName = folderName
        self.hostName = hostName
        self.folderMissing = folderMissing
        self.changeCount = changeCount
    }

    init(runID: String, workspaceID: String, folders: [WorkspaceFolder], hostName: String) {
        let folder = folders.first { $0.id == workspaceID }
        self.init(
            runID: runID,
            workspaceID: workspaceID,
            folderName: folder?.name ?? "",
            hostName: hostName,
            folderMissing: !workspaceID.isEmpty && (folder == nil || folder?.exists == false),
            changeCount: folder?.changeCount
        )
    }

    var runPlacement: TaskResultRunPlacement {
        if !workspaceID.isEmpty && !folderMissing {
            return .folderAutomations(workspaceID: workspaceID)
        }
        return .allAutomations
    }

    var reviewAvailability: TaskResultReviewAvailability {
        if workspaceID.isEmpty { return .uncategorized }
        if folderMissing { return .folderMissing }
        return .ready
    }

    var canReviewWorkspace: Bool { reviewAvailability == .ready }

    var folderLabel: String {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if workspaceID.isEmpty { return L10n.text("apple.taskresultroute.uncategorized.8d40d123") }
        return L10n.text("apple.taskresultroute.folder.74ccd433")
    }

    func preservesRun(_ selectedRunID: String?) -> Bool {
        !runID.isEmpty && selectedRunID == runID
    }

    func caption(for surface: TaskResultWorkspaceSurface) -> String {
        switch (surface, reviewAvailability) {
        case (.changes, .ready):
            if let changeCount {
                if changeCount == 0 { return L10n.text("apple.taskresultroute.working_tree_matches_the_last_commit.419b69e6") }
                return changeCount == 1 ? L10n.text("apple.taskresultroute.1_file_to_review.0d600164") : L10n.text("apple.taskresultroute.0_files_to_review.b2f93852", "\(changeCount)")
            }
            return L10n.text("apple.taskresultroute.uncommitted_files_in_this_folder.9b817339")
        case (.history, .ready):
            return L10n.text("apple.taskresultroute.previous_commits_in_this_folder.cf1fcffb")
        default:
            return reviewAvailability.message(hostName: hostName) ?? surface.title
        }
    }
}
