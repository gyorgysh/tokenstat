// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Files, Changes and History for the folder behind a chat or a session.
///
/// One surface in three presentations: pushed on a phone over the
/// conversation (which stays mounted underneath, so Back returns to the
/// same transcript position), a trailing pane on a wide iPad, or a sheet
/// over a terminal. Each tab names itself; Chat setup stays its own sheet:
/// agent and persona choices are not workspace tools.
struct ClientWorkspaceToolsView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    /// Fixture sessions. Production leaves both nil and the sections load
    /// through their own services, like everywhere else.
    var session: GitCommitSession?
    var autoCommit: AutoCommitSession?

    enum Surface: String, CaseIterable, Hashable {
        case files = "Files"
        case changes = "Changes"
        case history = "History"
    }

    /// Fixtures open on Changes to show a working tab. Production starts on Files.
    var initial: Surface = .files

    @State private var surface: Surface = .files

    private var folder: WorkspaceFolder {
        WorkspaceFolder(
            id: workspaceID,
            path: "",
            name: folderName,
            addedAtMs: 0,
            exists: true,
            git: nil,
            machineID: peer,
            machineLabel: hostName.isEmpty ? nil : hostName
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(
                options: Surface.allCases,
                selection: $surface,
                comfortable: false
            )
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .onAppear { surface = initial }
            switch surface {
            case .files:
                ClientFilesView(peer: peer, workspace: workspaceID, folderName: folderName)
            case .changes:
                ClientWorkspaceChangesView(
                    peer: peer,
                    workspaceID: workspaceID,
                    folder: folder,
                    hostName: hostName,
                    session: session,
                    autoCommit: autoCommit
                )
            case .history:
                ClientWorkspaceHistoryView(
                    peer: peer,
                    workspaceID: workspaceID,
                    folder: folder,
                    hostName: hostName
                )
            }
        }
        .background(Theme.background)
        .accessibilityElement(children: .contain)
    }
}
#endif
