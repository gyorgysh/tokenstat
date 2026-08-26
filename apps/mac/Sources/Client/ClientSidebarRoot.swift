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
                // The detail column's own width, not the window's. A folder
                // section decides between a nested split and a stacked screen
                // on the room it actually has, and on an 820 point iPad the
                // sidebar takes 300 of them.
                GeometryReader { geo in
                    detail(width: geo.size.width)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
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

    /// How tall a row is here. See `SidebarMetrics`.
    private var rowHeight: CGFloat {
        input.hasPointer ? SidebarMetrics.pointerRow : SidebarMetrics.touchRow
    }

    private func isCurrent(_ tab: ClientTab) -> Bool {
        navigation.destination == tab && navigation.folderID == nil
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                ForEach(ClientTab.allCases) { tab in
                    Button {
                        navigation.destination = tab
                        navigation.folderID = nil
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: tab.symbol)
                                .font(Theme.font(13))
                                .foregroundStyle(isCurrent(tab) ? Theme.accent : Color.secondary)
                                .frame(width: 16)
                            Text(tab.label)
                                .font(Theme.font(15, weight: isCurrent(tab) ? .medium : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .clientSidebarRowSurface(isSelected: isCurrent(tab), height: rowHeight)
                    }
                    .buttonStyle(.plain)
                    .clientSidebarRowChrome()
                }
            }
            Section {
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
            } header: {
                // The Mac's sidebar heading: small, uppercase, grey, with the
                // count on the right. A title-case row in the platform's own
                // header style was a third typographic voice in a list that
                // already has two.
                HStack {
                    Text("Machines")
                        .font(ClientType.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if !workspaces.hosts.isEmpty {
                        Text("\(workspaces.hosts.count)")
                            .font(ClientType.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // The rows set their own height, so the list must not insist on a
        // taller one underneath them: its default is 44 whatever a row asks.
        .environment(\.defaultMinListRowHeight, rowHeight)
        // Sections were spending another 20 points on the gap above their
        // heading, which is what made four destinations look like a menu.
        .clientCompactSections()
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
                Task { await reload() }
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
            .clientSidebarRowSurface(isSelected: false, height: rowHeight)
        }
        .buttonStyle(.plain)
        .disabled(host.online == false)
        .clientSidebarRowChrome()
    }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        Button {
            navigation.open(
                folderID: folder.id,
                section: navigation.folderID == folder.id ? navigation.section : .sessions
            )
        } label: {
            folderLabel(folder)
                .clientSidebarRowSurface(
                    isSelected: navigation.folderID == folder.id,
                    height: rowHeight
                )
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
    }

    private func folderLabel(_ folder: WorkspaceFolder) -> some View {
        HStack(spacing: Theme.Space.s) {
            // The accent tile the phone's folder rows and the Mac's sidebar
            // both use. A plain grey system folder in a list of purple marks
            // was the one place this app looked like somebody else's.
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "folder.fill")
                    .font(Theme.font(11, weight: .medium))
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
    }

    /// One of an open folder's sections, with what it holds.
    ///
    /// The Mac's row: glyph, word, count on the right, and nothing drawn for a
    /// zero. A column of grey zeroes is a wall of them.
    private func sectionRow(_ section: WorkspaceSection, in folder: WorkspaceFolder) -> some View {
        Button {
            navigation.open(folderID: folder.id, section: section)
        } label: {
            sectionLabel(section, in: folder)
                .clientSidebarRowSurface(
                    isSelected: navigation.folderID == folder.id
                        && navigation.section == section,
                    height: rowHeight
                )
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
    }

    private func sectionLabel(
        _ section: WorkspaceSection,
        in folder: WorkspaceFolder
    ) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: section.symbol)
                .font(Theme.font(12))
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
        Button {
            workspaces.openSession(session)
        } label: {
            sessionLabel(session)
                .clientSidebarRowSurface(isSelected: false, height: rowHeight)
        }
        .buttonStyle(.plain)
        .clientSidebarRowChrome()
    }

    private func sessionLabel(_ session: PtySessionInfo) -> some View {
        Label {
            Text(sessionTitle(session)).lineLimit(1)
        } icon: {
            Image(systemName: session.alive ? "terminal.fill" : "terminal")
                .foregroundStyle(session.alive ? Theme.accent : .secondary)
        }
        .font(ClientType.caption)
        .padding(.leading, Theme.Space.l)
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
    private func detail(width: CGFloat) -> some View {
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
                section: navigation.section,
                width: width
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

/// The sidebar's sizes, in one place.
///
/// The Mac's row is 28 points: 13 point text with five above and below. This
/// list is touched as well as pointed at, so the **target** grows and the
/// padding does not. Padding is the gap around a label, and growing it moves
/// the rows apart without making any of them easier to hit. A minimum height
/// grows the button itself: the wash, the leading bar and the tap area all
/// follow it, and the type stays where it is.
enum SidebarMetrics {
    /// The Mac's row height, which everything here is measured against.
    static let macRow: CGFloat = 28
    /// A pointer is precise, so this is the Mac's row plus the 15 percent that
    /// makes it comfortable rather than exact.
    static let pointerRow: CGFloat = macRow * 1.15
    /// A finger is not, and 44 is the platform's own number for one.
    static let touchRow: CGFloat = 44
}

extension View {
    /// Sections without the standard gap above their heading. iOS 17 and up;
    /// earlier systems keep the roomier list they already had.
    @ViewBuilder
    func clientCompactSections() -> some View {
        if #available(iOS 17, *) {
            listSectionSpacing(.compact)
        } else {
            self
        }
    }

    /// The Mac's sidebar row, drawn rather than borrowed.
    ///
    /// A `List(selection:)` cell draws the platform's highlight and, on an
    /// iPad with a keyboard, a focus ring. Neither is replaceable from
    /// underneath, so an accent wash added there came out as a boxed outline
    /// with a wash inside it. The rows are plain buttons in a plain list
    /// instead: nothing system-drawn to fight, and the selection is the Mac's,
    /// a soft accent wash with a three point bar down the leading edge.
    ///
    /// **This goes on the button's label, never on the button.** A button's
    /// hit area is its label, so padding and a minimum height applied outside
    /// it grow the picture and not the target: the row looked full width and
    /// answered only where the words were. `contentShape` says the whole of
    /// that grown label is the button, and it can only say so from inside.
    func clientSidebarRowSurface(isSelected: Bool, height: CGFloat) -> some View {
        padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Theme.rowSelected : Color.clear)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.accent)
                            .frame(width: 3)
                            .padding(.vertical, 3)
                    }
                }
            )
            .contentShape(.rect)
    }

    /// What the list needs to know about the row, applied to the button.
    ///
    /// Separate from the surface because these are the row's business rather
    /// than the button's: insets, separators and the cell fill belong outside,
    /// where the list can see them.
    func clientSidebarRowChrome() -> some View {
        hoverEffect(.highlight)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: Theme.Space.xs,
                bottom: 0,
                trailing: Theme.Space.xs
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#endif
