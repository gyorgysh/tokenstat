// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The top level destinations.
///
/// Home opens first. It answers "what do I have left before I start", which is
/// the question people have when they open the app, and it is not the question
/// Insights answers. Insights sits last, because accounting for the work comes
/// after the work.
///
/// There is deliberately **no Workspaces row**. The folder list below these is
/// that navigation, and a row whose only effect is to select the first folder
/// repeats the list beneath it. The app used to have a `WORKSPACE` heading over
/// the destinations, a `Workspaces` destination, and a `WORKSPACES` folder
/// section: three headings for two ideas.
enum Destination: String, CaseIterable, Identifiable {
    case home
    case automations
    case machines
    case insights
    /// Reached by selecting a folder, not by a row of its own.
    case workspaces
    case account

    var id: String { rawValue }

    /// The rows in the sidebar's top group.
    ///
    /// Account is not among them: it is reached from the footer, where people
    /// look for their account. Workspaces is not among them either, for the
    /// reason above.
    static var navigable: [Destination] {
        [.home, .automations, .machines, .insights]
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .workspaces: return "Workspaces"
        case .automations: return "Automations"
        case .machines: return "Machines"
        case .insights: return "Insights"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .workspaces: return "square.stack.3d.up.fill"
        case .automations: return "bolt.fill"
        case .machines: return "desktopcomputer"
        case .insights: return "chart.bar.fill"
        case .account: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @State private var destination: Destination = .home
    @State private var model = InsightsModel()
    @State private var home = HomeModel()
    @State private var account = AccountModel()
    @State private var workspaces = WorkspacesModel()
    @State private var machines = MachinesModel()
    @State private var isInspectorPresented = true
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
                    // Wider than it was. At 300 the Changes list wrapped every
                    // path onto two lines and a commit subject onto three,
                    // which is a column of text pretending to be a panel. The
                    // minimum went up with it: nothing here reads at 240.
                    .inspectorColumnWidth(min: 280, ideal: 360, max: 520)
                }
        }
        .task { await model.load() }
        // Loaded up front, not on first visit, so the sidebar can show the
        // handle without the user opening the screen to populate it.
        .task { await account.load() }
        .task { await workspaces.load() }
        .task { await machines.load() }
        #if os(macOS)
        .task { await terminals.load() }
        #endif
        .toolbar {
            if destinationHasInspector {
                ToolbarItem {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide inspector" : "Show inspector")
                }
            }
        }
    }

    /// Which destinations have an optional right pane.
    ///
    /// The write-back is guarded. Without the guard, moving to a destination
    /// with no inspector made the getter return false, SwiftUI wrote that false
    /// straight back into `isInspectorPresented`, and the pane was then closed
    /// for the rest of the session: selecting a workspace showed no Changes
    /// panel and nothing the user did had asked for that.
    private var showsInspector: Binding<Bool> {
        Binding(
            get: { isInspectorPresented && destinationHasInspector },
            set: { open in
                guard destinationHasInspector else { return }
                isInspectorPresented = open
            }
        )
    }

    private var destinationHasInspector: Bool {
        destination == .insights || destination == .workspaces
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The brand sits where the heading used to. A sidebar's top
                // left is where an app says what it is, and this one had a
                // section label there saying "WORKSPACE", which is what it is
                // not.
                Wordmark()
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, Theme.Space.m)

                // No heading over these. They are the app's four screens and
                // they are labelled with their own names, so a word above them
                // was a word that had to be picked and then not read.
                ForEach(Destination.navigable) { item in
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
                                label: folder.isRemote
                                    ? "\(folder.machineLabel ?? "Remote") / \(folder.name)"
                                    : folder.name,
                                symbol: folder.isRemote
                                    ? "network"
                                    : (folder.exists ? "folder" : "questionmark.folder"),
                                trailing: folder.diffStat,
                                isSelected: destination == .workspaces
                                    && workspaces.selectedID == folder.id
                            ) {
                                destination = .workspaces
                                workspaces.selectedID = folder.id
                            }
                        }
                        .contextMenu {
                            if !folder.isRemote {
                                Button("Reveal in Finder") { workspaces.revealInFinder(folder) }
                            }
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
            if let status = account.lastSyncSummary ?? account.errorMessage {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: account.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    Text(status)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(account.errorMessage == nil ? Theme.secondary : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xs)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Menu {
                if account.signedIn {
                    Button("Account settings") { destination = .account }
                    Button("Sync now") { Task { await account.sync() } }
                        .disabled(account.isSyncing || account.syncCooldownUntil != nil)
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
                Text(account.account?.title ?? "Not signed in")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Theme.Space.xs)

            // The tier sits against the trailing edge rather than beside the
            // name. As a middle dot and a coloured word it read as part of the
            // name; as a badge in the corner it reads as a badge.
            if !account.isSyncing, let tier = account.account?.tier, !tier.isEmpty {
                TierBadge(tier: tier, size: 9)
            }
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
        case .home:
            HomeView(model: home, account: account) { day in
                // A click on a day is a question about that day, and Insights
                // is where day-sized questions get answered.
                model.focusOn(day: day.date)
                destination = .insights
            }
        case .automations:
            NotBuiltYet(
                title: "Automations",
                symbol: "bolt",
                summary: """
                Recurring agent jobs that keep running with the window closed, \
                each with a budget it stops at rather than one it reports after.
                """,
                milestone: "Milestone 9"
            )
        case .machines:
            MachinesView(model: machines)
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
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if let harnessID = session.harnessID {
                    HarnessMark(id: harnessID, size: 16)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16, height: 16)
                }
                // One line, and no workspace name. The row is drawn directly
                // beneath the folder it belongs to, so repeating the folder's
                // name under it says nothing and made the row twice the height
                // of the one above, which is what looked misaligned.
                Text(session.title?.isEmpty == false ? session.title! : session.command)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.xs)
                Circle()
                    .fill(Theme.success)
                    .frame(width: 5, height: 5)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(session.cwd)
    }

    /// A session sits inside a workspace and the two are selected together, so
    /// they must not compete. The folder carries the accent bar and the tint;
    /// this is a plain neutral fill and no bar of its own, indented to sit
    /// under the folder's row.
    ///
    /// It used to repeat the folder's treatment at half strength, which put two
    /// purple bars at slightly different offsets one above the other.
    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                isSelected
                    ? Theme.rowSelectedNested
                    : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
            )
            .padding(.leading, Theme.Space.l)
            .padding(.trailing, Theme.Space.xs)
    }
}
#endif
