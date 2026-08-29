// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

/// Reports window geometry to SwiftUI, and keeps AppKit chrome from fighting
/// a full-screen transition.
///
/// Two jobs, kept in one observer because both need the same `NSWindow`:
///
/// 1. **Geometry.** Content width and the titlebar band height, published
///    outside any layout pass so a hosted `NavigationSplitView` child cannot
///    change its min/max while AppKit is already updating constraints.
/// 2. **Full screen.** The traffic-light zoom button starts an AppKit display
///    cycle that resizes the hosted content view. With `.hiddenTitleBar` the
///    content view uses `fullSizeContentView`, so that resize also changes
///    safe-area insets. SwiftUI's `NSHostingView` then calls
///    `setNeedsUpdateConstraints` from `setFrameSize` during layout, and
///    AppKit aborts (`_postWindowNeedsUpdateConstraints`). Dropping
///    `fullSizeContentView` before that cycle, and not writing SwiftUI
///    bindings until after it, is what keeps the traffic-light zoom
///    button from crashing the app.
///
/// A third, smaller job: `NavigationSplitView` re-inserts its stock sidebar
/// toggle whenever the split collapses (a narrow window). `.toolbar(removing:
/// .sidebarToggle)` does not catch that rebuild, so the item is neutralised
/// on `willAddItem` and removed on the next turn.
struct WindowScreenObserver: NSViewRepresentable {
    @Binding var contentWidth: CGFloat
    @Binding var isFullScreen: Bool
    @Binding var titlebarInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            Task { @MainActor in
                coordinator?.attach(
                    to: window,
                    contentWidth: $contentWidth,
                    isFullScreen: $isFullScreen,
                    titlebarInset: $titlebarInset
                )
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated {
            context.coordinator.contentWidth = $contentWidth
            context.coordinator.isFullScreen = $isFullScreen
            context.coordinator.titlebarInset = $titlebarInset
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var pendingPublish: Task<Void, Never>?
        private var toggleStripWork: [DispatchWorkItem] = []
        /// True between willEnter/willExit and the matching didEnter/didExit.
        /// While set, no SwiftUI bindings are written and the toolbar is not
        /// mutated beyond the synchronous style-mask change.
        private var isFullScreenTransitioning = false
        var attachedWindow: NSWindow? { window }
        var contentWidth: Binding<CGFloat>?
        var isFullScreen: Binding<Bool>?
        var titlebarInset: Binding<CGFloat>?

        func attach(
            to window: NSWindow?,
            contentWidth: Binding<CGFloat>,
            isFullScreen: Binding<Bool>,
            titlebarInset: Binding<CGFloat>
        ) {
            self.contentWidth = contentWidth
            self.isFullScreen = isFullScreen
            self.titlebarInset = titlebarInset
            guard self.window !== window else {
                schedulePublish()
                return
            }
            detach()
            guard let window else { return }
            self.window = window
            observe(window)
            updateDisplayAndClamp(window)
            stripSystemSidebarToggle(in: window)
            hideEmptyAppToolbar(on: window)
            scheduleSidebarToggleStrip(for: window)
            schedulePublish()
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default

            // Geometry. Skipped entirely during a full-screen transition: a
            // resize notification in that window is AppKit's animation, and
            // publishing titlebarInset from it is what re-entered layout.
            for name: Notification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
            ] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    self?.onMain {
                        guard let self, let window, self.window === window else { return }
                        guard !self.isFullScreenTransitioning else { return }
                        self.schedulePublish()
                    }
                })
            }

            observers.append(center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMain {
                    guard let self, let window, self.window === window else { return }
                    guard !self.isFullScreenTransitioning else { return }
                    self.updateDisplayAndClamp(window)
                    self.schedulePublish()
                }
            })

            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMain {
                    guard let self, let window, self.window === window else { return }
                    guard !self.isFullScreenTransitioning else { return }
                    self.updateDisplayAndClamp(window)
                    self.schedulePublish()
                }
            })

            // Full screen. willEnter/willExit run synchronously on the main
            // queue: wrapping them in `Task` hops a turn, which is after
            // AppKit has already started the layout cycle we have to finish
            // preparing for.
            observers.append(center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMainSync {
                    guard let self, let window, self.window === window else { return }
                    self.prepareFullScreen(window, entering: true)
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMain {
                    guard let self, let window, self.window === window else { return }
                    self.finishFullScreen(window, entered: true)
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMainSync {
                    guard let self, let window, self.window === window else { return }
                    self.prepareFullScreen(window, entering: false)
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.onMain {
                    guard let self, let window, self.window === window else { return }
                    self.finishFullScreen(window, entered: false)
                }
            })

            // Neutralise the stock toggle before it is inserted, so it
            // cannot paint a second sidebar mark next to the traffic lights.
            observers.append(center.addObserver(
                forName: NSToolbar.willAddItemNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.onMainSync {
                    self?.toolbarWillAddItem(note)
                }
            })
        }

        /// Drop or restore `fullSizeContentView` before the transition layout.
        ///
        /// Entering: the mask is what makes `NSHostingView.setFrameSize`
        /// invalidate safe-area insets during the animation. Leaving: put it
        /// back so windowed chrome can share the traffic-light row again.
        /// Style mask only. Do not walk the view tree, do not hide the
        /// toolbar, do not write SwiftUI state here.
        private func prepareFullScreen(_ window: NSWindow, entering: Bool) {
            isFullScreenTransitioning = true
            pendingPublish?.cancel()
            pendingPublish = nil
            if entering {
                if window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.remove(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = false
            } else {
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            revealTrafficLights(on: window)
        }

        private func finishFullScreen(_ window: NSWindow, entered: Bool) {
            isFullScreenTransitioning = false
            if entered {
                // SwiftUI's hidden-title-bar style can put the mask back on
                // a later pass. Keep it off while full screen.
                if window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.remove(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = false
            } else {
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            revealTrafficLights(on: window)
            stripSystemSidebarToggle(in: window)
            hideEmptyAppToolbar(on: window)
            scheduleSidebarToggleStrip(for: window)
            schedulePublish()
        }

        private func toolbarWillAddItem(_ note: Notification) {
            guard let window, let toolbar = window.toolbar else { return }
            guard note.object as? NSToolbar === toolbar else { return }
            guard let item = Self.item(from: note), Self.isSystemSidebarToggle(item) else {
                return
            }
            Self.neutraliseSidebarToggle(item)
            guard !isFullScreenTransitioning else { return }
            DispatchQueue.main.async { [weak self, weak toolbar] in
                guard let self, let toolbar else { return }
                self.removeSystemSidebarToggle(from: toolbar)
                if let window = self.window { self.hideEmptyAppToolbar(on: window) }
            }
        }

        /// Publish after the current display cycle, not on `Task.yield()`.
        /// A yield can resume inside the next `NSDisplayCycleFlush`.
        private func schedulePublish() {
            guard !isFullScreenTransitioning else { return }
            pendingPublish?.cancel()
            pendingPublish = Task { @MainActor [weak self] in
                await Self.afterDisplayCycle()
                guard !Task.isCancelled, let self, !self.isFullScreenTransitioning else { return }
                guard let window = self.window else { return }
                self.publish(from: window)
            }
        }

        private func publish(from window: NSWindow) {
            let width = quantised(window.contentLayoutRect.width, step: 4)
            if contentWidth?.wrappedValue != width { contentWidth?.wrappedValue = width }

            let fullScreen = window.styleMask.contains(.fullScreen)
            if isFullScreen?.wrappedValue != fullScreen { isFullScreen?.wrappedValue = fullScreen }

            let inset: CGFloat
            if fullScreen {
                // Full screen content sits below a real titlebar. A measured
                // band here would pull DetailChromeBar up into AppKit's bar,
                // which is the same overlap that crashed on the way in.
                inset = 0
            } else if let contentView = window.contentView {
                let layout = contentView.convert(window.contentLayoutRect, from: nil)
                inset = max(0, contentView.bounds.maxY - layout.maxY)
            } else {
                inset = 0
            }
            let stableInset = (inset * 2).rounded() / 2
            if titlebarInset?.wrappedValue != stableInset { titlebarInset?.wrappedValue = stableInset }
        }

        private func updateDisplayAndClamp(_ window: NSWindow) {
            DisplayFit.update(screen: window.screen)
            guard !isFullScreenTransitioning else { return }
            guard !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: false) }
        }

        private func stripSystemSidebarToggle(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            removeSystemSidebarToggle(from: toolbar)
        }

        private func removeSystemSidebarToggle(from toolbar: NSToolbar) {
            var index = 0
            while index < toolbar.items.count {
                if Self.isSystemSidebarToggle(toolbar.items[index]) {
                    toolbar.removeItem(at: index)
                } else {
                    index += 1
                }
            }
        }

        /// Hide the system toolbar when it has no app items left.
        ///
        /// App controls live in `DetailChromeBar`. An empty NSToolbar host
        /// still occupies a content band next to the traffic lights, which is
        /// the blank row the chrome then has to climb into. Visibility only:
        /// do not change toolbar style. Traffic lights are standard window
        /// buttons, not toolbar items, but hiding the host can hide them as a
        /// side effect, so they are re-shown after.
        private func hideEmptyAppToolbar(on window: NSWindow) {
            guard !isFullScreenTransitioning, let toolbar = window.toolbar else { return }
            let hasAppItem = toolbar.items.contains { !Self.isSystemSidebarToggle($0) }
            toolbar.isVisible = hasAppItem
            revealTrafficLights(on: window)
        }

        private func revealTrafficLights(on window: NSWindow) {
            for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(buttonType) {
                    button.isHidden = false
                    button.alphaValue = 1
                }
            }
        }

        /// SwiftUI rebuilds the toolbar after first paint and when the split
        /// collapses. Strip again on a few follow-up turns so a re-inserted
        /// stock item does not stick on a narrow window.
        private func scheduleSidebarToggleStrip(for window: NSWindow) {
            toggleStripWork.forEach { $0.cancel() }
            toggleStripWork.removeAll()
            for delay in [0.05, 0.2, 0.6, 1.2] {
                let work = DispatchWorkItem { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    guard !self.isFullScreenTransitioning else { return }
                    self.stripSystemSidebarToggle(in: window)
                    self.hideEmptyAppToolbar(on: window)
                    self.schedulePublish()
                }
                toggleStripWork.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        private func quantised(_ value: CGFloat, step: CGFloat) -> CGFloat {
            (value / step).rounded() * step
        }

        private func detach() {
            pendingPublish?.cancel()
            pendingPublish = nil
            toggleStripWork.forEach { $0.cancel() }
            toggleStripWork.removeAll()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            isFullScreenTransitioning = false
            window = nil
        }

        deinit {
            pendingPublish?.cancel()
            toggleStripWork.forEach { $0.cancel() }
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Run `body` on the main actor. Uses a Task hop when the caller is
        /// not already on the main thread. `nonisolated` so a notification
        /// callback can call it without already being on the actor.
        nonisolated private func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(body)
            } else {
                Task { @MainActor in body() }
            }
        }

        /// Like `onMain`, but never hops. Full-screen willEnter/willExit must
        /// finish before the callback returns.
        nonisolated private func onMainSync(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(body)
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated(body)
                }
            }
        }

        private static func afterDisplayCycle() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }

        private static func item(from note: Notification) -> NSToolbarItem? {
            if let item = note.userInfo?[NSToolbarUserInfoKey.itemKey] as? NSToolbarItem {
                return item
            }
            return note.userInfo?["item"] as? NSToolbarItem
        }

        private static func isSystemSidebarToggle(_ item: NSToolbarItem) -> Bool {
            if item.itemIdentifier == .toggleSidebar { return true }
            let id = item.itemIdentifier.rawValue
            if id.localizedCaseInsensitiveContains("toggleSidebar") { return true }
            if id.localizedCaseInsensitiveContains("sidebar.toggle") { return true }
            if item.action == #selector(NSSplitViewController.toggleSidebar(_:)) { return true }
            return false
        }

        /// Make a stock toggle impossible to render before it is inserted.
        /// Size is zeroed so the toolbar does not keep a blank slot beside
        /// the traffic lights after the item is later removed.
        private static func neutraliseSidebarToggle(_ item: NSToolbarItem) {
            item.isEnabled = false
            item.image = nil
            item.label = ""
            item.toolTip = nil
            item.minSize = .zero
            item.maxSize = .zero
            if #available(macOS 15.0, *) {
                item.isHidden = true
                item.isBordered = false
            }
            item.view?.isHidden = true
            item.view?.frame = .zero
        }
    }
}

final class WindowReportingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
