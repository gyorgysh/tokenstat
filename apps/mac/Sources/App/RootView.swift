// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The top level destinations from the desktop plan.
///
/// Workspaces opens first: this is a place to work, like an IDE, not a report.
/// Insights sits last, after the work surfaces, because that is what it is:
/// the accounting for the work, looked at when the work is done.
enum Destination: String, CaseIterable, Identifiable {
    case workspaces
    case automations
    case fleet
    case insights
    case account

    var id: String { rawValue }

    /// Account sits apart from the rest: the others are the work, it is the
    /// settings for it.
    static var workDestinations: [Destination] {
        allCases.filter { $0 != .account }
    }

    var label: String {
        switch self {
        case .workspaces: return "Workspaces"
        case .automations: return "Automations"
        case .fleet: return "Fleet"
        case .insights: return "Insights"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .workspaces: return "square.stack.3d.up.fill"
        case .automations: return "bolt.fill"
        case .fleet: return "desktopcomputer"
        case .insights: return "chart.bar.fill"
        case .account: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @State private var destination: Destination = .workspaces
    @State private var model = InsightsModel()
    @State private var account = AccountModel()
    @State private var workspaces = WorkspacesModel()
    #if os(macOS)
    @State private var terminals = TerminalsModel()
    @State private var collapsedWorkspaces: Set<String> = []
    #endif
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .inspector(isPresented: showsInspector) {
                    Group {
                        switch destination {
                        case .workspaces:
                            WorkspaceInspector(model: workspaces)
                        default:
                            InspectorView(model: model)
                        }
                    }
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
        }
        .task { await model.load() }
        // Loaded up front, not on first visit, so the sidebar can show the
        // handle without the user opening the screen to populate it.
        .task { await account.load() }
        .task { await workspaces.load() }
        #if os(macOS)
        .task { await terminals.load() }
        #endif
    }

    /// Which destinations have something for the right pane. The pane is part
    /// of the layout and is not user-closeable; it simply does not exist for
    /// screens that have nothing to put in it.
    private var showsInspector: Binding<Bool> {
        Binding(
            get: { destination == .insights || destination == .workspaces },
            set: { _ in }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Workspace")
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, Theme.Space.xs)

                ForEach(Destination.workDestinations) { item in
                    SidebarRow(
                        label: item.label,
                        symbol: item.symbol,
                        isSelected: destination == item
                    ) { destination = item }
                }

                // Folders the user chose. Nothing to do with the archive:
                // its `project` is a lossy label recovered from a slug and
                // cannot name a directory, and a folder an agent touched once
                // is not somewhere anyone wants a terminal.
                HStack {
                    SectionLabel(text: "Workspaces", count: workspaces.folders.count)
                    Spacer()
                    #if os(macOS)
                    Button {
                        Task { await workspaces.addFolder() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add a project folder")
                    #endif
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xs)

                if workspaces.folders.isEmpty {
                    Text("No folders yet. Use + to add one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                } else {
                    ForEach(workspaces.folders) { folder in
                        #if os(macOS)
                        let activeSessions = terminals.sessions(in: folder.id).filter(\.alive)
                        HStack(spacing: 0) {
                            Button {
                                if collapsedWorkspaces.contains(folder.id) {
                                    collapsedWorkspaces.remove(folder.id)
                                } else {
                                    collapsedWorkspaces.insert(folder.id)
                                }
                            } label: {
                                Image(systemName: collapsedWorkspaces.contains(folder.id)
                                      ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 24)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(collapsedWorkspaces.contains(folder.id) ? "Expand workspace" : "Collapse workspace")

                            SidebarRow(
                                label: folder.name,
                                symbol: folder.exists ? "folder" : "questionmark.folder",
                                trailing: folder.diffStat,
                                isSelected: destination == .workspaces
                                    && workspaces.selectedID == folder.id
                            ) {
                                destination = .workspaces
                                workspaces.selectedID = folder.id
                            }
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { workspaces.revealInFinder(folder) }
                            Divider()
                            // "Remove" and not "Delete": the folder stays.
                            Button("Remove from tokenstat") {
                                Task { await workspaces.remove(folder) }
                            }
                        }
                        #else
                        SidebarRow(
                            label: folder.name,
                            symbol: folder.exists ? "folder" : "questionmark.folder",
                            trailing: folder.diffStat,
                            isSelected: destination == .workspaces
                                && workspaces.selectedID == folder.id
                        ) {
                            destination = .workspaces
                            workspaces.selectedID = folder.id
                        }
                        .help(folder.path)
                        .contextMenu {
                            Divider()
                            // "Remove" and not "Delete": the folder stays.
                            Button("Remove from tokenstat") {
                                Task { await workspaces.remove(folder) }
                            }
                        }
                        #endif

                        #if os(macOS)
                        if !collapsedWorkspaces.contains(folder.id) {
                            ForEach(activeSessions) { session in
                                ActiveSessionRow(
                                    session: session,
                                    workspaceName: folder.name,
                                    // Selected only when this session is the one
                                    // actually on screen: the right workspace,
                                    // its active session, and a terminal rather
                                    // than a file or a commit in front of it.
                                    isSelected: destination == .workspaces
                                        && workspaces.selectedID == folder.id
                                        && workspaces.isShowingTerminal(in: folder.id)
                                        && terminals.active(in: folder.id)?.id == session.id
                                ) {
                                    destination = .workspaces
                                    workspaces.selectedID = folder.id
                                    workspaces.showTerminal(in: folder.id)
                                    terminals.select(session)
                                }
                            }
                        }
                        #endif
                    }
                }
            }
            .padding(.bottom, Theme.Space.m)
        }
        .background(Theme.sidebarMaterial)
        .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
        .safeAreaInset(edge: .bottom) { accountFooter }
    }

    /// Who is signed in, pinned to the bottom of the sidebar with a menu.
    ///
    /// The archive line that used to live here moved into the inspector, which
    /// already had an Archive section. Two places saying where the numbers came
    /// from was one too many, and this corner is where people look for their
    /// account.
    private var accountFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Menu {
                if account.signedIn {
                    Button("Account settings") { destination = .account }
                    Button("Sync now") { Task { await account.sync() } }
                        .disabled(account.isSyncing)
                    Divider()
                    Button("Sign out") { Task { await account.signOut() } }
                } else {
                    Button("Sign in to tokenstat.ai") {
                        destination = .account
                        account.signIn()
                    }
                    Divider()
                    Button("Account") { destination = .account }
                }
            } label: {
                accountLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.sidebarMaterial)
    }

    /// Avatar, handle, plan, chevron.
    ///
    /// The plan sits beside the handle rather than as a badge on the avatar.
    /// "Patron" is six characters and overflowed a 24pt circle, landing on top
    /// of the name.
    private var accountLabel: some View {
        HStack(spacing: Theme.Space.s) {
            Avatar(
                url: account.account?.avatar,
                handle: account.account?.handle,
                size: 22
            )

            if account.isSyncing {
                Text("Syncing…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: Theme.Space.xs) {
                    Text(account.account?.handle ?? "Not signed in")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tier = account.account?.tier, !tier.isEmpty {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                        Text(tier.capitalized)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: Theme.Space.xs)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .workspaces:
            #if os(macOS)
            WorkspacesView(model: workspaces, terminals: terminals)
            #else
            WorkspacesView(model: workspaces)
            #endif
        case .automations:
            NotBuiltYet(
                title: "Automations",
                symbol: "bolt",
                summary: """
                Recurring agent jobs that keep running with the window closed, \
                each with a budget it stops at rather than one it reports after.
                """,
                milestone: "Needs the host daemon, milestone 3"
            )
        case .fleet:
            NotBuiltYet(
                title: "Fleet",
                symbol: "desktopcomputer",
                summary: """
                Every machine signed in to your account, its workspaces, and its \
                sessions. This is what makes an iPad a client of your Mac rather \
                than a second place to read numbers.
                """,
                milestone: "Milestone 6, needs the remote transport decision"
            )
        case .account:
            AccountView(model: account)
        case .insights:
            InsightsView(model: model)
        }
    }
}

/// One row in the sidebar.
///
/// Hand rolled rather than a `List` row: the reference layout puts a stat on
/// the trailing edge of every row, and `List` selection styling fights that
/// with its own capsule.
private struct SidebarRow: View {
    var label: String
    var symbol: String
    var symbolSize: CGFloat = 11
    var trailing: String?
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                if let trailing {
                    Text(trailing)
                        .font(Theme.numeric(11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// Selection is tinted and carries a bar down its leading edge. Hover is a
    /// plain grey wash. They have to look like different things: with both as
    /// shades of grey, which workspace you were actually in was a guess.
    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.rowSelected : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear))
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
    }
}

#if os(macOS)
/// A shortcut to a running session, independent of which workspace is open.
private struct ActiveSessionRow: View {
    let session: TerminalSession
    let workspaceName: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let harnessID = session.harnessID {
                    HarnessMark(id: harnessID, size: 18)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title?.isEmpty == false ? session.title! : session.command)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(workspaceName)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Space.xs)
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }
            .padding(.leading, Theme.Space.l)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(session.cwd)
    }

    /// The same treatment as a selected workspace, but lighter.
    ///
    /// A session sits inside a workspace and the two are selected together, so
    /// they must not compete: the folder is the strong tint and the terminal
    /// within it is the same hue at half strength, with a thinner bar.
    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.rowSelectedNested : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear))
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 2)
                    .padding(.vertical, 4)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
    }
}
#endif
