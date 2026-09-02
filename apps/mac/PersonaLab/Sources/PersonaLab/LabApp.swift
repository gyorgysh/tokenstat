// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AppKit
import SwiftUI

@main
struct PersonaLabApp: App {
    init() {
        // Command-line rendering deliberately has no app activation or dock
        // presence. It is used by scripts and exits as soon as the image or
        // benchmark has been written.
        if LabShots.run(arguments: CommandLine.arguments) {
            exit(0)
        }

        // SwiftPM builds an executable rather than an app bundle. Tell AppKit
        // this is still a regular GUI app, otherwise it can make a window
        // behind the caller without ever bringing PersonaLab forward.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("persona motion lab") {
            LabView()
                .frame(minWidth: 1040, minHeight: 720)
        }
        .defaultSize(width: 1180, height: 820)
    }
}
