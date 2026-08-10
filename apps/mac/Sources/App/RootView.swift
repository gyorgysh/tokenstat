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
    /// reason above. The top group is ordered by label length so the rows read
    /// as one tidy column: HOME, TASKS, INSIGHTS, MACHINES, AUTOMATIONS.
    static var navigable: [Destination] {
        [.home, .todo, .insights, .machines, .automations]
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .todo: return "Tasks"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var destination: Destination = .home
    @State private var model = InsightsModel()
    @State private var home = HomeModel()
    @State private var account = AccountModel()
    @State private var workspaces = WorkspacesModel()
    @State private var machines = MachinesModel()
    @State private var automations = AutomationsModel()
    @State private var todo = TodoModel()
    @State private var appUpdate = AppUpdateModel()
    @State private var connectivity = ConnectivityModel()
    @State private var isInspectorPresented = true
    /// What the user chose for the sidebar, kept separate from the fit.
    ///
    /// The split view is handed `sidebarVisibility`, which forces `.detailOnly`
    /// below the width where the sidebar cannot hold a column and restores this
    /// value above it. Written only by an explicit toggle above the fit edge,
    /// or an explicit reopen below it: the split view writes its collapsed
    /// state back to the binding itself when the window narrows, and that
    /// write must not be recorded as the user's choice, or the sidebar would
    /// stay shut after the window widened again.
    @State private var columnVisibilityChoice: NavigationSplitViewVisibility = .all
    /// Whether the window is wide enough to carry the inspector at all.
    ///
    /// Separate from `isInspectorPresented`, which is what the user asked for.
    /// Conflating them would spend the user's choice on a window resize: narrow
    /// the window once and the pane would stay shut after widening it again.
    @State private var inspectorFits = true
    /// Whether the floating inspector overlay is on screen.
    ///
    /// Only meaningful in overlay mode (window below the fit edge); the
    /// column mode ignores it. Hovering the detail's trailing edge shows it,
    /// leaving starts the auto-hide, and the toolbar toggle pins it.
    @State private var isOverlayVisible = false
    /// The user pinned the overlay open, so leaving the pointer does not
    /// dismiss it. Cleared by the close button, the toggle, or a mode change.
    @State private var isOverlayPinned = false
    /// Cancelled whenever the pointer comes back, so a short trip out cannot
    /// dismiss the pane.
    @State private var hideOverlayTask: Task<Void, Never>?
    @State private var isOverlayEdgeHovered = false
    @State private var isOverlayPanelHovered = false
    /// Whether the leading sidebar column is collapsed and its left-edge peek
    /// is available: hovering the leading edge floats the sidebar over the
    /// detail, the same way the right inspector floats when it does not fit.
    @State private var isSidebarOverlayVisible = false
    @State private var isSidebarEdgeHovered = false
    @State private var isSidebarPanelHovered = false
    @State private var hideSidebarOverlayTask: Task<Void, Never>?
    /// The user explicitly reopened the sidebar below the sidebar fit edge.
    /// Honored until they close it; without the pin the fit would override
    /// the reopen on the next read.
    @State private var isSidebarPinned = false
    /// The window's content width, published by `WindowScreenObserver` from
    /// resize notifications rather than measured inside the split view.
    @State private var windowContentWidth: CGFloat = 0
    #if os(macOS)
    /// Full screen switches to an opaque titlebar; windowed stays transparent.
    /// Owned by `WindowScreenObserver`. Not used for toolbar background flips.
    @State private var isFullScreen = false
    #endif
    /// A run a delegated task asked to show: set when navigating from Tasks,
    /// consumed by the Automations screen once its runs have loaded.
    @State private var pendingRunID: String?
    /// The hovered heatmap cell's window-space frame, fed up from the grid by
    /// preference. Nil means nothing is hovered and the popover hides.
    @State private var hoveredCell: HoveredCellFrame?
    /// The window's content size, for popover placement.
    @State private var windowSize: CGSize = .zero
    #if os(macOS)
    @State private var terminals = TerminalsModel()
    @State private var collapsedWorkspaces: Set<String> = []
    #endif
    /// Logo splash until the host answers; then wireframes and data take over.
    @State private var launch = LaunchState()

    var body: some View {
        // Do not keep NavigationSplitView in the tree under the splash. Even at
        // opacity 0 it still installs the system sidebar toggle on the window
        // toolbar. Mount the chrome only after the host is ready; traffic
        // lights stay because the window itself is already up with the splash.
        ZStack {
            if launch.hostReady {
                // Same NavigationSplitView chrome in both modes. Full screen only
                // changes the AppKit titlebar (native bar above content); the
                // toolbar items stay on the detail column.
                mainChrome
                    .transition(.opacity)
            } else {
                LaunchSplashView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.32), value: launch.hostReady)
        .environment(\.hostReady, launch.hostReady)
        .task {
            await launch.prepare()
        }
        // Cell frames are reported in this space, and the popover overlay is
        // positioned in the same space, so a frame and its card agree wherever
        // the window is. Applied to the split view's result via the ZStack
        // content above: the modifiers below still attach to that tree.
        // (coordinateSpace stays on the outer ZStack so Home's heatmap and
        // popover share one space once the splash is gone.)
        .coordinateSpace(name: HeatmapView.coordinateSpace)
        .onPreferenceChange(HoveredCellFrameKey.self) { hoveredCell = $0 }
        // The inspector decision follows the window's width, published by the
        // observer from resize notifications. That source is outside any layout
        // pass; a GeometryReader inside the split view is not, and a width
        // driven from it re-entered AppKit's constraint cycle while dragging.
        .onChange(of: windowContentWidth) { _, width in
            applyWidth(for: width)
        }
        // Hover near the trailing edge shows the floating pane; leaving hides
        // it after a beat, so a trip across to the scrollbar does not dismiss
        // it. A pinned pane ignores both.
        .onChange(of: isOverlayHovered) { _, inside in
            if inside {
                hideOverlayTask?.cancel()
                isOverlayVisible = true
            } else if !isOverlayPinned {
                hideOverlayTask?.cancel()
                hideOverlayTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    isOverlayVisible = false
                }
            }
        }
        // The same peek on the leading edge: a collapsed sidebar comes back as
        // a floating pane while the pointer is near the edge, and hides again
        // once it leaves. A pinned popup (the only open state on a narrow
        // window) ignores the leave so the pointer can cross to the pane.
        .onChange(of: isSidebarOverlayHovered) { _, inside in
            if inside {
                hideSidebarOverlayTask?.cancel()
                isSidebarOverlayVisible = true
            } else if !isSidebarPinned {
                hideSidebarOverlayTask?.cancel()
                hideSidebarOverlayTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    isSidebarOverlayVisible = false
                }
            }
        }
        // A pending auto-hide outlives the window it was scheduled for; drop it
        // when the view goes away.
        .onDisappear { hideOverlayTask?.cancel() }
        .onDisappear { hideSidebarOverlayTask?.cancel() }
        .onAppear { connectivity.start() }
        .onDisappear { connectivity.stop() }
        // Track which screen the window is on so the display fit and the
        // window frame follow it.
        .background {
            #if os(macOS)
            WindowScreenObserver(
                contentWidth: $windowContentWidth,
                isFullScreen: $isFullScreen
            )
            #else
            Color.clear
            #endif
        }
        .overlay {
            DayDetailPopover(
                detail: home.hoveredDetail,
                isLoading: home.isLoadingDayDetail,
                anchor: hoveredCell,
                windowSize: windowSize
            )
        }
        #if os(macOS)
        .sheet(isPresented: $workspaces.isAddSheetPresented) {
            AddWorkspaceSheet(model: workspaces)
        }
        #endif
        // The window size for the hover popover, which needs to be placed
        // against the window rather than the pane it floats over.
        //
        // `onGeometryChange` would be the tidy way to write this and needs
        // macOS 15. This app targets 14.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowSize = proxy.size }
                    .onChange(of: quantised(proxy.size.height, step: 4)) { _, height in
                        let next = CGSize(
                            width: quantised(proxy.size.width, step: 4),
                            height: height
                        )
                        guard next != windowSize else { return }
                        // Off the layout pass, the same reason
                        // `updateInspectorFit` defers: state written from
                        // inside layout can feed straight back into it.
                        Task { @MainActor in
                            if windowSize != next { windowSize = next }
                        }
                    }
            }
        }
        // Insights is not the first screen. Loading it at launch used to fire
        // eight archive queries that all take the session lock and queue
        // behind (and in front of) Home's own work. Load on first visit.
        .task(id: destination) {
            guard destination == .insights else { return }
            await model.load()
        }
        // Returning to Home after work elsewhere: quiet re-read if the last
        // load is older than the stale window (see HomeModel.refreshIfStale).
        .onChange(of: destination) { _, next in
            guard next == .home else { return }
            Task { await home.refreshIfStale() }
        }
        // After the heatmap is up, warm secondary surfaces so Machines /
        // remote workspaces / agent tiles are a cache hit on first click.
        // Never starts before archive ready, so Home keeps the host first.
        .task(id: home.isArchiveReady) {
            guard home.isArchiveReady else { return }
            await warmSecondarySurfaces()
        }
        // Sidebar footer needs the handle, but not on the first frame. A short
        // yield lets Home's archive calls claim the host first.
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await account.load()
        }
        // Update check talks to the network and is not part of first paint.
        .task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await appUpdate.checkAndInstall()
        }
        .task {
            // Local folder names for the sidebar first. Git status is part of
            // that call, but it is still cheaper than also dialling peers.
            await workspaces.loadLocal()
            // Remote peers wait for the post-heatmap warm (or the 600ms
            // fallback below) so a cold Home does not compete with dials.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if !home.isArchiveReady {
                await workspaces.loadRemote()
            }
            // Other machines on their own slow schedule. Local folders refresh
            // from the file watcher, which must not dial anybody.
            await workspaces.watchPeers()
        }
        // A machine that just connected should not wait for the 60-second peer
        // sweep to show its folders.
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidConnect)) { note in
            if let key = note.object as? String {
                // An explicit Connect undoes a previous Disconnect; the sweep
                // notification (same object) is simply an extra reload.
                workspaces.reconnect(peer: key)
            } else {
                Task { await workspaces.loadRemote() }
            }
        }
        // An explicit Disconnect drops the peer's folders now instead of
        // waiting for the failure sweep to notice.
        .onReceive(NotificationCenter.default.publisher(for: .remotePeerDidDisconnect)) { note in
            if let key = note.object as? String {
                workspaces.disconnect(peer: key)
            }
        }
        #if os(macOS)
        .task {
            // Terminals are not on the first screen. A short yield keeps the
            // host free for Home's archive answers.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await terminals.load()
            // Sessions can start on this machine from a remote window or an
            // automation; the sidebar has to learn about them without an app
            // restart.
            await terminals.watch()
        }
        // The File menu's Add Workspace. The menu has no model, so it posts and
        // this acts.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .addWorkspaceRequested) {
                workspaces.requestAdd()
            }
        }
        // Host bring-up lives in `LaunchState.prepare` (splash). No second
        // ensureHosted here: that would race the splash and reinstall thrash.
        #endif
        // View menu shortcuts post here so a focused editor cannot swallow ⌘B
        // as "bold". Toolbar items live on the NavigationSplitView above.
        .onReceive(NotificationCenter.default.publisher(for: .toggleLeftSidebar)) { _ in
            guard launch.hostReady else { return }
            toggleLeftSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRightSidebar)) { _ in
            guard launch.hostReady, destinationHasInspector else { return }
            toggleRightSidebar()
        }
        // The network came back: refresh what the offline stretch starved.
        // This is the connectionBack hook. Do it now, not on the next
        // 30-second retry tick.
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task {
                await account.load()
                await home.refreshIfStale()
                await appUpdate.checkAndInstall()
            }
            Task { await workspaces.loadRemote() }
        }
    }

    /// Shared chrome: NavigationSplitView with the window toolbar.
    ///
    /// Toolbar items sit on the split view (not only the detail column) so
    /// the leading mark is hosted with the titlebar traffic lights in both
    /// windowed and full screen. Windowed blends under a transparent
    /// titlebar; full screen keeps the same item host with an opaque bar.
    private var mainChrome: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebar
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        // Drop the stock NavigationSplitView toggle (glyph + "Hide
        // Sidebar", no shortcut). Ours carry ⌘B / ⌥⌘B in the help.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // Leading mark next to the traffic lights. Kept on the split view
            // (not only the detail column) so full-screen titlebar layout sees
            // it in the same host as windowed mode.
            ToolbarItem(placement: .navigation) {
                leftSidebarToolbarButton
            }
            if destinationHasInspector {
                ToolbarItem(placement: .primaryAction) {
                    rightInspectorToolbarButton
                }
            }
        }
        // Always hidden. Do not flip with full screen (late rebuild, stale
        // leading mark). AppKit owns bar opacity via titlebarAppearsTransparent.
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    /// Leading sidebar mark for toolbars (sidebar column and detail column).
    private var leftSidebarToolbarButton: some View {
        SidebarToggleButton(
            edge: .leading,
            isOpen: isLeftSidebarOpen,
            action: toggleLeftSidebar,
            help: isLeftSidebarOpen
                ? "Hide Sidebar (⌘B)"
                : "Show Sidebar (⌘B)"
        )
    }

    /// Trailing inspector mark for the detail toolbar.
    private var rightInspectorToolbarButton: some View {
        SidebarToggleButton(
            edge: .trailing,
            isOpen: isRightSidebarOpen,
            action: toggleRightSidebar,
            help: isRightSidebarOpen
                ? "Hide Inspector (⌥⌘B)"
                : (inspectorFits
                    ? "Show Inspector (⌥⌘B)"
                    : "Peek Inspector (⌥⌘B)")
        )
    }

    /// Whether the leading sidebar column is on screen.
    ///
    /// Does **not** count a hover-peek float as open: that is temporary
    /// chrome (narrow windows, or a hidden column on a wide one), not the
    /// user's expanded preference.
    private var isLeftSidebarOpen: Bool {
        if windowContentWidth > 0, windowContentWidth < Self.widthForSidebar {
            return isSidebarPinned
        }
        if windowContentWidth <= 0 { return true }
        return columnVisibilityChoice == .all
    }

    /// Whether the inspector is on screen as a column or a pinned float.
    private var isRightSidebarOpen: Bool {
        guard destinationHasInspector else { return false }
        if !inspectorFits {
            return isOverlayPinned || isOverlayVisible
        }
        return isInspectorPresented
    }

    /// Toggle the leading sidebar. Same action as ⌘B and the toolbar mark.
    ///
    /// On a wide window this flips the split column. The hover peek is never
    /// entered by a press. Below the fit edge the column cannot be laid out,
    /// so the press pins the floating popup instead. Asking the split view
    /// for a column there is what crashed a narrow window on ⌘B.
    private func toggleLeftSidebar() {
        // Always clear float state first so a hide never leaves a peek up.
        isSidebarOverlayVisible = false
        isSidebarEdgeHovered = false
        isSidebarPanelHovered = false

        if windowContentWidth > 0, windowContentWidth < Self.widthForSidebar {
            // Narrow: the sidebar is a floating popup only. Pin it open or
            // close it. The split column stays shut below the fit edge.
            isSidebarPinned.toggle()
            if isSidebarPinned {
                isSidebarOverlayVisible = true
            }
            columnVisibilityChoice = .detailOnly
            return
        }
        if columnVisibilityChoice == .all {
            columnVisibilityChoice = .detailOnly
            isSidebarPinned = false
        } else {
            columnVisibilityChoice = .all
            isSidebarPinned = false
        }
    }

    /// Toggle the trailing inspector. Same action as ⌥⌘B and the toolbar mark.
    private func toggleRightSidebar() {
        guard destinationHasInspector else { return }
        if isRightSidebarOpen {
            closeInspector()
            return
        }
        isInspectorPresented = true
        // Narrow window: pin the float so it stays past hover.
        if !inspectorFits {
            isOverlayPinned = true
            isOverlayVisible = true
        }
    }

    /// The narrowest the detail column may be. `minimumContentWidth` is this
    /// plus the sidebar, and the two must be defined from one number so they
    /// cannot drift.
    static var detailMinimumWidth: CGFloat { DisplayFit.box(560) }

    /// The narrowest the sidebar column may be, matching
    /// `navigationSplitViewColumnWidth(min:)` on the sidebar.
    static var sidebarMinimumWidth: CGFloat { DisplayFit.box(200) }

    /// The narrowest the window may get: the sidebar and detail minimums
    /// together.
    ///
    /// This is the window's minimum size, set from here so it cannot drift from
    /// the numbers above. It must stay **smaller** than a window a user can
    /// actually make. A content minimum larger than the window does not shrink
    /// the window, it overflows it: the layout is built at the minimum and the
    /// right hand side is simply cut off by the window edge. That was the
    /// clipped inspector, and it also blinded the measurement below, which sits
    /// inside the clamp and so could only ever read the clamped width back.
    static var minimumContentWidth: CGFloat { sidebarMinimumWidth + detailMinimumWidth }

    /// The narrowest the window may get vertically.
    static var minimumContentHeight: CGFloat { DisplayFit.box(620) }

    /// The narrowest window that can hold all three columns.
    ///
    /// Deliberately more than the columns' bare minimums (which sum to 1160 at
    /// full factor): the Overview only stops looking cramped when the detail
    /// column keeps about 800 points, and below that the inspector is not
    /// worth the room it costs the sidebar. So the fit edge is 1450 — below
    /// it the pane stops being a column and floats instead (see the overlay
    /// below), with no band where the sidebar gets pushed for its sake.
    /// `.inspector` does not enforce any of this itself: given less room it
    /// keeps its width and lets the trailing edge run off the window.
    private static var widthForThreeColumns: CGFloat { DisplayFit.box(1450) }

    /// Below this the sidebar collapses instead of being squeezed. Above it,
    /// the user's choice stands; below it the collapse is the default, but an
    /// explicit reopen is honored (`isSidebarPinned`). Same separation as
    /// `inspectorFits` and `isInspectorPresented`: a resize must not be
    /// recorded as a decision. 1000 is where a full sidebar plus the detail
    /// minimum stops being comfortable, so the menu gets out of the way below
    /// it rather than being pushed.
    private static var widthForSidebar: CGFloat { DisplayFit.box(1000) }

    /// Whether the inspector fits.
    ///
    /// A single edge, no hysteresis: the width arrives quantised to 4 points,
    /// which is the dead band that stops a drag parked on the boundary from
    /// adding and removing the column on alternating frames. The old explicit
    /// gap existed to keep the inspector open a little past the edge; that is
    /// exactly the band in which the sidebar lost its column, so it is gone.
    private static func fits(_ width: CGFloat) -> Bool {
        width >= widthForThreeColumns
    }

    /// Applies a measured width to the decisions that depend on it: the
    /// inspector fit below, and (through `sidebarVisibility`, which reads the
    /// same width) whether the sidebar keeps its column. Out of the layout pass
    /// that produced it; the width itself arrives from a resize notification,
    /// so the hop below is belt and braces rather than the whole fix.
    ///
    /// The hop is the point. Adding or removing the inspector column from
    /// inside layout is what AppKit refuses to do, and `.inspector`'s presence
    /// is driven straight off this value.
    private func applyWidth(for width: CGFloat) {
        // Above the sidebar fit edge the popup is moot. The column can exist
        // again. A popup pinned below the edge is the user saying "keep the
        // sidebar", so hand it to the column. Otherwise the collapsed choice
        // stands, and the next narrowing auto-closes again.
        if width >= Self.widthForSidebar {
            if isSidebarPinned {
                columnVisibilityChoice = .all
            }
            isSidebarPinned = false
            isSidebarOverlayVisible = false
            isSidebarEdgeHovered = false
            isSidebarPanelHovered = false
        }
        let next = Self.fits(width)
        guard next != inspectorFits else { return }
        Task { @MainActor in
            if inspectorFits != next {
                inspectorFits = next
                if next {
                    // Column mode is back; the floating pane has nothing to
                    // float over any more.
                    isOverlayPinned = false
                    isOverlayVisible = false
                }
            }
        }
    }

    /// The sidebar visibility handed to the split view.
    ///
    /// The user's choice, forced to `.detailOnly` below the width where the
    /// sidebar cannot hold a column. Same guarded-write shape as
    /// `showsInspector`: a resize must not be recorded as a decision, so the
    /// user's value lives in its own state and the fit only overrides the
    /// getter.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                // Until the observer has reported a real width, treat the
                // window as wide enough: a fresh launch must not start with
                // the sidebar shut.
                guard windowContentWidth > 0 else { return columnVisibilityChoice }
                if windowContentWidth < Self.widthForSidebar {
                    // Below the fit edge the column is never shown: the
                    // sidebar exists there as a floating popup, pinned or
                    // peeking. Asking the split view for a column it cannot
                    // lay out is what crashed a narrow window on ⌘B.
                    return .detailOnly
                }
                return columnVisibilityChoice
            },
            set: { requested in
                if windowContentWidth < Self.widthForSidebar {
                    // The split view's writes below the edge are all float
                    // state: reopening pins the popup, collapsing unpins it.
                    // The column stays shut, and the user's choice is
                    // restored when the window widens.
                    isSidebarPinned = requested == .all
                    isSidebarOverlayVisible = requested == .all
                    columnVisibilityChoice = .detailOnly
                } else {
                    columnVisibilityChoice = requested
                    if requested == .all {
                        isSidebarPinned = false
                    }
                }
            },
        )
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

    /// The pane itself, shared by the fixed column and the floating overlay.
    @ViewBuilder
    private var inspectorContent: some View {
        Group {
            switch destination {
            case .workspaces:
                WorkspaceInspector(model: workspaces) { closeInspector() }
            default:
                InspectorView(model: model) { closeInspector() }
            }
        }
    }

    /// Whether the inspector is a floating overlay rather than a column:
    /// either the window is too narrow for the column, or the user closed the
    /// column and the pane becomes a peek that opens on hover instead of a
    /// door that stays shut.
    private var usesOverlayInspector: Bool {
        destinationHasInspector && (!isInspectorPresented || !inspectorFits)
    }

    /// The pointer is near the pane: on the edge strip or on the pane itself.
    private var isOverlayHovered: Bool {
        isOverlayEdgeHovered || isOverlayPanelHovered
    }

    /// The pointer is near the left edge: on the edge strip or on the floated
    /// sidebar panel itself.
    private var isSidebarOverlayHovered: Bool {
        isSidebarEdgeHovered || isSidebarPanelHovered
    }

    /// Whether the left-edge float is allowed.
    ///
    /// The sidebar column is off screen in two situations: the window is too
    /// narrow to hold it, or the user hid it on a wide window. Both get the
    /// same hover peek the right inspector has: the sidebar comes back as a
    /// floating pane while the pointer is near the leading edge.
    private var usesOverlaySidebar: Bool {
        guard windowContentWidth > 0 else { return false }
        if windowContentWidth < Self.widthForSidebar { return true }
        return columnVisibilityChoice == .detailOnly
    }

    /// The floated sidebar is on screen: pinned open, or peeking under the
    /// pointer.
    private var showsSidebarOverlay: Bool {
        usesOverlaySidebar && (isSidebarPinned || isSidebarOverlayVisible)
    }

    /// The floating pane is on screen.
    private var showsOverlayInspector: Bool {
        usesOverlayInspector && (isOverlayPinned || isOverlayVisible)
    }

    /// The detail column: the destination, its fixed inspector column, and the
    /// floating overlay that replaces the column below the fit edge.
    private var detailColumn: some View {
        detail
            // The destination views paint `Theme.background` themselves, but
            // the column behind them does not: while a destination swaps (the
            // inspector column appearing or leaving on the same frame), the
            // column can show the window's default surface for a moment. A
            // solid backing here closes that gap so the swap paints the app's
            // backdrop, not a light flash.
            .background(Theme.background)
            // The detail column has a declared minimum, so an overflow is
            // never absorbed by the sidebar: the split view cannot take
            // the difference from the leading column to satisfy the
            // detail's demand.
            .frame(minWidth: Self.detailMinimumWidth)
            .inspector(isPresented: showsInspector) {
                inspectorContent
                    // Fixed, on purpose. A min/ideal/max triplet left 30 points
                    // of drag travel, and dragging that divider ran the hosted
                    // column's constraint update inside NSSplitView's own
                    // constraint pass, which AppKit throws on. A single value
                    // installs no divider drag at all: the pane opens and
                    // closes, and is never dragged.
                    .inspectorColumnWidth(DisplayFit.box(400))
            }
            // Below the fit edge the inspector stops being a column and floats
            // instead: a thin hover strip at the trailing edge, the pane
            // sliding in over the detail. It pushes nothing, so the sidebar
            // can never be squeezed for its sake. The scrim underneath means a
            // click on the content beside the floating pane dismisses it, the
            // way clicking beside a popover does.
            .overlay(alignment: .leading) { sidebarDismissScrim }
            .overlay(alignment: .leading) { sidebarHoverStrip }
            .overlay(alignment: .leading) { sidebarOverlayPanel }
            .overlay(alignment: .trailing) { inspectorDismissScrim }
            .overlay(alignment: .trailing) { inspectorHoverStrip }
            .overlay(alignment: .trailing) { inspectorOverlayPanel }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsOverlayInspector
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsSidebarOverlay
            )
    }

    @ViewBuilder
    private var sidebarHoverStrip: some View {
        if usesOverlaySidebar {
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .onHover { isSidebarEdgeHovered = $0 }
        }
    }

    /// A click outside the floated sidebar closes it, mirroring the right
    /// inspector's scrim. A pinned popup unpins. A hover peek simply closes.
    @ViewBuilder
    private var sidebarDismissScrim: some View {
        if showsSidebarOverlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismissSidebarOverlay() }
        }
    }

    @ViewBuilder
    private var sidebarOverlayPanel: some View {
        if showsSidebarOverlay {
            sidebar
                .frame(width: DisplayFit.box(240))
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.20), radius: 12, x: 5, y: 0)
                .onHover { isSidebarPanelHovered = $0 }
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var inspectorHoverStrip: some View {
        if usesOverlayInspector {
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())
                .onHover { isOverlayEdgeHovered = $0 }
        }
    }

    /// A click outside the floating pane closes it.
    ///
    /// The strip and the pane sit above this, so the pane itself stays fully
    /// interactive; anywhere else in the detail column is "outside", and the
    /// natural instinct to click beside a floating window dismisses it.
    @ViewBuilder
    private var inspectorDismissScrim: some View {
        if showsOverlayInspector {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismissOverlay() }
        }
    }

    @ViewBuilder
    private var inspectorOverlayPanel: some View {
        if showsOverlayInspector {
            inspectorContent
                .frame(width: DisplayFit.box(400))
                .frame(maxHeight: .infinity)
                .background(Theme.sidebarMaterial)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                }
                // A real drop shadow, applied to the panel as one flattened
                // layer. Flattened first so the shadow is cast by the panel's
                // silhouette, full height and at its leading edge; without the
                // group, the shadow sampled the translucent material and the
                // individual controls inside it.
                .compositingGroup()
                .shadow(color: .black.opacity(0.20), radius: 12, x: -5, y: 0)
                .onHover { isOverlayPanelHovered = $0 }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Hides the floating pane, whether it was hover-revealed or pinned.
    private func dismissOverlay() {
        isOverlayPinned = false
        isOverlayVisible = false
    }

    /// Hides the floated sidebar, whether it was hover-revealed or pinned.
    private func dismissSidebarOverlay() {
        isSidebarPinned = false
        isSidebarOverlayVisible = false
        isSidebarEdgeHovered = false
        isSidebarPanelHovered = false
    }

    /// Shuts the pane on the user's behalf.
    ///
    /// Not `showsInspector.wrappedValue = false`: that setter refuses to run
    /// when the window is too narrow, which is right for reopening and wrong
    /// for closing. Closing is always allowed.
    private func closeInspector() {
        isInspectorPresented = false
        isOverlayPinned = false
        isOverlayVisible = false
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
                    .padding(.top, Theme.Space.m)
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
                        workspaces.requestAdd()
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
                    .accessibilityLabel("Add a project folder")
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
                    workspaces.requestAdd()
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
        // Solid, not the `.bar` material. When the split view re-lays out for a
        // destination change (the inspector column appearing or leaving), the
        // material can momentarily resolve against an empty backdrop and paint
        // the whole left bar light — the white flash seen when clicking
        // between menus. A flat colour cannot flash, and the ScrollView's own
        // default background layer is stripped so nothing white can show
        // through the overscroll area either.
        //
        // Ignoring top/leading/bottom safe areas lets the colour meet the
        // windowed titlebar gap patch and run flush to the screen edges in
        // full screen. The trailing edge still meets the split divider.
        .background {
            Theme.sidebar.ignoresSafeArea(edges: [.top, .leading, .bottom])
        }
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(
            min: Self.sidebarMinimumWidth,
            ideal: DisplayFit.box(228),
            max: DisplayFit.box(300)
        )
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
            // Offline is the same card language as sync and update, so the
            // footer reads as one place for "what is the network doing".
            OfflineCard(connectivity: connectivity)
            // Sync feedback is a card in the same slot and the same language
            // as the update card: success is the accent, rate limiting is
            // amber, a failure is red. A plain caption made a successful sync
            // read as a footnote.
            SyncCard(account: account)
            UpdateCard(update: appUpdate)
            Rectangle().fill(Theme.border).frame(height: 1)
            // The up-to-date confirmation is a card in `UpdateCard`; only the
            // other check results are captions.
            if let notice = appUpdate.checkNotice,
               notice != AppUpdateModel.upToDateMessage {
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
        .background(Theme.sidebar)
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
            HomeView(
                model: home,
                account: account,
                onSelectDay: { day in
                    // A click on a day is a question about that day, and
                    // Insights is where day-sized questions get answered.
                    model.focusOn(day: day.date)
                    destination = .insights
                },
                onShowAccount: { selectDestination(.account) }
            )
        case .automations:
            AutomationsView(
                model: automations,
                folders: workspaces.folders,
                onNavigate: { destination = $0 },
                pendingRunID: $pendingRunID
            )
        case .todo:
            TodoView(model: todo, folders: workspaces.folders) { runID in
                selectDestination(.automations)
                pendingRunID = runID
            }
        case .machines:
            MachinesView(model: machines)
        case .account:
            AccountView(model: account)
        case .insights:
            InsightsView(model: model) {
                // The back arrow exists only for a day that came from Home, so
                // the round trip has to end there too: clear the day filter
                // and put Home back in front.
                model.clearFocusedDay()
                selectDestination(.home)
            }
        }
    }

    /// Background fill of secondary screens after Home's heatmap is up.
    ///
    /// Machines, remote workspaces and the launch catalog used to load on
    /// first click (or on a delayed timer that still raced Home). Warm them
    /// here at low urgency so a later click paints from model state. Never
    /// blocks Home, and is cancelable when the root view goes away.
    private func warmSecondarySurfaces() async {
        // Yield once so the main actor can finish painting the heatmap before
        // we issue more host calls.
        await Task.yield()
        guard !Task.isCancelled else { return }

        // Machines: identity, peers, account directory. Parallel inside load().
        if !machines.isWarmed {
            await machines.load()
        }
        guard !Task.isCancelled else { return }

        // Remote workspace groups for the sidebar. Local folders already
        // loaded earlier; this is the peer dial pass.
        await workspaces.loadRemote()
        guard !Task.isCancelled else { return }

        #if os(macOS)
        // Agent tiles: absolute paths from the host's login PATH.
        await LaunchCatalog.shared.resolve()
        #endif
    }

    /// Select the folder and destination in one immediate transaction. The
    /// inspector is part of the workspace destination, so allowing SwiftUI to
    /// animate the two state changes separately makes it visibly trail the row.
    private func selectWorkspace(_ id: String) {
        selectDestination(.workspaces) {
            if workspaces.selectedID == id {
                // Second click on the same folder: swap between the running
                // surface and the launcher, so a new agent can be started
                // without hunting for the + menu.
                workspaces.toggleLauncher(in: id)
            } else {
                workspaces.selectedID = id
                // A first selection shows the folder as it was, not the
                // launcher it might have been left on.
                workspaces.exitLauncher(in: id)
            }
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
                    .font(.system(size: DisplayFit.dp(symbolSize)))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: DisplayFit.dp(13), weight: isSelected ? .medium : .regular))
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
