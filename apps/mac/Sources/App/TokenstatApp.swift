// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

@main
struct TokenstatApp: App {
    /// Pick the transport before any view can call across it.
    ///
    /// In the initializer rather than in a `.task`, because a view that renders
    /// first would make its opening calls in-process and its later ones over
    /// the daemon, so the terminals a session starts with would belong to a
    /// different owner than the ones it ends with.
    init() {
        Bridge.connect()
        DesktopSyncScheduler.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1040, minHeight: 620)
        }
        #if os(macOS)
        // Unified toolbar and a hidden title give the rounded, chrome-light
        // window the plan asks for, without drawing custom window controls.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 720)
        #endif
    }
}
