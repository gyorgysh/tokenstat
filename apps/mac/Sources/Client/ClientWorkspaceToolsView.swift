// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

struct ClientWorkspaceToolsView: View {
    let peer: String
    let workspaceID: String
    let folderName: String
    let hostName: String
    var session: GitCommitSession?
    var autoCommit: AutoCommitSession?

    enum Surface: String, CaseIterable, Hashable {
        case files = "Files"
        case changes = "Changes"
        case history = "History"
        case sessions = "Sessions"
    }

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
                title: { $0 == .changes ? L10n.text("apple.rootview.git.b949c922") : L10n.enumLabel($0) },
                comfortable: false
            )
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .onAppear { surface = initial }
            switch surface {
            case .sessions:
                ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
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
