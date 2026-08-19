// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit

/// The client with navigation down the left, for an iPad that has a keyboard.
///
/// Not a second app. Every screen here is the screen the tab bar shows, in the
/// detail column instead of behind a tab. What the sidebar adds is the thing a
/// tab bar cannot hold: the account's machines, their folders, and the sessions
/// running in them, all visible at once the way the Mac's sidebar shows them.
///
/// `.sidebarAdaptable` would have been four lines and can only ever show the
/// four destinations, which is exactly the part that was already fine.
struct ClientSidebarRoot: View {
    @Binding var showAccount: Bool

    @Environment(AccountModel.self) private var account
    @Environment(ClientNavigationModel.self) private var navigation
    /// A pointer means a person aiming, not a thumb landing. Rows tighten and
    /// grow hover states. See `ClientLayout`.
    @Environment(PointerKeyboardModel.self) private var input

    /// One workspaces model for the whole layout: the tree in the sidebar and
    /// the screen in the detail column are the same connection, not two.
    @State private var workspaces = ClientWorkspacesModel()
    /// What each folder holds, keyed by workspace id. One call for the whole
    /// tree rather than one per folder: the Mac's sidebar draws these counts
    /// too, and asking per row is five tunnel hops per folder.
    @State private var summaries: [String: WorkspaceSummary] = [:]
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .clientShortcuts(shortcuts)
        .task { await reload() }
        .onChange(of: workspaces.connectedKey) { _, _ in
            Task { await loadSummaries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await workspaces.recoverAfterNetworkChange(account: account.account) }
        }
        .fullScreenCover(item: Binding(
            get: { workspaces.activeTerminal },
            set: { workspaces.activeTerminal = $0 }
        )) { session in
            ClientTerminalScreen(
                session: session,
                hostName: workspaces.hosts.first { $0.peerKey == workspaces.connectedKey }?.name ?? "",
                onClose: { workspaces.activeTerminal = nil },
                onClosedProcess: {
                    Task { await workspaces.refresh(account: account.account) }
                }
            )
        }
    }

    private func reload() async {
        await workspaces.refresh(account: account.account)
        await loadSummaries()
    }

    /// Counts for every folder on the connected machine. Quiet on failure:
    /// the tree is still usable without its numbers, and the chip in the bar
    /// is what says the machine is not answering.
    private func loadSummaries() async {
        guard let peer = workspaces.connectedKey else {
            summaries = [:]
            return
        }
        guard let list = try? await ClientRemote.summaries(peer: peer) else { return }
        summaries = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    // MARK: - Sidebar

    private var selection: Binding<ClientSidebarItem?> {
        Binding(
            get: {
                if let folder = navigation.folderID, navigation.destination == .workspaces {
                    return .folder(folder, navigation.section)
                }
                return .destination(navigation.destination)
            },
            set: { item in
                guard let item else { return }
                switch item {
                case .destination(let tab):
                    navigation.destination = tab
                    navigation.folderID = nil
                case .folder(let id, let section):
                    navigation.open(folderID: id, section: section)
                case .session(let id):
                    if let info = workspaces.sessions.first(where: { $0.id == id }) {
                        workspaces.openSession(info)
                    }
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach(ClientTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.symbol)
                        .tag(ClientSidebarItem.destination(tab))
                }
            }
            Section("Machines") {
                if workspaces.hosts.isEmpty {
                    Text("No host computers yet")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(workspaces.hosts) { host in
                    hostRow(host)
                    if workspaces.connectedKey == host.peerKey {
                        ForEach(workspaces.folders) { folder in
                            folderRow(folder)
                            // Only the open folder shows its sections, the way
                            // the Mac's sidebar opens one at a time. Four
                            // folders each spelling out eight rows is a list
                            // nobody can find anything in.
                            if navigation.folderID == folder.id {
                                ForEach(WorkspaceSection.allCases) { item in
                                    sectionRow(item, in: folder)
                                    if item == .sessions {
                                        ForEach(sessions(in: folder)) { session in
                                            sessionRow(session)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A thumb needs 44 points. A trackpad pointer does not, and the whole
        // point of this layout is seeing more of the account at once.
        .environment(\.defaultMinListRowHeight, input.hasPointer ? 32 : 44)
        // The lockup, not the word. The Mac's sidebar has the bars and the
        // two-tone name at its head, and a system title spelling "tokenstat"
        // in the same place is the one screen in the product where the brand
        // is set in the platform's font. The mark also acknowledges a pull,
        // which a title cannot do.
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("sidebar") { await reload() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AvatarButton { showAccount = true }
            }
            ToolbarItem(placement: .principal) {
                Wordmark(size: 19, fills: false)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ClientConnectionChip(compact: true)
            }
        }
    }

    /// What `⌘` opens, and what holding it lists.
    ///
    /// The numbers follow the sidebar's own order rather than the tab bar's,
    /// because the sidebar is what is on screen. `⌘,` is Settings everywhere
    /// on this platform, and here the account is the settings.
    private var shortcuts: [ClientShortcut] {
        var commands: [ClientShortcut] = []
        for (index, tab) in ClientTab.allCases.enumerated() {
            guard let key = "1234".dropFirst(index).first else { continue }
            commands.append(
                ClientShortcut(id: tab.rawValue, title: tab.label, key: KeyEquivalent(key)) {
                    navigation.destination = tab
                    navigation.folderID = nil
                }
            )
        }
        commands.append(
            ClientShortcut(id: "refresh", title: "Refresh", key: "r") {
                Task { await workspaces.refresh(account: account.account) }
            }
        )
        commands.append(
            ClientShortcut(id: "sidebar", title: "Toggle Sidebar", key: "\\") {
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        )
        commands.append(
            ClientShortcut(id: "account", title: "Account", key: ",") {
                showAccount = true
            }
        )
        return commands
    }

    /// A machine, with the dot that says whether it is awake.
    ///
    /// Asleep machines still list, greyed. The sidebar is a map of the account
    /// rather than of what happens to be running.
    private func hostRow(_ host: ClientHost) -> some View {
        Button {
            if workspaces.connectedKey == host.peerKey {
                workspaces.disconnect()
            } else {
                Task { await workspaces.connect(host) }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(host.online == true ? Theme.accent : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Image(systemName: ClientDeviceIcon.symbol(name: host.name, isHost: true))
                    .foregroundStyle(.secondary)
                Text(host.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if workspaces.isConnecting == host.peerKey {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(host.online == false)
        .hoverEffect(.highlight)
    }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            // The accent tile the phone's folder rows and the Mac's sidebar
            // both use. A plain grey system folder in a list of purple marks
            // was the one place this app looked like somebody else's.
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(ClientType.label.weight(.medium))
                    .lineLimit(1)
                gitLine(folder)
            }
        }
        .tag(ClientSidebarItem.folder(folder.id, navigation.folderID == folder.id
            ? navigation.section
            : .sessions))
        .hoverEffect(.highlight)
    }

    /// One of an open folder's sections, with what it holds.
    ///
    /// The Mac's row: glyph, word, count on the right, and nothing drawn for a
    /// zero. A column of grey zeroes is a wall of them.
    private func sectionRow(_ section: WorkspaceSection, in folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: section.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(section.label)
                .font(ClientType.caption)
            Spacer(minLength: 0)
            if let count = count(section, in: folder), count > 0 {
                Text("\(count)")
                    .font(ClientType.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Theme.Space.m)
        .tag(ClientSidebarItem.folder(folder.id, section))
        .hoverEffect(.highlight)
    }

    /// What a section row says on its right. Nil where a count would be a
    /// guess: Files and Browser are not collections this side has counted.
    private func count(_ section: WorkspaceSection, in folder: WorkspaceFolder) -> Int? {
        guard let summary = summaries[ClientRemote.rawWorkspaceID(of: folder) ?? folder.id] else {
            return nil
        }
        switch section {
        case .sessions: return summary.sessions
        case .changes: return summary.changed ?? folder.git?.files.count
        case .todo: return summary.tasks
        case .notes: return summary.notes
        case .workflows: return summary.workflowsRunning > 0
            ? summary.workflowsRunning
            : summary.workflows
        case .automations: return summary.automations
        case .files, .browser: return nil
        }
    }

    /// The branch and what is on it, as the Mac's sidebar draws it.
    ///
    /// In pieces rather than as one string, because the counts carry the diff
    /// colours: as one grey line `main ⇡2 +535 −46` reads as a serial number
    /// and nothing in it says which number is which. Numeric face throughout,
    /// so a count ticking over does not shift the line sideways.
    @ViewBuilder
    private func gitLine(_ folder: WorkspaceFolder) -> some View {
        let font = ClientType.caption.monospacedDigit()
        if let git = folder.git, git.isRepo {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(ClientType.caption)
                    .foregroundStyle(.tertiary)
                Text(git.branch.map { $0.isEmpty ? "detached" : $0 } ?? "detached")
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if git.ahead > 0 {
                    Text("⇡\(git.ahead)").font(font).foregroundStyle(Theme.accent)
                }
                if git.behind > 0 {
                    Text("⇣\(git.behind)").font(font).foregroundStyle(Theme.accent)
                }
                if !git.files.isEmpty {
                    Text("+\(git.added)").font(font).foregroundStyle(Theme.diffAdded)
                    if git.removed > 0 {
                        Text("−\(git.removed)").font(font).foregroundStyle(Theme.diffRemoved)
                    }
                    // A floor rather than a total when a file could not be
                    // counted, said the way the rest of the app says it.
                    if git.partial {
                        Text("+").font(font).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        } else if let subtitle = folder.subtitle {
            Text(subtitle)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func sessionRow(_ session: PtySessionInfo) -> some View {
        Label {
            Text(sessionTitle(session)).lineLimit(1)
        } icon: {
            Image(systemName: session.alive ? "terminal.fill" : "terminal")
                .foregroundStyle(session.alive ? Theme.accent : .secondary)
        }
        .font(ClientType.caption)
        .padding(.leading, Theme.Space.l)
        .tag(ClientSidebarItem.session(session.id))
        .hoverEffect(.highlight)
    }

    private func sessionTitle(_ session: PtySessionInfo) -> String {
        if let harness = harnessID(forCommand: session.command) { return harnessName(harness) }
        return URL(fileURLWithPath: session.command).lastPathComponent
    }

    /// The sessions running in one folder, matched on the directory rather
    /// than on a label: two checkouts can share a basename.
    private func sessions(in folder: WorkspaceFolder) -> [PtySessionInfo] {
        workspaces.sessions.filter { $0.cwd == folder.path }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = navigation.folderID,
           navigation.destination == .workspaces,
           let folder = workspaces.folders.first(where: { $0.id == id }),
           let peer = workspaces.connectedKey
        {
            // The sections are in the sidebar, so the detail column is the
            // section. Drawing the folder split here would list them twice.
            ClientWorkspaceSectionDetail(
                peer: peer,
                hostName: workspaces.hosts.first { $0.peerKey == peer }?.name ?? "",
                folder: folder,
                section: navigation.section
            )
        } else {
            switch navigation.destination {
            case .home: ClientHomeView()
            case .insights: ClientInsightsView()
            case .machines: ClientDevicesView()
            case .workspaces: ClientWorkspacesView(model: workspaces)
            }
        }
    }
}

/// What one row in the sidebar stands for.
///
/// A folder row carries the section it stands for, which is what lets the
/// sidebar hold the whole tree the Mac's does: folder, then Sessions, Changes,
/// Tasks, Notes and the rest, each landing in the detail column on its own.
enum ClientSidebarItem: Hashable {
    case destination(ClientTab)
    case folder(String, WorkspaceSection)
    case session(String)
}

#endif
