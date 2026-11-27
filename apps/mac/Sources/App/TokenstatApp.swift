// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DiagnosticsLog.watchInput()
            #if DEBUG
            DebugUIHooks.install()
            #endif
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop hostd before dropping the lock, so launchd does not win a
        // race with the helper's own watch thread.
        HostAgentInstaller.stopIfNotAlwaysOn()
        HostOwnerLock.release()
    }
}
#else
import UIKit

/// The phone and tablet have one thing AppKit's delegate does not: the APNs
/// device token, which arrives nowhere else. Everything else this app does at
/// launch lives in `TokenstatApp.init`.
final class ClientAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { EcosystemWatchSync.shared.activate() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.received(token: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.failed(error)
        }
    }
}
#endif

enum BridgeLaunch {
    @MainActor private static var handshake: Task<Void, Never>?

    @MainActor static func begin() {
        guard handshake == nil else { return }
        handshake = Task.detached(priority: .userInitiated) {
            Bridge.connect()
        }
    }

    static func wait() async {
        let task = await MainActor.run { handshake }
        await task?.value
    }
}

extension Notification.Name {
    #if os(macOS)
    static let addWorkspaceRequested = Notification.Name("ai.tokenstat.addWorkspaceRequested")
    static let toggleLeftSidebar = Notification.Name("ai.tokenstat.toggleLeftSidebar")
    static let searchWorkRequested = Notification.Name("ai.tokenstat.searchWorkRequested")
    static let chatStepRequested = Notification.Name("ai.tokenstat.chatStepRequested")
    static let chatStepGroupsToggleRequested = Notification.Name("ai.tokenstat.chatStepGroupsToggleRequested")
    static let toggleRightSidebar = Notification.Name("ai.tokenstat.toggleRightSidebar")
    #endif
    static let archiveDidChange = Notification.Name("ai.tokenstat.archiveDidChange")
    static let hostRecoveryStarted = Notification.Name("ai.tokenstat.hostRecoveryStarted")
    static let hostRecoveryFinished = Notification.Name("ai.tokenstat.hostRecoveryFinished")
    static let hostBecameSilent = Notification.Name("ai.tokenstat.hostBecameSilent")
    static let hostBecameUnreachable = Notification.Name("ai.tokenstat.hostBecameUnreachable")
}

#if !WORKBENCH_QA
@main enum TokenstatEntry {
    @MainActor static func main() {
        #if os(macOS)
        if let status = WorkCacheKey.helperMainIfRequested() { exit(status) }
        #endif
        TokenstatApp.main()
    }
}
#endif
struct TokenstatApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #else
    @UIApplicationDelegateAdaptor(ClientAppDelegate.self) private var delegate
    #endif

    init() {
        #if os(macOS)
        DiagnosticsLog.start()
        #endif
        AppFonts.register()
        Self.adoptPreferencesFromPreviousBundleID()
        AccountIdentityPins.shared.activate()
        Self.excludeSecretsFromBackup()
        BridgeLaunch.begin()
        Task.detached(priority: .utility) { TokenstatAppShortcuts.updateAppShortcutParameters() }
        NotificationPresenter.install()
        Task { await ChatAttachmentCache.shared.maintain() }
        #if os(macOS)
        Task {
            await BridgeLaunch.wait()
            DeviceAccessRequests.shared.start()
        }
        #endif
        #if os(iOS)
        // A token is only asked for when somebody has already said yes, and
        // then on every launch, because iOS reissues them.
        PushRegistrar.shared.refresh()
        #endif
        Task {
            await BridgeLaunch.wait()
            await Bridge.pricingSeed()
            _ = try? await Bridge.pricingRefresh()
        }
        #if os(macOS)
        HostOwnerLock.acquire()
        DesktopSyncScheduler.start()
        Task {
            await BridgeLaunch.wait()
            ScreenCaptureCoordinator.shared.start()
        }
        #endif
    }

    /// Keep the machine key and the login bearer out of iCloud / Time Machine
    /// backups. Restoring them onto a second device clones the identity.
    ///
    /// The directories are created here, before anything writes a key, because
    /// `setResourceValues` on a missing path is a no-op and the first session
    /// is the one that mints both secrets.
    private static func excludeSecretsFromBackup() {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ai.tokenstat.tokenstat") else { return }
        for name in ["identity", "credentials"] {
            var url = base.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
                .modifier(AppAppearanceScheme())
                .frame(
                    minWidth: RootView.minimumContentWidth,
                    minHeight: RootView.minimumContentHeight
                )
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            #else
            ClientRootView()
                .modifier(AppAppearanceScheme())
            #endif
        }
        #if os(macOS)
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
            CommandGroup(after: .newItem) {
                Button(L10n.text("apple.tokenstatapp.add_project.94d63fa2")) {
                    NotificationCenter.default.post(name: .addWorkspaceRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button(L10n.text("apple.tokenstatapp.search_work.7b7bfbb6")) {
                    NotificationCenter.default.post(name: .searchWorkRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            CommandGroup(after: .sidebar) {
                Button(L10n.text("apple.tokenstatapp.toggle_sidebar.1d4c17db")) {
                    NotificationCenter.default.post(name: .toggleLeftSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
                Button(L10n.text("apple.tokenstatapp.toggle_inspector.1d522187")) {
                    NotificationCenter.default.post(name: .toggleRightSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button(L10n.text("apple.tokenstatapp.previous_conversation.2afe4350")) {
                    NotificationCenter.default.post(name: .chatStepRequested, object: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button(L10n.text("apple.tokenstatapp.next_conversation.379370fa")) {
                    NotificationCenter.default.post(name: .chatStepRequested, object: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Section {
                    ChatDetailMenuPicker()
                    Button(L10n.text("apple.chatdetail.toggle_steps")) {
                        NotificationCenter.default.post(name: .chatStepGroupsToggleRequested, object: nil)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                }
            }
        }
        #endif

        #if os(macOS)
        Window(L10n.text("apple.tokenstatapp.about_tokenstat.2777c642"), id: Self.aboutWindowID) {
            AboutView()
                .modifier(AppAppearanceScheme())
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: [])

        // A real window, not a sheet. Sheets cannot enter AppKit full screen,
        // and `NSApp.keyWindow` on a sheet is the parent, so the expand
        // control on the viewer did nothing between two Macs.
        WindowGroup(for: RemoteScreenTarget.self) { $target in
            if let target {
                ScreenViewerView(peer: target.peer, name: target.name, tier: target.tier)
                    .modifier(AppAppearanceScheme())
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .defaultSize(width: 1100, height: 720)
        .handlesExternalEvents(matching: [])
        #endif
    }

    #if os(macOS)
    static let aboutWindowID = "about"

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
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("apple.tokenstatapp.about_tokenstat.2777c642")) {
            openWindow(id: TokenstatApp.aboutWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
#endif
