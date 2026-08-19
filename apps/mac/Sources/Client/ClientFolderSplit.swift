// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Regular-width folder: sections stay on the leading side, like the Mac workspace.
///
/// Compact still pushes. This is only mounted when the size class is regular.
struct ClientFolderSplit: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    @State private var section: WorkspaceSection = .sessions
    @State private var live: WorkspaceFolder?
    @State private var counts = WorkspaceSectionCounts()
    @State private var errorMessage: String?
    @State private var showPort = false
    @State private var portText = "5173"
    @State private var forwardedPort: Int?
    @State private var browserURL: String?
    @State private var isOpeningPort = false

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    private var current: WorkspaceFolder {
        guard var merged = live else { return folder }
        merged.id = folder.id
        merged.machineID = folder.machineID
        merged.machineLabel = folder.machineLabel
        return merged
    }

    /// Below this, the detail side is too narrow to hold a second split.
    ///
    /// The sections column already spends 280 points. A workflow workspace
    /// inside what is left adds its own list, board and run columns, and on
    /// an iPad in portrait that list came out around 170 points wide with
    /// cards that will not go below 180: the card spilled over the divider.
    /// Narrow detail gets the stacked screen the phone uses instead, which is
    /// a list that pushes, and nothing overflows because nothing is nested.
    private static let splitInsideSplit: CGFloat = 900

    /// The sections column. Named once, because the detail width is what is
    /// left after it and two numbers that must agree will not.
    private static let sectionsColumn: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            split(detailWidth: geo.size.width - Self.sectionsColumn)
        }
        .background(Theme.background)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-\(workspaceID)") { await reload() }
        }
        .task { await reload() }
        .sheet(isPresented: $showPort) { portSheet }
        .fullScreenCover(item: Binding(
            get: { browserURL.map { BrowserURL(url: $0) } },
            set: { browserURL = $0?.url }
        )) { item in
            ClientBrowserScreen(url: item.url) {
                browserURL = nil
                if let port = forwardedPort {
                    forwardedPort = nil
                    Task { await Bridge.proxyUnlisten(peer: peer, host: "127.0.0.1", port: port) }
                }
            }
        }
    }

    private func split(detailWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    header
                    if let errorMessage {
                        ClientErrorCard(message: errorMessage) {
                            Task { await reload() }
                        }
                    }
                    // Notes are local to the machine that owns the folder,
                    // so a connected client has nothing to show under that
                    // row yet.
                    ForEach(WorkspaceSection.allCases.filter { $0 != .notes }) { item in
                        Button {
                            if item == .browser {
                                showPort = true
                            } else {
                                section = item
                            }
                        } label: {
                            ClientSectionRow(
                                section: item,
                                count: count(for: item),
                                isSelected: item == section && item != .browser,
                                showsChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Space.m)
            }
            .frame(width: Self.sectionsColumn)
            .background(Theme.background)
            Divider()
            detail(width: detailWidth)
        }
    }

    @ViewBuilder
    private func detail(width: CGFloat) -> some View {
        switch section {
        case .sessions:
            ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
        case .changes:
            ClientWorkspaceChangesView(
                peer: peer,
                workspaceID: workspaceID,
                folder: current,
                hostName: hostName
            )
        case .todo:
            ClientWorkspaceTasksView(
                peer: peer,
                workspaceID: workspaceID,
                hostName: hostName,
                folderName: current.name
            )
        case .workflows:
            if width >= Self.splitInsideSplit {
                ClientWorkflowWorkspace(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name
                )
            } else {
                NavigationStack {
                    ClientWorkspaceWorkflowsView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        folderName: current.name
                    )
                }
            }
        case .automations:
            if width >= Self.splitInsideSplit {
                ClientAutomationWorkspace(
                    peer: peer,
                    workspaceID: workspaceID,
                    hostName: hostName,
                    folderName: current.name
                )
            } else {
                NavigationStack {
                    ClientWorkspaceAutomationsView(
                        peer: peer,
                        workspaceID: workspaceID,
                        hostName: hostName,
                        folderName: current.name
                    )
                }
            }
        case .notes:
            // Not offered in the list above, so this cannot be selected.
            EmptyView()
        case .files:
            ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
        case .browser:
            ClientWorkspaceSessionsView(peer: peer, hostName: hostName, folder: folder)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(hostName)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            Text(current.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let subtitle = current.subtitle {
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func count(for section: WorkspaceSection) -> Int? {
        switch section {
        case .sessions: return counts.sessions
        case .changes: return counts.changes
        case .todo: return counts.todo
        case .workflows: return counts.workflows
        case .automations: return counts.automations
        case .notes, .files, .browser: return nil
        }
    }

    private var portSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Opens a loopback bridge to that port on \(hostName) and shows it in the in-app browser.")
                }
            }
            .navigationTitle("Browse port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPort = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { Task { await openPort() } }
                        .disabled(isOpeningPort || UInt16(portText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reload() async {
        async let status = try? ClientRemote.status(peer: peer, workspace: workspaceID)
        async let counted = ClientRemote.summaries(peer: peer)
        if let fresh = await status { live = fresh }
        let summaries: [WorkspaceSummary]
        do {
            summaries = try await counted
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            return
        }
        guard let summary = summaries.first(where: { $0.id == workspaceID }) else {
            counts.changes = current.git?.files.count ?? counts.changes
            return
        }
        counts = WorkspaceSectionCounts(
            sessions: summary.sessions,
            changes: summary.changed ?? current.git?.files.count ?? 0,
            todo: summary.tasks,
            automations: summary.automations,
            workflows: summary.workflowsRunning > 0 ? summary.workflowsRunning : summary.workflows
        )
        errorMessage = nil
    }

    private func openPort() async {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return }
        isOpeningPort = true
        defer { isOpeningPort = false }
        do {
            let result = try await Bridge.proxyListen(peer: peer, host: "127.0.0.1", port: Int(port))
            showPort = false
            forwardedPort = Int(port)
            browserURL = result.url
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
            showPort = false
        }
    }
}

#endif
