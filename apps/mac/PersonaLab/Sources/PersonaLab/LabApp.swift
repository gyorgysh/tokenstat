// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

@main
struct PersonaLabApp: App {
    init() {
        // `--shots` renders filmstrips and leaves. Checked here rather than in
        // a `main.swift`, because an executable cannot have both that and an
        // `@main` App.
        if LabShots.run(arguments: CommandLine.arguments) {
            exit(0)
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
