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

extension Notification.Name {
    #if os(macOS)
    /// Posted by the File menu, acted on by the window that owns the folders.
    static let addWorkspaceRequested = Notification.Name("ai.tokenstat.addWorkspaceRequested")
    /// View menu / ⌘B: toggle the leading sidebar. RootView acts.
    static let toggleLeftSidebar = Notification.Name("ai.tokenstat.toggleLeftSidebar")
    /// View menu / ⌥⌘B: toggle the trailing inspector. RootView acts.
    static let toggleRightSidebar = Notification.Name("ai.tokenstat.toggleRightSidebar")
    #endif
    /// The local archive gained or changed events (scan, remote fetch). Home
    /// re-reads its heatmap without a full window restart.
    static let archiveDidChange = Notification.Name("ai.tokenstat.archiveDidChange")
    /// A local host call is retrying after the daemon went quiet or disappeared.
    static let hostRecoveryStarted = Notification.Name("ai.tokenstat.hostRecoveryStarted")
    /// A local host call answered after a recovery attempt.
    static let hostRecoveryFinished = Notification.Name("ai.tokenstat.hostRecoveryFinished")
}

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
        Self.adoptPreferencesFromPreviousBundleID()
        Self.excludeSecretsFromBackup()
        Bridge.connect()
        // Before anything asks for a figure. A machine with no price book
        // renders every value as unknown, and on a platform with no CLI and no
        // daemon the bundled book is the only one there will be until a refresh
        // lands. Never replaces a fetched book, so this is safe every launch.
        Task { await Bridge.pricingSeed() }
        #if os(macOS)
        DesktopSyncScheduler.start()
        #endif
        // Host bring-up is owned by `LaunchState.prepare` (the splash in
        // RootView). A second ensureHosted here would race that path.
    }

    /// Keep the machine key and the login bearer out of iCloud / Time Machine
    /// backups. Restoring them onto a second device clones the identity.
    private static func excludeSecretsFromBackup() {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ai.tokenstat.tokenstat") else { return }
        for name in ["identity", "credentials"] {
            var url = base.appendingPathComponent(name)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// Carry preferences over from `ai.tokenstat.Tokenstat`.
    ///
    /// The bundle id was lowercased to match the data directory, the launch
    /// agent and every other identifier this product uses. To the system that
    /// is a different app, so `UserDefaults.standard` moved to a new domain and
    /// took the workspace list, the per-workspace bypass switches and every
    /// window preference with it. Losing those on an update nobody asked for is
    /// not an acceptable cost of a rename.
    ///
    /// Copy, not move: the old domain is left alone, so a person running the
    /// previous build alongside this one finds it as they left it. Runs once,
    /// and only fills keys the new domain does not already have, so it can
    /// never overwrite a choice made since.
    private static func adoptPreferencesFromPreviousBundleID() {
        let defaults = UserDefaults.standard
        let marker = "prefs.adoptedFromCapitalizedBundleID"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let previous = UserDefaults(suiteName: "ai.tokenstat.Tokenstat") else { return }
        for (key, value) in previous.dictionaryRepresentation() {
            // Skip the global domain's own keys, which every suite reports and
            // none of which belong to this app.
            guard !key.hasPrefix("Apple"), !key.hasPrefix("NS"), !key.hasPrefix("com.apple.") else {
                continue
            }
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
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
            #else
            // The phone and the iPad get their own root, not a narrow window.
            // A minimum size would be meaningless here: the scene is whatever
            // the device is.
            ClientRootView()
            #endif
        }
        #if os(macOS)
        // Unified toolbar and a hidden title give the rounded, chrome-light
        // window the plan asks for, without drawing custom window controls.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(Self.initialWindowSize)
        .commands {
            // Replace AppKit's standard about panel with the app's own window.
            // The panel has room for an icon, a version and a copyright line,
            // which leaves out who made this and how to reach them.
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
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
            // Sidebar toggles live on RootView. The menu posts and the window
            // acts, same shape as Add Workspace, so the shortcut works when a
            // text field would otherwise claim ⌘B for bold.
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
                Button("Toggle Inspector") {
                    NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }
            // Note: help strings on the toolbar marks also carry ⌘B / ⌥⌘B so
            // the hover tooltip teaches the shortcut without opening the menu.
        }
        #endif

        #if os(macOS)
        Window("About tokenstat", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        // Nothing outside the app opens this, and without the empty match a
        // URL or a document open can be routed to it instead of the main
        // window.
        .handlesExternalEvents(matching: [])
        #endif
    }

    #if os(macOS)
    /// Scene id shared with the About menu item.
    static let aboutWindowID = "about"

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

#if os(macOS)
/// The application menu's About item.
///
/// Its own view because `openWindow` is an environment value, and a
/// `CommandGroup` closure is not a view body that can read one.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About tokenstat") {
            openWindow(id: TokenstatApp.aboutWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
