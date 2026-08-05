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
    case todo
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
        [.home, .todo, .automations, .machines, .insights]
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .todo: return "Todo"
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
        case .todo: return "checklist"
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
    @State private var automations = AutomationsModel()
    @State private var todo = TodoModel()
    @State private var appUpdate = AppUpdateModel()
    @State private var isInspectorPresented = true
    /// Whether the window is wide enough to carry the inspector at all.
    ///
    /// Separate from `isInspectorPresented`, which is what the user asked for.
    /// Conflating them would spend the user's choice on a window resize: narrow
    /// the window once and the pane would stay shut after widening it again.
    @State private var inspectorFits = true
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
                            WorkspaceInspector(model: workspaces) { closeInspector() }
                        default:
                            InspectorView(model: model) { closeInspector() }
                        }
                    }
                    // Wider than it was. At 300 the Changes list wrapped every
                    // path onto two lines and a commit subject onto three,
                    // which is a column of text pretending to be a panel. The
                    // minimum went up with it: nothing here reads at 240.
                    .inspectorColumnWidth(min: 370, ideal: 400, max: 520)
                }
        }
        // Watch the width of the whole split view, not the detail pane: the
        // detail's own width already reflects the inspector being open, so
        // driving the decision from it oscillates.
        //
        // `onGeometryChange` would be the tidy way to write this and needs
        // macOS 15. This app targets 14.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { inspectorFits = Self.fits(proxy.size.width, open: inspectorFits) }
                    .onChange(of: quantised(proxy.size.width, step: 4)) { _, width in
                        updateInspectorFit(for: width)
                    }
            }
        }
        .task { await model.load() }
        // Loaded up front, not on first visit, so the sidebar can show the
        // handle without the user opening the screen to populate it.
        .task { await account.load() }
        // Checked, fetched and put in place without being asked. Only the
        // restart is a decision, and it waits in the sidebar until it is taken.
        .task { await appUpdate.checkAndInstall() }
        .task {
            await workspaces.load()
            // Other machines on their own slow schedule. Local folders refresh
            // from the file watcher, which must not dial anybody.
            await workspaces.watchPeers()
        }
        #if os(macOS)
        .task { await terminals.load() }
        // The File menu's Add Workspace. The menu has no model, so it posts and
        // this acts.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .addWorkspaceRequested) {
                await workspaces.addFolder()
            }
        }
        // The daemon outlives the app, so a helper installed by an older build
        // keeps answering until something replaces it. Off the main actor and
        // after the first frame: it usually finds nothing to do, and when it
        // does, copying a file and asking launchctl to reload is not work the
        // window should wait on.
        .task {
            await Task.detached(priority: .background) {
                HostAgentInstaller.refreshIfStale()
            }.value
            Bridge.reconnect()
        }
        #endif
        .toolbar {
            if destinationHasInspector {
                ToolbarItem {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    // Disabled rather than hidden when there is no room. A
                    // control that vanishes on resize reads as a bug, and one
                    // that stays but does nothing is worse: this says why.
                    .disabled(!inspectorFits)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(
                        inspectorFits
                            ? (isInspectorPresented ? "Hide inspector" : "Show inspector")
                            : "The window is too narrow for the inspector"
                    )
                }
            }
        }
    }

    /// The narrowest the window may get: sidebar at its 200 floor, detail at
    /// the 560 where the Overview's cards still sit side by side.
    ///
    /// This is the window's minimum size, set from here so it cannot drift from
    /// the number below. It must stay **smaller** than a window a user can
    /// actually make. A content minimum larger than the window does not shrink
    /// the window, it overflows it: the layout is built at the minimum and the
    /// right hand side is simply cut off by the window edge. That was the
    /// clipped inspector, and it also blinded the measurement below, which sits
    /// inside the clamp and so could only ever read the clamped width back.
    static let minimumContentWidth: CGFloat = 760

    /// What the inspector asks for, matching `inspectorColumnWidth(min:)`.
    private static let inspectorMinimumWidth: CGFloat = 370

    /// The narrowest window that can hold all three columns.
    ///
    /// `.inspector` does not enforce this itself: given less room it keeps its
    /// width and lets the trailing edge run off the window.
    private static let widthForThreeColumns = minimumContentWidth + inspectorMinimumWidth

    /// How much wider than the threshold the window must get before the pane
    /// comes back.
    ///
    /// Without it the decision is a single edge, and a drag that lands on that
    /// edge adds and removes a whole split view column on alternating frames.
    /// That is what threw inside AppKit's constraints pass: a hosted column
    /// changing its minimum size while the pass was already running. The gap
    /// means a drag has to mean it.
    private static let inspectorFitHysteresis: CGFloat = 60

    /// Whether the inspector fits, given whether it is currently showing.
    private static func fits(_ width: CGFloat, open: Bool) -> Bool {
        open
            ? width >= widthForThreeColumns
            : width >= widthForThreeColumns + inspectorFitHysteresis
    }

    /// Applies a measured width to `inspectorFits`, out of the layout pass that
    /// produced it.
    ///
    /// The hop is the point. Adding or removing the inspector column from
    /// inside layout is what AppKit refuses to do, and `.inspector`'s presence
    /// is driven straight off this value.
    private func updateInspectorFit(for width: CGFloat) {
        let next = Self.fits(width, open: inspectorFits)
        guard next != inspectorFits else { return }
        Task { @MainActor in
            if inspectorFits != next { inspectorFits = next }
        }
    }

    /// Whether the right pane is on screen, and the only place that is decided.
    ///
    /// The write-back is guarded. Without the guard, moving to a destination
    /// with no inspector made the getter return false, SwiftUI wrote that false
    /// straight back into `isInspectorPresented`, and the pane was then closed
    /// for the rest of the session: selecting a workspace showed no Changes
    /// panel and nothing the user did had asked for that. Width is guarded for
    /// the same reason, one step further: a resize would otherwise spend the
    /// user's choice.
    private var showsInspector: Binding<Bool> {
        Binding(
            get: { isInspectorPresented && destinationHasInspector && inspectorFits },
            // A resize must not be recorded as a decision. Only a press of the
            // toolbar button changes what the user asked for, so widening the
            // window brings the pane back exactly as they left it.
            set: { open in
                guard destinationHasInspector, inspectorFits else { return }
                isInspectorPresented = open
            }
        )
    }

    private var destinationHasInspector: Bool {
        destination == .insights || destination == .workspaces
    }

    /// Shuts the pane on the user's behalf.
    ///
    /// Not `showsInspector.wrappedValue = false`: that setter refuses to run
    /// when the window is too narrow, which is right for reopening and wrong
    /// for closing. Closing is always allowed.
    private func closeInspector() {
        isInspectorPresented = false
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
                    ) { selectDestination(item) }
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
                            // A 9pt glyph is a 9pt target. The frame and the
                            // shape are what make it clickable rather than
                            // merely visible.
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Add a project folder")
                    #endif
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.l)
                .padding(.bottom, Theme.Space.xs)

                if workspaces.folders.isEmpty {
                    Text("No folders yet.")
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
                            ) { selectWorkspace(folder.id) }
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
                        ) { selectWorkspace(folder.id) }
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
                                    var transaction = Transaction()
                                    transaction.animation = nil
                                    withTransaction(transaction) {
                                        destination = .workspaces
                                        workspaces.selectedID = folder.id
                                        workspaces.showTerminal(in: folder.id)
                                        terminals.select(session)
                                        isInspectorPresented = true
                                    }
                                }
                            }
                        }
                        #endif
                    }
                }

                #if os(macOS)
                // A row, always there, under whatever folders exist.
                //
                // The centre pane has a prominent Add Workspace button, but it
                // is only reachable with no folders at all: the first folder
                // added selects itself and the empty state is never seen again.
                // That left one 9pt `+` in a section header as the only way to
                // add a second folder, which is not somewhere anyone looks.
                Button {
                    Task { await workspaces.addFolder() }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add workspace…")
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, workspaces.folders.isEmpty ? 0 : Theme.Space.xs)
                #endif
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
            if let status = account.syncNotice {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: account.syncNoticeIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    Text(status)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(account.syncNoticeIsError ? Theme.warning : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xs)
            }
            UpdateCard(update: appUpdate)
            Rectangle().fill(Theme.border).frame(height: 1)
            if let notice = appUpdate.checkNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.xs)
            }
            Menu {
                if account.signedIn {
                    Button("Account settings") { destination = .account }
                    Button("Sync now") { Task { await account.sync() } }
                        .disabled(account.isSyncing || account.syncCooldownUntil != nil)
                    Divider()
                    updateItem
                    Divider()
                    Button("Sign out") { Task { await account.signOut() } }
                } else {
                    Button("Sign in to tokenstat.ai") {
                        destination = .account
                        account.signIn()
                    }
                    Divider()
                    Button("Account") { destination = .account }
                    Divider()
                    updateItem
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

    /// Check for an update, because somebody asked.
    ///
    /// The app already checks on launch, off the main actor and without saying
    /// anything, and installs what it finds. That is the right default and it
    /// is also invisible, so there is no way to answer "am I on the latest
    /// version" without one of these. The launch check stays exactly as it was.
    private var updateItem: some View {
        Button(appUpdate.isChecking ? "Checking for updates…" : "Check for updates") {
            Task { await appUpdate.checkNow() }
        }
        .disabled(appUpdate.isChecking)
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
            AutomationsView(model: automations, folders: workspaces.folders) { destination = $0 }
        case .todo:
            TodoView(model: todo, folders: workspaces.folders)
        case .machines:
            MachinesView(model: machines)
        case .account:
            AccountView(model: account)
        case .insights:
            InsightsView(model: model)
        }
    }

    /// Select the folder and destination in one immediate transaction. The
    /// inspector is part of the workspace destination, so allowing SwiftUI to
    /// animate the two state changes separately makes it visibly trail the row.
    private func selectWorkspace(_ id: String) {
        selectDestination(.workspaces) {
            workspaces.selectedID = id
            isInspectorPresented = true
        }
    }

    private func selectDestination(_ next: Destination, update: (() -> Void)? = nil) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            destination = next
            update?()
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
