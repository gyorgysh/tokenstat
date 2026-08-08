// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if os(macOS)
import AppKit

/// The one place this app needs AppKit's own launch order.
///
/// `applicationWillFinishLaunching` rather than the `App` initializer: moving
/// the bundle puts a question in front of the user, and a modal panel wants an
/// application that has finished waking up. It is also the last moment before
/// any window exists, so the copy that gets relaunched is the one that draws.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = AppRelocator.relocateIfNeeded()
        }
    }
}
#endif

#if os(macOS)
extension Notification.Name {
    /// Posted by the File menu, acted on by the window that owns the folders.
    static let addWorkspaceRequested = Notification.Name("ai.tokenstat.addWorkspaceRequested")
}
#endif

@main
struct TokenstatApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    /// Pick the transport before any view can call across it.
    ///
    /// In the initializer rather than in a `.task`, because a view that renders
    /// first would make its opening calls in-process and its later ones over
    /// the daemon, so the terminals a session starts with would belong to a
    /// different owner than the ones it ends with.
    init() {
        Bridge.connect()
        DesktopSyncScheduler.start()
        // The socket probe in `connect()` can miss a daemon that is still
        // coming up (or not installed yet), leaving the app in-process until
        // something fails. Catch up off the main thread so the first screen's
        // data load finds the daemon instead of an archive opened in this
        // process, and terminals belong to a process that outlives the window.
        Task.detached(priority: .userInitiated) {
            Bridge.ensureHosted()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The minimum is what the window needs *without* the
                // inspector, not with it. Asking for more than the user can
                // give does not enlarge the window, it overflows it, and the
                // pane that runs past the right edge is the one that gets cut.
                // The inspector closes itself below its own threshold instead.
                .frame(
                    minWidth: RootView.minimumContentWidth,
                    minHeight: RootView.minimumContentHeight
                )
        }
        #if os(macOS)
        // Unified toolbar and a hidden title give the rounded, chrome-light
        // window the plan asks for, without drawing custom window controls.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(Self.initialWindowSize)
        .commands {
            // Adding a folder is the app's "open", so it belongs in the File
            // menu with the shortcut people already try. The model that does
            // the work belongs to the window, so this posts and the window
            // acts, rather than the menu holding a second copy of the state.
            CommandGroup(after: .newItem) {
                Button("Add Workspace…") {
                    NotificationCenter.default.post(name: .addWorkspaceRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        #endif
    }

    #if os(macOS)
    /// The window's opening size, clamped to the display it opens on.
    ///
    /// 1260×825, a slightly wider-than-4:3 window in the shape of the other
    /// agentic desktop apps, clamped to the display it opens on: a window born
    /// wider or taller than its screen reads as one that does not fit. Start
    /// inside the visible frame and let the user make it bigger.
    ///
    /// At 1260 the fixed inspector column does not fit (its edge is 1450), so
    /// the default state is overlay mode: the pane floats in on hover rather
    /// than taking a column.
    private static var initialWindowSize: CGSize {
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(
            width: min(1260, frame.width * 0.94),
            height: min(825, frame.height * 0.90)
        )
    }
    #endif
}
