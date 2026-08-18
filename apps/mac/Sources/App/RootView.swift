// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// Everything below is the desktop shell: a resizable window with two sidebars,
// an inspector, a terminal stack and a menu bar. None of it is a phone, and a
// phone-sized copy of it would be the wrong app rather than a smaller one, so
// the client gets its own root in `ClientRootView`. See `docs/ios-client-ui.md`.
//
// `Route` and its sections live in `Route.swift`, outside this guard:
// `AutomationsView` navigates by `NavigationRequest` and compiles for both
// platforms.
#if os(macOS)

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var route: Route = .global(.home)
    @State private var model = InsightsModel()
    @State private var home = HomeModel()
    @State private var account = AccountModel()
    @State private var workspaces = WorkspacesModel()
    @State private var machines = MachinesModel()
    @State private var automations = AutomationsModel()
    @State private var workflows = WorkflowsModel()
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
    /// Written by `watchPointer`, which opens it after a dwell at the edge and
    /// closes it when the pointer has actually left, and by the toggle on a
    /// window too narrow to dock into. Whether it stays
    /// without the pointer is `isOverlayPinned`, which is derived from the
    /// toggle rather than stored.
    @State private var isOverlayVisible = false
    /// The float is up because the toolbar toggle was pressed on a window too
    /// narrow to hold the column, and the pointer has not reached it yet.
    ///
    /// Cleared the moment the pointer arrives, after which the pane behaves
    /// like every other peek and leaves when the pointer does. A press should
    /// not have to be undone by a second press, and a pane should not vanish
    /// while somebody is still moving towards it.
    @State private var overlayHeldByPress = false
    /// Whether the leading sidebar column is collapsed and its left-edge peek
    /// is available: hovering the leading edge floats the sidebar over the
    /// detail, the same way the right inspector floats when it does not fit.
    @State private var isSidebarOverlayVisible = false
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
    /// Measured titlebar band above contentLayoutRect. Detail chrome pulls up
    /// by this amount so it shares the traffic-light row.
    @State private var titlebarInset: CGFloat = 0
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
    @State private var workspacePendingRemove: WorkspaceFolder?
    /// Folders whose sections are showing. Collapsed is the default: a
    /// sidebar of six folders each listing seven sections is a wall, and the
    /// question it should answer first is which folder, not which section.
    @State private var expandedWorkspaces: Set<String> = []
    /// The section each folder was last left on, so returning to a folder
    /// returns to what you were doing in it.
    @State private var lastSection: [String: WorkspaceSection] = [:]
    /// The every-folder group. Shut by default, and remembered: it answers a
    /// question people ask about once a week.
    @AppStorage("sidebar.globalGroupExpanded") private var isGlobalGroupExpanded = false
    /// Workspace id the current drag would land before, or `workspaceDropEnd`.
    @State private var workspaceDropBeforeID: String?
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
        // Where the pointer is decides both peeks, and it is asked rather
        // than waited for. See `watchPointer`.
        .task { await watchPointer() }
        // A pending auto-hide outlives the window it was scheduled for; drop it
        // when the view goes away.
        .onAppear { connectivity.start() }
        .onDisappear { connectivity.stop() }
        // Track which screen the window is on so the display fit and the
        // window frame follow it.
        .background {
            #if os(macOS)
            WindowScreenObserver(
                contentWidth: $windowContentWidth,
                isFullScreen: $isFullScreen,
                titlebarInset: $titlebarInset
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
        // macOS 15. This app targets 14. Track both axes: width-only resizes
        // used to leave a stale width and clamp the card against the wrong
        // edge.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowSize = proxy.size }
                    .onChange(of: quantised(proxy.size.width, step: 4)) { _, width in
                        publishWindowSize(
                            CGSize(width: width, height: quantised(proxy.size.height, step: 4))
                        )
                    }
                    .onChange(of: quantised(proxy.size.height, step: 4)) { _, height in
                        publishWindowSize(
                            CGSize(width: quantised(proxy.size.width, step: 4), height: height)
                        )
                    }
            }
        }
        // Insights is not the first screen. Loading it at launch used to fire
        // eight archive queries that all take the session lock and queue
        // behind (and in front of) Home's own work. Load on first visit.
        .task(id: route) {
            guard route.isGlobal(.insights) else { return }
            await model.load()
        }
        // Returning to Home after work elsewhere: quiet re-read if the last
        // load is older than the stale window (see HomeModel.refreshIfStale).
        .onChange(of: route) { _, next in
            // A float belongs to the screen it was opened over. Carrying one
            // across a navigation is how somebody who clicked a workspace ends
            // up with a pane over it that they never asked for.
            isOverlayVisible = false
            overlayHeldByPress = false
            applyScope(from: next)
            guard next.isGlobal(.home) else { return }
            Task { await home.refreshIfStale() }
        }
        #if os(macOS)
        .onChange(of: workspaces.front(in: route.workspaceID ?? "")) { _, front in
            syncRouteToFront(front)
        }
        #endif
        // After the heatmap is up, warm secondary surfaces so Machines /
        // remote workspaces / agent tiles are a cache hit on first click.
        // Never starts before archive ready, so Home keeps the host first.
        .task(id: home.isArchiveReady) {
            guard home.isArchiveReady else { return }
            await warmSecondarySurfaces()
        }
        // Live automations belong on the workspace sidebar, so the run list
        // has to stay current even when the Automations screen is not open.
        .task {
            await automations.load()
            while !Task.isCancelled {
                let interval: Duration = automations.runs.contains(where: \.isRunning)
                    ? .seconds(2)
                    : .seconds(12)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await automations.refreshList()
            }
        }
        .task {
            await workflows.load()
            while !Task.isCancelled {
                let interval: Duration = workflows.runs.contains(where: \.isLive)
                    ? .seconds(2)
                    : .seconds(12)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await workflows.refreshList()
            }
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
            guard launch.hostReady, route.hasInspector else { return }
            toggleRightSidebar()
        }
        // A folder can leave the list from anywhere: Remove in this window,
        // a peer going away, another machine dropping off the tunnel. The
        // route must not keep naming it, or the sidebar lights no row while
        // the pane shows a different folder, and a scoped board keeps a scope
        // no `onChange(of: route)` will ever clear.
        .onChange(of: workspaces.folders.map(\.id)) { _, ids in
            guard let id = route.workspaceID, !ids.contains(id) else { return }
            lastSection[id] = nil
            expandedWorkspaces.remove(id)
            if let next = workspaces.selectedID, ids.contains(next) {
                selectWorkspace(next)
            } else {
                navigate(to: .global(.home))
            }
        }
        .onChange(of: todo.selectionGeneration) { _, _ in
            guard todo.selectedCardID != nil else { return }
            isInspectorPresented = true
            if !inspectorFits {
                isOverlayVisible = true
                overlayHeldByPress = true
            }
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
            Task { await Bridge.nudgeTunnel(reconnect: true) }
        }
        // Waking from sleep is the same story as the network coming back: the
        // machine's egress is only just arriving, so the tunnel supervisor
        // should reconnect now rather than wait out a backoff sized for a
        // laptop that was off.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await Bridge.nudgeTunnel() }
        }
    }

    /// Shared chrome: NavigationSplitView.
    ///
    /// Sidebar and inspector marks live in each screen's `DetailChromeBar`
    /// (leading), with destination actions on the trailing side. The system
    /// toolbar is empty on purpose so the titlebar is only traffic lights and
    /// every destination shares one content chrome row.
    private var mainChrome: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebar
        } detail: {
            detailColumn
                .environment(\.detailChromeToggles, detailChromeToggles)
                // Pull DetailChromeBar into the measured titlebar band (same
                // vertical row as traffic lights). Value comes from AppKit
                // contentLayoutRect, not a faked compact chrome height.
                .padding(.top, -titlebarInset)
        }
        .navigationSplitViewStyle(.balanced)
        // Drop the stock NavigationSplitView toggle (glyph + "Hide
        // Sidebar", no shortcut). Ours carry ⌘B / ⌥⌘B in the help, and live
        // in DetailChromeBar rather than here.
        .toolbar(removing: .sidebarToggle)
        // No app items. Background hidden; AppKit also hides the empty host
        // so it does not own a content band (WindowScreenObserver).
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    /// Leading toggles injected into every destination's chrome bar.
    private var detailChromeToggles: DetailChromeToggles {
        DetailChromeToggles(
            leftSidebar: AnyView(leftSidebarToolbarButton),
            rightInspector: route.hasInspector
                ? AnyView(rightInspectorToolbarButton)
                : nil
        )
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

    /// Whether the inspector is on screen, as a column, a docked float or a
    /// peek. What the toolbar mark lights up for.
    private var isRightSidebarOpen: Bool {
        guard route.hasInspector else { return false }
        if !inspectorFits {
            return isOverlayPinned || isOverlayVisible
        }
        return isInspectorPresented || isOverlayVisible
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
    ///
    /// The button means docked or not docked, and nothing else. It is not a
    /// show/hide for whatever happens to be on screen: pressing it while a peek
    /// is open docks that peek, which is what somebody who has just hovered
    /// their way to the pane and reached for the button wants. Pressing it
    /// again undocks, and the pane goes back to appearing under the pointer and
    /// leaving with it.
    ///
    /// Where "docked" puts the pane is the window's business rather than the
    /// user's: a column where there is room, a float that stays where there is
    /// not.
    private func toggleRightSidebar() {
        guard route.hasInspector else { return }
        if isInspectorPresented {
            closeInspector()
            return
        }
        isInspectorPresented = true
        if !inspectorFits {
            isOverlayVisible = true
            overlayHeldByPress = true
        }
    }

    /// How long the pointer has to rest on an edge strip before the pane
    /// behind it opens.
    ///
    /// Long enough that crossing the edge does nothing, short enough that
    /// somebody who meant it does not think the strip is broken. A second is
    /// the number people describe when they ask for this, and it matches what
    /// the system's own edge reveals feel like.
    static let edgeDwell: TimeInterval = 0.4
    /// How long the pointer has to be away before an undocked peek closes.
    /// Short enough to feel like it follows the pointer, long enough that a
    /// trip to a scrollbar or across a corner is not a dismissal.
    static let edgeGrace: TimeInterval = 0.28
    /// How close to the edge counts as asking for the pane, while it is shut.
    ///
    /// Wider than a hairline, and deliberately reaching **inward**. The last
    /// few points of a window belong to the resize cursor, so a narrow strip
    /// meant aiming at the one band of pixels that is also the window's handle:
    /// overshoot and you are dragging the window instead of opening a pane.
    /// Half an inch in is a place a pointer can arrive at without care, while
    /// still being somewhere nobody rests by accident.
    static let edgeStrip: CGFloat = 32

    /// The narrowest the detail column may be. The window minimum is this
    /// alone: below `widthForSidebar` the sidebar overlays, so requiring
    /// both columns overflows a tiled half-screen.
    static var detailMinimumWidth: CGFloat { DisplayFit.box(480) }

    /// The narrowest the sidebar column may be, matching
    /// `navigationSplitViewColumnWidth(min:)` on the sidebar.
    static var sidebarMinimumWidth: CGFloat { DisplayFit.box(200) }

    /// The narrowest the window may get.
    ///
    /// Detail only. A content minimum larger than the window does not shrink
    /// the window, it overflows it: the layout is built at the minimum and the
    /// trailing edge is cut off. Half-screen tile on a 1440-wide display is
    /// about 720, which is less than sidebar + detail (760 at factor 1).
    static var minimumContentWidth: CGFloat { detailMinimumWidth }

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

    /// Publishes the window content size for the day hover card. Deferred so a
    /// GeometryReader measurement cannot re-enter layout on the same pass.
    private func publishWindowSize(_ next: CGSize) {
        guard next != windowSize else { return }
        Task { @MainActor in
            if windowSize != next { windowSize = next }
        }
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
        }
        let next = Self.fits(width)
        guard next != inspectorFits else { return }
        Task { @MainActor in
            if inspectorFits != next {
                inspectorFits = next
                if next {
                    // Column mode is back; the floating pane has nothing to
                    // float over any more.
                    isOverlayVisible = false
                    overlayHeldByPress = false
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
                    // Below the fit edge the split view is forced closed. Its
                    // write-back is a layout consequence, not a user choice.
                    // Ignore it so widening restores the embedded sidebar.
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
            get: { isInspectorPresented && route.hasInspector && inspectorFits },
            // A resize must not be recorded as a decision. Only a press of the
            // toolbar button changes what the user asked for, so widening the
            // window brings the pane back exactly as they left it.
            set: { open in
                guard route.hasInspector, inspectorFits else { return }
                isInspectorPresented = open
            }
        )
    }

    /// Height of the titlebar band the detail column is lifted into.
    ///
    /// `mainChrome` pulls the whole detail column up by `titlebarInset` so
    /// `DetailChromeBar` shares the traffic-light row. Everything mounted on
    /// that column rises with it, including the inspector and the two floating
    /// panels, and that is wrong for all three: the sidebar's wordmark lands
    /// under the traffic lights, and the inspector's tab strip lands in a strip
    /// where **AppKit's titlebar owns the mouse**, so the tabs and the close
    /// button are not merely cramped, they are unclickable. Panes add the band
    /// back and start where the window's content actually starts.
    private var chromeTopInset: CGFloat {
        #if os(macOS)
        titlebarInset
        #else
        0
        #endif
    }

    /// Puts a pane mounted on the detail column back below the titlebar band.
    ///
    /// The band stays free of controls: AppKit's titlebar owns the mouse there,
    /// and a tab or close button drawn into it cannot be pressed. It is not
    /// left unpainted. `Color.clear` showed the window's liquid glass (or the
    /// unfocused grey titlebar) through the inspector, while the left sidebar
    /// fills the same strip with `Theme.sidebar`. Paint the same colour here,
    /// and never take a click.
    private func belowTitlebar<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            if chromeTopInset > 0 {
                Theme.sidebar
                    .frame(height: chromeTopInset)
                    .allowsHitTesting(false)
            }
            content()
        }
    }

    /// The pane itself, shared by the fixed column and the floating overlay.
    @ViewBuilder
    private var inspectorContent: some View {
        Group {
            switch route {
            case .workspace(_, .todo):
                todoInspector
            case .workspace(_, .workflows), .global(.workflows):
                WorkflowsInspector(
                    model: workflows,
                    folders: workspaces.folders
                ) { closeInspector() }
            case .workspace(_, .automations), .global(.automations):
                AutomationsInspector(
                    model: automations,
                    folders: workspaces.folders
                ) { closeInspector() }
            case .workspace:
                #if os(macOS)
                WorkspaceInspector(
                    model: workspaces,
                    automations: automations,
                    terminals: terminals,
                    account: account.account,
                    onClose: { closeInspector() },
                    onOpenAutomation: { jobID, runID in
                        openAutomation(jobID: jobID, runID: runID)
                    }
                )
                #else
                WorkspaceInspector(
                    model: workspaces,
                    account: account.account
                ) { closeInspector() }
                #endif
            case .global(.home):
                HomeInspector(
                    model: home,
                    onOpenInsights: { day in
                        model.focusOn(day: day)
                        navigate(to: .global(.insights))
                    }
                ) { closeInspector() }
            case .global(.todo):
                todoInspector
            case .global(.machines):
                MachinesInspector(model: machines) { closeInspector() }
            case .global(.insights):
                InspectorView(model: model) { closeInspector() }
            case .global(.account):
                EmptyView()
            }
        }
    }

    /// Shared by the global board and a folder's, which differ only in what
    /// the board is showing.
    private var todoInspector: some View {
        TodoInspector(
            model: todo,
            folders: workspaces.folders,
            onViewRun: { runID in
                navigate(to: .global(.automations))
                pendingRunID = runID
                isInspectorPresented = true
            },
            onRunInFront: { launch in
                launchTaskInFront(launch)
            }
        ) { closeInspector() }
    }

    /// Whether the inspector is a floating overlay rather than a column:
    /// either the window is too narrow for the column, or the user closed the
    /// column and the pane becomes a peek that opens on hover instead of a
    /// door that stays shut.
    private var usesOverlayInspector: Bool {
        route.hasInspector && (!isInspectorPresented || !inspectorFits)
    }

    /// Whether the floating inspector stays put without the pointer.
    ///
    /// **Only ever true because somebody just pressed the button.** Docked is a
    /// column, and a window with no room for a column has no docked state to
    /// be in: deriving one from the toggle meant that on a narrow window every
    /// arrival at a destination with an inspector threw a pane across the
    /// content nobody had asked to cover.
    ///
    /// So the toggle records a preference for when there is room, and on a
    /// narrow window a press means "show it now". That reveal waits for the
    /// pointer to arrive rather than closing under a hand that is still on its
    /// way, and once the pointer has been on the pane it leaves with it like
    /// any other peek. See `overlayHeldByPress`.
    private var isOverlayPinned: Bool { overlayHeldByPress }

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
                belowTitlebar { inspectorContent }
                    // Opaque, like the leading sidebar. `.inspector` on a
                    // transparent titlebar otherwise composites the column
                    // against liquid glass, which is what made the Files /
                    // Changes / History strip look see-through or unfocused.
                    .background(Theme.sidebar)
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
            // can never be squeezed for its sake.
            //
            // Hit testing is the point of the HStack layout: the dismiss
            // scrim and the panel must not share the same rectangle. A full-
            // size clear scrim under the panel (ZStack) still won taps from
            // workspace file rows and the account menu. Side-by-side means
            // the panel's frame is exclusively the panel's.
            .overlay(alignment: .leading) { sidebarFloatLayer }
            .overlay(alignment: .trailing) { inspectorFloatLayer }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsOverlayInspector
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: showsSidebarOverlay
            )
    }

    /// Floated sidebar: panel on the leading edge, dismiss region to its right.
    /// Flush to the window edge like a column, not a floating card with inset.
    @ViewBuilder
    private var sidebarFloatLayer: some View {
        if showsSidebarOverlay {
            HStack(spacing: 0) {
                belowTitlebar { sidebar }
                    .frame(width: DisplayFit.box(240))
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Theme.border)
                            .frame(width: 1)
                    }
                    .shadow(color: Theme.shadow(0.20), radius: 12, x: 5, y: 0)

                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissSidebarOverlay() }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// Floated inspector: panel on the trailing edge, dismiss region to its
    /// left. Same non-overlapping hit model as the sidebar float.
    @ViewBuilder
    private var inspectorFloatLayer: some View {
        if showsOverlayInspector {
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissOverlay() }

                belowTitlebar { inspectorContent }
                    .frame(width: DisplayFit.box(400))
                    .frame(maxHeight: .infinity)
                    .background(Theme.sidebar)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.border)
                            .frame(width: 1)
                    }
                    .shadow(color: Theme.shadow(0.20), radius: 12, x: -5, y: 0)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Open and close both edge peeks from where the pointer actually is.
    ///
    /// **`onHover` was the wrong source.** It reports crossings, and it misses
    /// them: a pointer that leaves fast, leaves onto another window, or leaves
    /// while a menu takes the mouse never produces the exit event, so a pane
    /// that opened stayed open with nothing under the pointer. Reported as
    /// "it does not always auto close", and it is not a timing bug that a
    /// longer grace period fixes, it is an event that never arrives.
    ///
    /// Asking `NSEvent.mouseLocation` cannot miss anything. Ten times a second
    /// is far below anything measurable and it answers both questions at once:
    /// has the pointer rested at the edge long enough to mean it, and has it
    /// actually left.
    ///
    /// **A peek that is not docked always auto-hides**, at every window size.
    /// Pinning belongs to the toolbar toggle alone: it is the docked state, and
    /// on a window too narrow to carry the column a pinned float is what
    /// "docked" has to mean. Nothing else pins, so nothing can lock a pane
    /// open behind the user's back.
    @MainActor
    private func watchPointer() async {
        #if os(macOS)
        var trailingSince: Date?
        var trailingLeftAt: Date?
        var leadingSince: Date?
        var leadingLeftAt: Date?
        let now = { Date() }

        while !Task.isCancelled {
            if usesOverlayInspector {
                let width = showsOverlayInspector ? DisplayFit.box(400) : Self.edgeStrip
                let inside = Self.pointerIsNear(.trailing, within: width)
                if inside {
                    trailingLeftAt = nil
                    // The pointer has arrived at a pane a press put there, so
                    // the press has done its job and the pane goes back to
                    // following the pointer.
                    if overlayHeldByPress { overlayHeldByPress = false }
                    if showsOverlayInspector {
                        trailingSince = nil
                    } else {
                        let since = trailingSince ?? now()
                        trailingSince = since
                        if now().timeIntervalSince(since) >= Self.edgeDwell {
                            isOverlayVisible = true
                            trailingSince = nil
                        }
                    }
                } else {
                    trailingSince = nil
                    if isOverlayVisible, !isOverlayPinned {
                        let left = trailingLeftAt ?? now()
                        trailingLeftAt = left
                        // A short trip out, to a scrollbar or across a corner,
                        // is not a dismissal.
                        if now().timeIntervalSince(left) >= Self.edgeGrace {
                            isOverlayVisible = false
                            trailingLeftAt = nil
                        }
                    } else {
                        trailingLeftAt = nil
                    }
                }
            } else {
                trailingSince = nil
                trailingLeftAt = nil
            }

            if usesOverlaySidebar {
                let width = showsSidebarOverlay ? DisplayFit.box(240) : Self.edgeStrip
                let inside = Self.pointerIsNear(.leading, within: width)
                if inside {
                    leadingLeftAt = nil
                    if showsSidebarOverlay {
                        leadingSince = nil
                    } else {
                        let since = leadingSince ?? now()
                        leadingSince = since
                        if now().timeIntervalSince(since) >= Self.edgeDwell {
                            isSidebarOverlayVisible = true
                            leadingSince = nil
                        }
                    }
                } else {
                    leadingSince = nil
                    if isSidebarOverlayVisible, !isSidebarPinned {
                        let left = leadingLeftAt ?? now()
                        leadingLeftAt = left
                        if now().timeIntervalSince(left) >= Self.edgeGrace {
                            isSidebarOverlayVisible = false
                            leadingLeftAt = nil
                        }
                    } else {
                        leadingLeftAt = nil
                    }
                }
            } else {
                leadingSince = nil
                leadingLeftAt = nil
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
        #endif
    }

    #if os(macOS)
    /// Whether the pointer is inside `width` points of one edge of this app's
    /// window.
    ///
    /// Screen coordinates on both sides, so no view has to publish a frame and
    /// no layout pass is involved. A pointer over another app's window is not
    /// near anything: `frame.contains` is what rules that out.
    private static func pointerIsNear(_ edge: HorizontalEdge, within width: CGFloat) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else {
            return false
        }
        let point = NSEvent.mouseLocation
        let frame = window.frame
        guard frame.contains(point) else { return false }
        switch edge {
        case .trailing: return point.x >= frame.maxX - width
        case .leading: return point.x <= frame.minX + width
        }
    }
    #endif

    /// Hides the floating pane.
    ///
    /// A pinned pane is pinned because the toggle is on, so dismissing one is
    /// turning the toggle off. Anything less would leave a pane that comes
    /// straight back on the next pointer move.
    private func dismissOverlay() {
        isInspectorPresented = false
        isOverlayVisible = false
        overlayHeldByPress = false
    }

    /// Hides the floated sidebar, whether it was hover-revealed or pinned.
    private func dismissSidebarOverlay() {
        isSidebarPinned = false
        isSidebarOverlayVisible = false
    }

    /// Shuts the pane on the user's behalf.
    ///
    /// Not `showsInspector.wrappedValue = false`: that setter refuses to run
    /// when the window is too narrow, which is right for reopening and wrong
    /// for closing. Closing is always allowed.
    private func closeInspector() {
        isInspectorPresented = false
        isOverlayVisible = false
        overlayHeldByPress = false
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

                // No heading over these three. They are the whole machine,
                // they are labelled with their own names, and a word above
                // them was a word that had to be picked and then not read.
                ForEach(GlobalSection.standalone) { item in
                    SidebarRow(
                        label: item.label,
                        symbol: item.symbol,
                        isSelected: route.isGlobal(item)
                    ) { navigate(to: .global(item)) }
                }

                // Tasks, workflows and automations belong to a folder, and the
                // rows for them here are the every-folder view. That is the
                // weekly question rather than the daily one, so it is one
                // collapsed group instead of three rows competing with the
                // folders below.
                SidebarGroupHeader(
                    title: "Global",
                    isExpanded: isGlobalGroupExpanded
                ) { isGlobalGroupExpanded.toggle() }
                if isGlobalGroupExpanded {
                    ForEach(GlobalSection.everywhere) { item in
                        SidebarRow(
                            label: item.label,
                            symbol: item.symbol,
                            isSelected: route.isGlobal(item)
                        ) { navigate(to: .global(item)) }
                    }
                }

                // Folders the user chose. Nothing to do with the archive:
                // its `project` is a lossy label recovered from a slug and
                // cannot name a directory, and a folder an agent touched once
                // is not somewhere anyone wants a terminal.
                SidebarGroupHeader(
                    title: "Workspaces",
                    count: workspaces.folders.count,
                    isExpanded: nil
                ) {} trailing: {
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

                if workspaces.folders.isEmpty {
                    Text("No folders yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                } else {
                    ForEach(workspaces.folders) { folder in
                        #if os(macOS)
                        if workspaceDropBeforeID == folder.id {
                            workspaceInsertionLine
                        }
                        let activeSessions = terminals.sessions(in: folder.id).filter(\.alive)
                        // The open workspace, and whether a terminal inside it
                        // is what the centre pane is actually showing. Only one
                        // of the two rows lights up: the folder when you are
                        // looking at the folder, the session when you are
                        // looking at a shell.
                        let isCurrent = route.workspaceID == folder.id
                        // The launcher is its own surface, so a folder sitting
                        // on the launch grid is not showing a terminal and no
                        // session row may claim to be what you are looking at.
                        let showingTerminal = isCurrent
                            && workspaces.isShowingTerminal(in: folder.id)
                            && terminals.active(in: folder.id) != nil
                        let isExpanded = expandedWorkspaces.contains(folder.id)
                        HStack(spacing: 0) {
                            Button {
                                if isExpanded {
                                    expandedWorkspaces.remove(folder.id)
                                } else {
                                    expandedWorkspaces.insert(folder.id)
                                }
                            } label: {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(isCurrent ? Theme.accent : Color.secondary)
                                    .frame(width: 18, height: 24)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(isExpanded ? "Collapse workspace" : "Expand workspace")

                            WorkspaceRow(
                                folder: folder,
                                // Collapsed, the card carries the lit state of
                                // whatever is inside it, because none of it is
                                // on screen to carry its own. Expanded, one of
                                // the section rows is the lit one and two
                                // accent bars in the same group is the bug the
                                // nested rows already avoid.
                                isSelected: isCurrent && !isExpanded,
                                isCurrent: isCurrent
                            ) { selectWorkspace(folder.id) }
                        }
                        .contextMenu {
                            if !folder.isRemote {
                                Button("Reveal in Finder", .reveal) { workspaces.revealInFinder(folder) }
                            }
                            Divider()
                            // "Remove" and not "Delete": the folder stays.
                            Button("Remove from tokenstat", .delete, role: .destructive) {
                                workspacePendingRemove = folder
                            }
                        }
                        .modifier(WorkspaceReorder(id: folder.id, enabled: workspaces.folders.count > 1) {
                            workspaces.moveWorkspace($0, before: folder.id)
                            workspaceDropBeforeID = nil
                        } onTargeted: { on in
                            if on {
                                workspaceDropBeforeID = folder.id
                            } else if workspaceDropBeforeID == folder.id {
                                workspaceDropBeforeID = nil
                            }
                        })
                        #else
                        SidebarRow(
                            label: folder.name,
                            symbol: folder.exists ? "folder" : "questionmark.folder",
                            trailing: folder.diffStat,
                            isSelected: route.workspaceID == folder.id
                        ) { selectWorkspace(folder.id) }
                        .help(folder.path)
                        .contextMenu {
                            Divider()
                            // "Remove" and not "Delete": the folder stays.
                            Button("Remove from tokenstat", .delete, role: .destructive) {
                                workspacePendingRemove = folder
                            }
                        }
                        #endif

                        #if os(macOS)
                        if isExpanded {
                            // The same seven, in the same order, for every
                            // folder. Live things sit directly under the
                            // section that owns them, so a running workflow is
                            // found where workflows are and not in a pile at
                            // the bottom of the folder.
                            ForEach(WorkspaceSection.allCases) { section in
                                WorkspaceSectionRow(
                                    section: section,
                                    count: count(of: section, in: folder),
                                    isSelected: route == .workspace(id: folder.id, section: section)
                                ) {
                                    openSection(section, in: folder.id)
                                }
                                if section == .automations {
                                    ForEach(automations.liveJobs(in: folder.id)) { job in
                                        let run = automations.lastRun(for: job)
                                        ActiveAutomationRow(
                                            job: job,
                                            backendLabel: automations.backends
                                                .first { $0.id == job.backend }?.label ?? job.backend,
                                            isSelected: automations.selectedJobID == job.id
                                                && (route.isGlobal(.automations)
                                                    || route == .workspace(id: folder.id, section: .automations))
                                        ) {
                                            openAutomation(jobID: job.id, runID: run?.id, in: folder.id)
                                        }
                                    }
                                }
                                if section == .workflows {
                                    ForEach(workflows.liveRuns(in: folder.id)) { run in
                                        ActiveWorkflowRow(
                                            run: run,
                                            isSelected: workflows.selectedRunID == run.id
                                                && (route.isGlobal(.workflows)
                                                    || route == .workspace(id: folder.id, section: .workflows))
                                        ) {
                                            openWorkflow(graphID: run.workflowID, runID: run.id, in: folder.id)
                                        }
                                    }
                                }
                                if section == .sessions {
                                    sessionRows(activeSessions, in: folder, showingTerminal: showingTerminal)
                                }
                            }
                        }
                        #endif
                    }
                    #if os(macOS)
                    if workspaceDropBeforeID == WorkspaceDrag.end {
                        workspaceInsertionLine
                    }
                    #endif
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
                .modifier(WorkspaceReorder(id: WorkspaceDrag.end, canDrag: false, enabled: workspaces.folders.count > 1) {
                    workspaces.moveWorkspace($0, before: nil)
                    workspaceDropBeforeID = nil
                } onTargeted: { on in
                    if on {
                        workspaceDropBeforeID = WorkspaceDrag.end
                    } else if workspaceDropBeforeID == WorkspaceDrag.end {
                        workspaceDropBeforeID = nil
                    }
                })
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
        // Confirm lives on the sidebar column, not RootView's outer body chain,
        // so the type checker can still finish the main chrome expression.
        .background {
            RemoveWorkspaceConfirm(
                folder: $workspacePendingRemove,
                remove: { folder in
                    Task { await workspaces.remove(folder) }
                }
            )
        }
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
            HostStatusCard()
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
            accountRow
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.sidebar)
    }

    /// Who is signed in: the row as drawn, with a real menu over it.
    ///
    /// The row is deliberately **not** a `Menu`'s label. A macOS `Menu` does
    /// not host a custom label so much as rebuild it: artwork is lifted out
    /// and repainted as the control's own image across the whole button, which
    /// is how a 22 point circle became a full-width photograph of the account
    /// holder; a placeholder view left in its place is dropped, so the name
    /// slid under the picture; and the label is measured with no width to work
    /// with, so the row shrink-wrapped to the name and floated in the middle
    /// of the sidebar. Fixed frames, a clear host, `.clipped()`,
    /// `.fixedSize()`, a measured width and dropping `AsyncImage` all failed
    /// for one reason: each constrains a view the menu had already stopped
    /// laying out.
    ///
    /// So the row is an ordinary view, laid out by the ordinary rules, and the
    /// menu is a real `NSMenu` popped from the row itself. The whole row stays
    /// one click target, and the picture is a picture.
    private var accountRow: some View {
        #if os(macOS)
        ZStack(alignment: .leading) {
            accountLabel
            NativeMenuTrigger(items: { accountMenuItems })
        }
        .frame(height: accountRowHeight)
        #else
        Menu {
            accountMenuContent
        } label: {
            accountLabel
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
    }

    #if os(macOS)
    /// The account menu, as data. Rebuilt on every press, so "Sync now" and
    /// the update check reflect what is happening at the moment it opens.
    private var accountMenuItems: [NativeMenuItem] {
        let checkUpdates = NativeMenuItem(
            appUpdate.isChecking ? "Checking for updates…" : "Check for updates",
            isEnabled: !appUpdate.isChecking
        ) {
            Task { await appUpdate.checkNow() }
        }
        guard account.signedIn else {
            return [
                NativeMenuItem("Sign in to tokenstat.ai") {
                    navigate(to: .global(.account))
                    account.signIn()
                },
                .separator,
                NativeMenuItem("Account") { navigate(to: .global(.account)) },
                .separator,
                checkUpdates,
            ]
        }
        return [
            NativeMenuItem("Account settings") { navigate(to: .global(.account)) },
            NativeMenuItem(
                "Sync now",
                isEnabled: !account.isSyncing && account.syncCooldownUntil == nil
            ) {
                Task { await account.sync() }
            },
            .separator,
            checkUpdates,
            .separator,
            NativeMenuItem("Sign out") { Task { await account.signOut() } },
        ]
    }
    #else
    @ViewBuilder
    private var accountMenuContent: some View {
        if account.signedIn {
            Button("Account settings", .settings) { navigate(to: .global(.account)) }
            Button("Sync now", .refresh) { Task { await account.sync() } }
                .disabled(account.isSyncing || account.syncCooldownUntil != nil)
            Divider()
            updateItem
            Divider()
            Button("Sign out", .signOut) { Task { await account.signOut() } }
        } else {
            Button("Sign in to tokenstat.ai", .signIn) {
                navigate(to: .global(.account))
                account.signIn()
            }
            Divider()
            Button("Account", .account) { navigate(to: .global(.account)) }
            Divider()
            updateItem
        }
    }

    /// Check for an update, because somebody asked.
    ///
    /// The app already checks on launch, off the main actor and without saying
    /// anything, and installs what it finds. That is the right default and it
    /// is also invisible, so there is no way to answer "am I on the latest
    /// version" without one of these. The launch check stays exactly as it was.
    private var updateItem: some View {
        Button(appUpdate.isChecking ? "Checking for updates…" : "Check for updates", .refresh) {
            Task { await appUpdate.checkNow() }
        }
        .disabled(appUpdate.isChecking)
    }
    #endif

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
                size: Self.accountAvatarSize
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
        .frame(maxWidth: .infinity, maxHeight: accountRowHeight, alignment: .leading)
    }

    /// One footer row. Fixed so nothing drawn inside can grow the sidebar's
    /// bottom inset, and shared by the menu and the picture drawn over it so
    /// the two cannot drift apart.
    private var accountRowHeight: CGFloat { 36 }

    /// The footer picture's diameter, and the width of the seat the label
    /// leaves for it.
    private static let accountAvatarSize: CGFloat = 22

    // MARK: - Detail

    /// Whether the centre pane is the workspace surface itself.
    ///
    /// Tasks, Workflows and Automations are the same screens as their global
    /// versions with a folder's worth of rows in them, so they are drawn where
    /// those are drawn rather than as a fourth thing inside the terminal pane.
    private var showsWorkspaceSurface: Bool {
        switch route.workspaceSection {
        case .sessions, .changes, .files, .browser: return true
        case .todo, .workflows, .automations, nil: return false
        }
    }

    @ViewBuilder
    private var detail: some View {
        #if os(macOS)
        // Keep WorkspacesView mounted for the life of the window. Destination
        // used to be a switch that destroyed the whole tree on every leave:
        // Home (or Insights, Account, …) then back left every TerminalView
        // re-parented into a fresh TerminalStack, and SwiftTerm does not
        // reliably redraw its buffer after that (blank pane, only a caret,
        // until the process prints again). Switching sessions *inside*
        // workspaces stayed solid because TerminalStack never tore them
        // down. Same rule at this level: hide the surface, do not destroy it.
        ZStack {
            WorkspacesView(
                model: workspaces,
                terminals: terminals,
                isActive: showsWorkspaceSurface
            )
            .opacity(showsWorkspaceSurface ? 1 : 0)
            .allowsHitTesting(showsWorkspaceSurface)
            .accessibilityHidden(!showsWorkspaceSurface)
            .zIndex(showsWorkspaceSurface ? 1 : 0)

            if !showsWorkspaceSurface {
                nonWorkspaceDetail
                    .zIndex(1)
            }
        }
        #else
        if showsWorkspaceSurface {
            WorkspacesView(model: workspaces)
        } else {
            nonWorkspaceDetail
        }
        #endif
    }

    /// Every destination except the workspace surface. On macOS the workspace
    /// surface is kept mounted separately so its terminals are not destroyed.
    @ViewBuilder
    private var nonWorkspaceDetail: some View {
        switch route {
        case .workspace(_, .sessions), .workspace(_, .changes),
             .workspace(_, .files), .workspace(_, .browser):
            EmptyView()
        case .global(.home):
            HomeView(
                model: home,
                account: account,
                onShowAccount: { navigate(to: .global(.account)) }
            )
        case .workspace(_, .automations), .global(.automations):
            AutomationsView(
                model: automations,
                folders: workspaces.folders,
                onNavigate: { handle($0) },
                pendingRunID: $pendingRunID
            )
        case .workspace(_, .workflows), .global(.workflows):
            WorkflowsView(
                model: workflows,
                folders: workspaces.folders
            )
        case .workspace(_, .todo), .global(.todo):
            TodoView(
                model: todo,
                folders: workspaces.folders,
                onViewRun: { runID in
                    navigate(to: .global(.automations))
                    pendingRunID = runID
                    isInspectorPresented = true
                },
                onRunInFront: { launch in
                    launchTaskInFront(launch)
                }
            )
        case .global(.machines):
            MachinesView(model: machines)
        case .global(.account):
            AccountView(model: account)
        case .global(.insights):
            InsightsView(model: model) {
                // The back arrow exists only for a day that came from Home, so
                // the round trip has to end there too: clear the day filter
                // and put Home back in front.
                model.clearFocusedDay()
                navigate(to: .global(.home))
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

        await automations.load()
        guard !Task.isCancelled else { return }
        await workflows.load()
    }

    /// Open a graph on Workflows, with its run in the inspector when we have
    /// one. A run clicked under a folder opens on that folder's board.
    private func openWorkflow(graphID: String, runID: String?, in folderID: String? = nil) {
        navigate(to: folderID.map { .workspace(id: $0, section: .workflows) } ?? .global(.workflows)) {
            workflows.selectGraph(graphID)
            if let runID, let run = workflows.runs.first(where: { $0.id == runID }) {
                workflows.selectRun(run)
            }
            isInspectorPresented = true
        }
    }

    /// Open a job on Automations, with its run in the inspector when we have
    /// one. A job clicked under a folder opens on that folder's board.
    private func openAutomation(jobID: String, runID: String?, in folderID: String? = nil) {
        navigate(to: folderID.map { .workspace(id: $0, section: .automations) } ?? .global(.automations)) {
            automations.selectJob(jobID)
            if let runID, let run = automations.runs.first(where: { $0.id == runID }) {
                automations.selectRun(run)
            }
            pendingRunID = runID
            isInspectorPresented = true
        }
    }

    /// Interactive TTY for a task. Not an automation run: no transcript, no
    /// delegate badge. Opens the workspace terminal so the person can watch.
    private func launchTaskInFront(_ launch: InteractiveTaskLaunch) {
        #if os(macOS)
        guard let folder = workspaces.folders.first(where: { $0.id == launch.workspaceID }) else {
            todo.errorMessage = "Choose a workspace first."
            return
        }
        Task {
            do {
                let argv = try await Bridge.automationInteractiveCommand(
                    backend: launch.backend,
                    prompt: launch.prompt,
                    model: launch.model,
                    effort: launch.effort
                )
                guard let command = argv.first else {
                    todo.errorMessage = "The agent command was empty."
                    return
                }
                navigate(to: .workspace(id: folder.id, section: .sessions)) {
                    workspaces.selectedID = folder.id
                    workspaces.showTerminal(in: folder.id)
                    isInspectorPresented = true
                }
                let session = await terminals.start(
                    workspace: folder,
                    command: command,
                    args: Array(argv.dropFirst())
                )
                if session == nil {
                    todo.errorMessage = terminals.errorMessage
                        ?? "Could not start a terminal."
                    return
                }
                // OpenCode 2 seeds the prompt box but does not submit it.
                // Wait for first output (the TUI), then a short settle.
                if launch.backend == "opencode2", let session {
                    let deadline = Date().addingTimeInterval(5)
                    while session.showsStartingState, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    session.sendEnter()
                }
                todo.noticeOpenedInFront(launch.title)
            } catch {
                todo.errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    private var workspaceInsertionLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(height: 2)
            .padding(.horizontal, Theme.Space.m)
    }

    /// The live sessions of a folder, under its Sessions row.
    #if os(macOS)
    @ViewBuilder
    private func sessionRows(
        _ sessions: [TerminalSession],
        in folder: WorkspaceFolder,
        showingTerminal: Bool
    ) -> some View {
        ForEach(sessions) { session in
            ActiveSessionRow(
                session: session,
                // Selected only when this session is the one actually on
                // screen. `showingTerminal` carries the whole test, launcher
                // included: with the launch grid up, the pane is showing a
                // grid of tools and no session at all.
                isSelected: showingTerminal
                    && terminals.active(in: folder.id)?.id == session.id
            ) {
                openSection(.sessions, in: folder.id) {
                    terminals.select(session)
                }
            }
        }
    }
    #endif

    /// What a section's badge says. Nil draws nothing: a zero is not news, and
    /// seven greyed zeroes under every folder is a wall of them.
    private func count(of section: WorkspaceSection, in folder: WorkspaceFolder) -> Int? {
        // Cards, graphs and jobs on another machine are not in this app's
        // models, so a remote folder used to draw no badge for any of them.
        // Its owner counts them and says so in one call. Local folders keep
        // the in-memory count: it is instant, it is free, and it moves the
        // moment somebody adds a card rather than on the next poll.
        let remote = folder.isRemote ? workspaces.summary(for: folder.id) : nil
        let value: Int
        switch section {
        case .sessions: value = terminals.sessions(in: folder.id).filter(\.alive).count
        case .changes: value = folder.git?.files.count ?? 0
        case .todo: value = remote?.tasks ?? todo.openCount(in: folder.id)
        case .workflows:
            if let remote {
                value = remote.workflowsRunning > 0 ? remote.workflowsRunning : remote.workflows
            } else {
                value = workflows.count(in: folder.id)
            }
        case .automations: value = remote?.automations ?? automations.count(in: folder.id)
        case .files: return nil
        case .browser: value = workspaces.browserTabs(in: folder.id).count
        }
        return value > 0 ? value : nil
    }

    /// Open one of a folder's sections, and put the centre pane on it.
    ///
    /// The scoped screens (Tasks, Workflows, Automations) need nothing here:
    /// their scope is set in `navigate(to:)` with the route, so a screen
    /// cannot be showing one folder's cards under another folder's row.
    private func openSection(
        _ section: WorkspaceSection,
        in folderID: String,
        then update: (() -> Void)? = nil
    ) {
        navigate(to: .workspace(id: folderID, section: section)) {
            workspaces.selectedID = folderID
            lastSection[folderID] = section
            expandedWorkspaces.insert(folderID)
            isInspectorPresented = true
            #if os(macOS)
            switch section {
            case .sessions: workspaces.showTerminal(in: folderID)
            case .changes: workspaces.reviewWorkingTree(in: folderID)
            case .files: workspaces.showFiles(in: folderID)
            case .browser:
                // Back to the page you had open, rather than a second blank
                // tab every time the row is clicked.
                let existing = workspaces.tabs(in: folderID).last {
                    if case .browser = $0 { return true }
                    return false
                }
                if let existing {
                    workspaces.show(existing, in: folderID)
                } else {
                    workspaces.showBrowser(in: folderID)
                }
            case .todo, .workflows, .automations:
                break
            }
            #endif
            update?()
        }
    }

    /// Click the folder card: open it on whatever section it was left on, and
    /// show its sections.
    ///
    /// A second click on a folder already open on its sessions swaps between
    /// the running surface and the launcher, so a new agent can be started
    /// without hunting for the + menu.
    private func selectWorkspace(_ id: String) {
        let section = lastSection[id] ?? .sessions
        // Decided here rather than inside the transaction, because
        // `openSection` puts the sessions surface back on the way in. Asking
        // `toggleLauncher` afterwards asked what the navigation had just set
        // rather than what was on screen when the click happened, so every
        // click opened the launcher and none of them closed it.
        let wantsLauncher = route.workspaceID == id
            && section == .sessions
            && !workspaces.isShowingLauncher(in: id)
        openSection(section, in: id) {
            #if os(macOS)
            if wantsLauncher {
                workspaces.showLauncher(in: id)
            } else {
                // A first selection shows the folder as it was, not the
                // launcher it might have been left on.
                workspaces.exitLauncher(in: id)
            }
            #endif
        }
    }

    /// Go somewhere, and apply the state that arrival needs, in one
    /// un-animated transaction.
    ///
    /// Two state changes SwiftUI is free to animate separately are two things
    /// the user sees move at different times: the inspector visibly trailed
    /// the row it belongs to.
    private func navigate(to next: Route, update: (() -> Void)? = nil) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            route = next
            applyScope(from: next)
            update?()
        }
    }

    /// Scope follows the route in the same transaction, not on the next
    /// paint. `onChange(of: route)` runs after the first frame.
    private func applyScope(from next: Route) {
        let previous = todo.scope
        let nextID = next.workspaceID
        todo.scope = nextID
        automations.scope = nextID
        workflows.scope = nextID
        if previous != nextID {
            todo.dropOutOfScopeSelection()
            automations.dropOutOfScopeSelection()
            workflows.dropOutOfScopeSelection()
        }
    }

    /// Closing a Files, Changes or Browser chip puts sessions in front. The
    /// route has to follow or the sidebar stays on the section just closed.
    private func syncRouteToFront(_ front: WorkspaceSurface) {
        guard let id = route.workspaceID, let section = route.workspaceSection else { return }
        switch section {
        case .files, .changes, .browser:
            if front == .sessions || front == .launcher {
                lastSection[id] = .sessions
                navigate(to: .workspace(id: id, section: .sessions))
            }
        default:
            break
        }
    }

    /// Answer a `NavigationRequest` from a screen that does not know the shell.
    private func handle(_ request: NavigationRequest) {
        switch request {
        case let .global(section):
            navigate(to: .global(section))
        case .workspaces:
            guard let id = workspaces.selectedID ?? workspaces.folders.first?.id else { return }
            openSection(.sessions, in: id)
        case .launcher:
            guard let id = workspaces.selectedID ?? workspaces.folders.first?.id else { return }
            openSection(.sessions, in: id) {
                #if os(macOS)
                workspaces.showLauncher(in: id)
                #endif
            }
        }
    }
}

/// Workspace remove confirm, kept off RootView's main modifier chain so the
/// type checker can still finish the root body.
private struct RemoveWorkspaceConfirm: View {
    @Binding var folder: WorkspaceFolder?
    var remove: (WorkspaceFolder) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .confirmationDialog(
                "Remove from tokenstat?",
                isPresented: Binding(
                    get: { folder != nil },
                    set: { if !$0 { folder = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let folder {
                        remove(folder)
                    }
                    folder = nil
                }
                Button("Keep it", role: .cancel) {
                    folder = nil
                }
            } message: {
                Text(
                    "Remove \(folder?.name ?? "this folder") from the sidebar? The folder on disk is not deleted."
                )
            }
    }
}

#if os(macOS)
/// One entry in a menu popped by `NativeMenuTrigger`.
struct NativeMenuItem {
    enum Kind {
        case action
        case separator
    }

    let kind: Kind
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.kind = .action
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    private init() {
        kind = .separator
        title = ""
        isEnabled = false
        action = {}
    }

    static let separator = NativeMenuItem()
}

/// Pops a real `NSMenu` under whatever it is laid over.
///
/// For rows that must look exactly as designed. SwiftUI's `Menu` rebuilds a
/// custom label rather than hosting it (see `RootView.accountRow`), so a row
/// with a picture, a badge and a trailing chevron in it cannot survive being
/// that label. Here the row is drawn as an ordinary view and this sits on top
/// of it as the control: the menu is the system's own, with its keyboard
/// handling and its placement, and the row is untouched.
struct NativeMenuTrigger: NSViewRepresentable {
    /// Read at press time, not at build time, so item titles and enablement
    /// describe the moment the menu opens.
    var items: () -> [NativeMenuItem]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.items = items
        let view = TriggerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items
        (nsView as? TriggerView)?.coordinator = context.coordinator
    }

    /// Builds the menu and runs the chosen item.
    ///
    /// The target lives here rather than on the view because `NSMenuItem.target`
    /// is a **weak** reference: an owner AppKit does not retain can be gone by
    /// the time the menu closes, and then choosing an item does nothing at all.
    /// SwiftUI holds the coordinator for as long as the representable exists,
    /// which is exactly as long as the menu can be opened.
    final class Coordinator: NSObject {
        var items: (() -> [NativeMenuItem])?
        /// The set the open menu was built from. Items dispatch by index into
        /// this, so a closure never has to survive inside an AppKit object.
        private var current: [NativeMenuItem] = []

        func menu() -> NSMenu? {
            current = items?() ?? []
            guard !current.isEmpty else { return nil }

            let menu = NSMenu()
            // Our own enablement. Left on, AppKit asks a validator this app
            // does not have and greys every item out.
            menu.autoenablesItems = false
            for (index, entry) in current.enumerated() {
                switch entry.kind {
                case .separator:
                    menu.addItem(.separator())
                case .action:
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(run(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = index
                    item.isEnabled = entry.isEnabled
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func run(_ sender: NSMenuItem) {
            guard current.indices.contains(sender.tag) else { return }
            current[sender.tag].action()
        }
    }

    final class TriggerView: NSView {
        weak var coordinator: Coordinator?

        /// Menus drop from the bottom of the row, which is where a pop-up
        /// button puts them, and flipped coordinates make that `maxY`.
        override var isFlipped: Bool { true }

        /// Open on the click that also brings the window forward. Without
        /// this, pressing the row in a background window only activates it and
        /// the press has to be repeated.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let menu = coordinator?.menu() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        }
    }
}
#endif

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
/// Sizing shared by the workspace row and the session rows nested under it.
///
/// One place, because the two are read as a single surface: a folder and the
/// sessions inside it must share a leading tile size, a type scale and a
/// vertical rhythm, or the indent reads as a different list rather than as
/// the inside of this one.
///
/// The type scale is the platform's, not a chosen one. 13pt is the macOS
/// source list size, and the two lines under it step down to 11pt, which is
/// as small as text is allowed to go here. Larger reads as a settings pane
/// rather than a sidebar, and that is what a 14/12/11 stack looked like.
private enum RowMetrics {
    /// The leading brand or folder tile.
    static let mark: CGFloat = 26
    /// Line one: the name.
    static let title: CGFloat = 13
    /// Lines two and three: git summary, then state.
    static let meta: CGFloat = 11
    /// Between the three lines. Tight: they are one block of text about one
    /// thing, not three separate facts.
    static let lineGap: CGFloat = 2
    /// Above and below the text block.
    static let rowPadding: CGFloat = 6
    /// The state dot.
    static let dot: CGFloat = 7
}

/// Dot plus word: what a session is doing right now.
///
/// Working is the accent in both the dot and the label, so the one row that
/// matters is the one carrying colour. Everything else is grey, because a
/// sidebar where four states all shout is a sidebar with no state at all.
private struct StateBadge: View {
    let state: SessionState
    /// When the session last produced output.
    ///
    /// Shown for an idle session and nowhere else. "Idle" alone leaves the
    /// one question it raises unanswered, which is *how long*: an agent quiet
    /// for eight seconds is thinking, one quiet for an hour is waiting for
    /// you. On a working session the answer is always "just now", so the
    /// clock would be noise that redraws every second.
    var since: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var tint: Color {
        switch state {
        case .working: return Theme.stateWorking
        case .starting: return Theme.stateWorking.opacity(0.5)
        case .needsAttention: return Theme.warning
        case .stopped: return Theme.danger
        case .idle, .none: return Theme.stateIdle
        }
    }

    private var label: String {
        switch state {
        case .none: return "No sessions"
        case .working: return "Working"
        case .starting: return "Starting"
        case .idle: return "Idle"
        case .needsAttention: return "Needs attention"
        case .stopped: return "Stopped"
        }
    }

    /// Working and attention carry colour. Everything else stays grey so
    /// the one row that needs a person is the one that draws the eye.
    private var labelStyle: AnyShapeStyle {
        switch state {
        case .working: return AnyShapeStyle(Theme.stateWorking)
        case .needsAttention: return AnyShapeStyle(Theme.warning)
        default: return AnyShapeStyle(.tertiary)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if state != .none {
                Circle()
                    .fill(tint)
                    .frame(width: RowMetrics.dot, height: RowMetrics.dot)
                    // Only the live state breathes, and only when the system
                    // allows motion. A pulsing dot on an idle row would be
                    // movement that means nothing.
                    .opacity(pulsing ? 0.45 : 1)
                    .onAppear { startPulse() }
                    .onChange(of: state) { _, _ in startPulse() }
            }
            Text(label)
                .font(.system(size: DisplayFit.dp(RowMetrics.meta)))
                .foregroundStyle(labelStyle)
                .lineLimit(1)
            if state == .idle, let since {
                Text("·").font(.system(size: DisplayFit.dp(RowMetrics.meta))).foregroundStyle(.quaternary)
                // One shared tick, not a live time source per row. SwiftUI
                // does keep `Text(_, style: .relative)` current on its own,
                // and the price is a full window layout pass every frame for
                // as long as one is on screen. See `RelativeClock`.
                RelativeTimeText(date: since, unitsStyle: .short)
                    .font(Theme.numeric(RowMetrics.meta))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func startPulse() {
        guard state == .working, !reduceMotion else {
            pulsing = false
            return
        }
        pulsing = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

/// Prefix so a Finder path drop cannot be mistaken for a sidebar move.
private enum WorkspaceDrag {
    static let prefix = "tokenstat.workspace:"
    static let end = "__end__"

    static func payload(_ id: String) -> String { prefix + id }

    static func id(from payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        return String(payload.dropFirst(prefix.count))
    }
}

/// Drag a workspace row, and accept another row dropped onto it.
private struct WorkspaceReorder: ViewModifier {
    let id: String
    var canDrag: Bool = true
    let enabled: Bool
    let onDrop: (String) -> Void
    let onTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if canDrag {
            drop(on: content)
                .draggable(WorkspaceDrag.payload(id)) {
                    Text((id as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                }
        } else {
            drop(on: content)
        }
    }

    private func drop(on content: Content) -> some View {
        content.dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let dragged = WorkspaceDrag.id(from: payload),
                  dragged != id else { return false }
            onDrop(dragged)
            return true
        } isTargeted: { on in
            onTargeted(on)
        }
    }
}

/// A workspace in the sidebar: a folder mark, its name, and where its
/// checkout stands.
///
/// The folder mark is deliberate. This row names a workspace, and the sessions
/// underneath it carry the harness marks, so the folder reads as the container
/// it is rather than pretending to be an agent.
///
/// Two lines, and no working state. A folder does not work, the shells inside
/// it do, and each of those says so on its own row. Folding their states into
/// one word here only restated what was already visible one row below, and it
/// put a live indicator on something that is really just a place.
///
/// No path line either. It made every row taller than the thing it described
/// and pushed the second workspace off the top of a short sidebar. The path is
/// in the tooltip, where it belongs: it is what you check once when adding a
/// folder, not what you read every time you switch to one.
private struct WorkspaceRow: View {
    let folder: WorkspaceFolder
    /// This row is what the centre pane is showing: the workspace itself,
    /// with no terminal in front of it. Only then does the row take the fill
    /// and the accent bar.
    let isSelected: Bool
    /// The workspace is the open one, whatever is in front of it. Carries a
    /// tinted mark and a heavier name, and nothing louder, so that a selected
    /// session below can be the only lit row.
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var label: String {
        folder.isRemote
            ? "\(folder.machineLabel ?? "Remote") / \(folder.name)"
            : folder.name
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                leadingMark
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(label)
                        .font(.system(
                            size: DisplayFit.dp(RowMetrics.title),
                            weight: isCurrent ? .semibold : .regular
                        ))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    gitLine
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(folder.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label). \(folder.subtitle ?? "No branch")")
    }

    /// Line two, in pieces rather than as one string.
    ///
    /// The counts carry the diff colours, which is the whole reason this is
    /// not a `Text`. As one grey line, `main ⇡2 +535 −46` reads as a serial
    /// number: nothing in it says which number is which without being read
    /// word by word. Numeric face throughout, so a count ticking over does
    /// not shift the line sideways.
    @ViewBuilder
    private var gitLine: some View {
        let font = Theme.numeric(RowMetrics.meta)
        if let git = folder.git, git.isRepo {
            HStack(spacing: 5) {
                // The same glyph the session rows use. Without it the branch
                // is a bare word in a line of numbers, and `main +562 −46`
                // reads as though `main` were another count.
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: DisplayFit.dp(RowMetrics.meta - 1), weight: .medium))
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
                    // The counts are a floor when some file could not be
                    // counted, and a trailing `+` is how the rest of the app
                    // already says so.
                    if git.partial {
                        Text("+").font(font).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
        } else {
            Text(folder.subtitle ?? "No branch")
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var leadingMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: RowMetrics.mark * 0.28, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.18) : Theme.accent.opacity(0.09))
            Image(
                systemName: folder.isRemote
                    ? "network"
                    : (folder.exists ? "folder.fill" : "questionmark.folder.fill")
            )
            .font(.system(size: DisplayFit.dp(RowMetrics.mark * 0.5), weight: .medium))
            .foregroundStyle(isCurrent ? Theme.accent : Theme.accent.opacity(0.6))
        }
        .frame(width: DisplayFit.dp(RowMetrics.mark), height: DisplayFit.dp(RowMetrics.mark))
    }

    /// Same selection treatment as the destination rows: tinted fill plus a
    /// leading accent bar, with hover as a plain grey wash.
    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.rowSelected
                        : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
                )
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        // A hairline between adjacent rows. Without it two selected cards, or
        // a card and the session under it, share an edge and read as one tall
        // shape rather than as two things.
        .padding(.vertical, 1)
    }
}

/// A sidebar group heading, with an optional disclosure and trailing control.
///
/// One component for both headings, because they are the same object: a
/// tertiary uppercase label at the sidebar's own rhythm. Two hand-rolled
/// `HStack`s is how the second one ends up 2pt off the first.
private struct SidebarGroupHeader<Trailing: View>: View {
    let title: String
    var count: Int?
    /// Nil for a heading that does not fold. The chevron is then absent
    /// rather than drawn and inert.
    let isExpanded: Bool?
    let toggle: () -> Void
    @ViewBuilder var trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Group {
                if let isExpanded {
                    Button(action: toggle) {
                        header(chevron: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering = $0 }
                    .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
                } else {
                    header(chevron: nil)
                }
            }
            trailing
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
    }

    private func header(chevron: String?) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isHovering ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: 8)
            }
            SectionLabel(text: title, count: count)
        }
        .contentShape(.rect)
    }
}

extension SidebarGroupHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, isExpanded: Bool?, toggle: @escaping () -> Void) {
        self.init(title: title, count: count, isExpanded: isExpanded, toggle: toggle) {
            EmptyView()
        }
    }
}

/// One of a workspace's sections, indented under its folder card.
///
/// Deliberately lighter than everything around it. The folder card above is a
/// 26pt mark and three lines, and the live rows below are cards of their own,
/// so a section has to read as the label between them rather than as a third
/// kind of object: one line, one small glyph, one count.
///
/// The rail is what says "inside". Each row draws its own segment, so the run
/// of them looks continuous, and the selected row's segment is the accent.
/// That is the selection mark here: a 3pt bar beside a 1pt rail is two edges
/// arguing, and the folder card already owns the bar when it is collapsed.
private struct WorkspaceSectionRow: View {
    let section: WorkspaceSection
    /// Nil draws nothing. A zero is not news, and seven greyed zeroes under
    /// every folder is a wall of them.
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    /// Where the rail sits, and where the content starts after it.
    private static let railInset: CGFloat = Theme.Space.l

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: section.symbol)
                    .font(.system(size: DisplayFit.dp(10.5)))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 14)
                Text(section.label)
                    .font(.system(
                        size: DisplayFit.dp(12),
                        weight: isSelected ? .medium : .regular
                    ))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if let count {
                    Text("\(count)")
                        .font(Theme.numeric(11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        .monospacedDigit()
                }
            }
            .padding(.leading, Self.railInset + Theme.Space.s)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, 3)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(section.label)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(section.label), \($0)" } ?? section.label)
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.rowSelectedNested
                        : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
                )
                .padding(.leading, Self.railInset)
                .padding(.trailing, Theme.Space.xs)
            Rectangle()
                .fill(isSelected ? Theme.accent : Theme.border)
                .frame(width: 1)
                .padding(.leading, Self.railInset)
        }
    }
}

/// A live workflow run, drawn under the workspace it is bound to.
private struct ActiveWorkflowRow: View {
    let run: WorkflowRunRecord
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_workflow", tint: Theme.accent, size: DisplayFit.dp(RowMetrics.mark))
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(run.name)
                        .font(.system(
                            size: DisplayFit.dp(RowMetrics.title),
                            weight: isSelected ? .semibold : .regular
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(run.steps.count) steps")
                        .font(Theme.numeric(RowMetrics.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StateBadge(state: run.isWaiting ? .needsAttention : .working)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open this running workflow")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.name). \(run.endedLabel)")
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.rowSelected
                        : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
                )
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

/// A live automation, drawn under the workspace it is running in.
///
/// Automation ptys are hidden from the terminal list on purpose. This row is
/// how a job that is already going (Auto commit especially) stays visible
/// without opening the Automations screen first.
private struct ActiveAutomationRow: View {
    let job: Automation
    let backendLabel: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_automation", tint: Theme.accent, size: DisplayFit.dp(RowMetrics.mark))
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(job.name)
                        .font(.system(
                            size: DisplayFit.dp(RowMetrics.title),
                            weight: isSelected ? .semibold : .regular
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(backendLabel)
                        .font(Theme.numeric(RowMetrics.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StateBadge(state: .working)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open this running job")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.name). \(backendLabel). Working")
    }

    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.rowSelected
                        : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
                )
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

/// A running session, drawn inside the workspace it belongs to.
///
/// Three lines: what it is, what it is costing, and whether it is working.
/// This is the row that carries the live state, because this is the thing that
/// is alive. The folder above it is a place, and a place is never busy.
///
/// The folder name and the path are both absent on purpose. The row sits
/// directly beneath its folder, so repeating either says nothing and costs a
/// line.
private struct ActiveSessionRow: View {
    let session: TerminalSession
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    /// Line one: what was launched.
    ///
    /// The harness name, not the shell title. A harness rewrites its title as
    /// it works ("✳ Claude Code", then whatever it is thinking about), so a
    /// row keyed on it renamed itself every few seconds and the list you were
    /// reading moved under you. What you picked from the launcher does not
    /// change, so that is what names the row.
    private var title: String {
        if let harnessID = session.harnessID { return harnessName(harnessID) }
        return (session.command as NSString).lastPathComponent
    }

    /// The harness's own title, when it is saying something the row does not
    /// already say. This is where a session that is called something else
    /// gets to be called that.
    /// Containment tested both ways. A harness whose title is "grok" under a
    /// row named "Grok Build" passes a one-way test and then prints a word
    /// the row above it already said.
    private var dynamicTitle: String? {
        guard let reported = session.title?.trimmingCharacters(in: .whitespaces),
              !reported.isEmpty,
              !reported.localizedCaseInsensitiveContains(title),
              !title.localizedCaseInsensitiveContains(reported)
        else { return nil }
        return reported
    }

    /// Line two: what this session is costing.
    ///
    /// List-rate dollars and a short token total when the host meter has
    /// spoken. CPU · RAM stay as the fallback, and move to the tooltip
    /// once the meter lands. `nil` before either reading, so a row never
    /// invents a zero.
    private var stats: String? {
        if let meter = session.meter {
            var parts: [String] = []
            if let micros = meter.costMicros, micros > 0 {
                parts.append(
                    Money(
                        micros: micros,
                        estimated: meter.estimated,
                        complete: meter.complete
                    ).formatted
                )
            }
            if meter.tokens > 0 {
                parts.append(formatTokens(meter.tokens))
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return resourceStats
    }

    /// CPU and RAM, for the tooltip and as the line-two fallback.
    private var resourceStats: String? {
        var parts: [String] = []
        if let cpu = session.cpuPercent {
            parts.append("CPU \(Int(cpu.rounded()))%")
        }
        if let memory = session.memoryMb, memory >= 1 {
            // Gigabytes past a thousand: an agent with a language server and
            // a test run under it reaches four digits, and "3.4 GB" is read
            // at a glance where "3421 MB" is counted.
            parts.append(
                memory >= 1000
                    ? String(format: "%.1f GB", memory / 1024)
                    : "\(Int(memory.rounded())) MB"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines = [session.cwd]
        if session.meter != nil, let resources = resourceStats {
            lines.append(resources)
        }
        if session.meter?.costMicros != nil {
            lines.append("List-rate equivalent, not billed.")
        }
        return lines.joined(separator: "\n")
    }

    private var spokenLabel: String {
        var parts = [title]
        if let stats { parts.append(stats) }
        if let meter = session.meter,
           let used = meter.contextUsed,
           let window = meter.contextWindow,
           window > 0
        {
            let pct = Int((Double(used) / Double(window) * 100).rounded())
            parts.append("context \(pct) percent")
        }
        parts.append(session.state.label)
        return parts.joined(separator: ". ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                leadingMark
                VStack(alignment: .leading, spacing: RowMetrics.lineGap) {
                    Text(title)
                        .font(.system(
                            size: DisplayFit.dp(RowMetrics.title),
                            weight: isSelected ? .semibold : .regular
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let used = session.meter?.contextUsed,
                       let window = session.meter?.contextWindow
                    {
                        SessionContextBar(used: used, window: window)
                    }
                    // The live numbers, or the harness's own title until the
                    // first reading lands. Never both: this is one line and
                    // the numbers are what change.
                    Text(stats ?? dynamicTitle ?? session.command)
                        .font(Theme.numeric(RowMetrics.meta))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StateBadge(state: session.state, since: session.lastOutputAt)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, RowMetrics.rowPadding)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var leadingMark: some View {
        if let harnessID = session.harnessID {
            HarnessMark(id: harnessID, size: DisplayFit.dp(RowMetrics.mark))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: RowMetrics.mark * 0.28, style: .continuous)
                    .fill(Theme.accent.opacity(0.09))
                Image(systemName: "terminal")
                    .font(.system(size: DisplayFit.dp(RowMetrics.mark * 0.46), weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.75))
            }
            .frame(width: DisplayFit.dp(RowMetrics.mark), height: DisplayFit.dp(RowMetrics.mark))
        }
    }

    /// The session, not its folder, carries the selection.
    ///
    /// What is on screen when a session is picked is that shell, so the tint
    /// and the accent bar belong here. The folder above it steps back to a
    /// tinted mark and a heavier name, which says "you are in this workspace"
    /// without claiming to be the thing being looked at. Both of them lit was
    /// two selections for one choice.
    private var background: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.rowSelected
                        : (isHovering ? Theme.rowHighlight.opacity(0.6) : .clear)
                )
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, 1)
    }
}

/// How full this session's context window is, when we know both sides.
///
/// Heat, not green. Near the window the fill turns warning, because that
/// is the moment a person should start a new session. Missing data draws
/// nothing: the caller already gated on both numbers.
private struct SessionContextBar: View {
    let used: UInt64
    let window: UInt64

    private var ratio: Double {
        guard window > 0 else { return 0 }
        return min(1, Double(used) / Double(window))
    }

    private var fill: Color {
        if ratio >= 0.85 { return Theme.warning }
        let idx = min(Theme.heat.count - 1, max(1, Int((ratio * 4).rounded(.up))))
        return Theme.heat[idx]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule()
                    .fill(fill)
                    .frame(width: max(2, geo.size.width * ratio))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
#endif

#endif  // os(macOS), the desktop shell
