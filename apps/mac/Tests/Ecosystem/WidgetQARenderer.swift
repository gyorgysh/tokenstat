// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native SwiftUI layout artifacts for QA. Excluded from shipping targets.
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum WidgetQARenderer {
    static func export() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-layouts")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let families: [(WidgetFamily, CGFloat, CGFloat, String)] = [
            (.systemSmall, 170, 170, "small"), (.systemMedium, 360, 170, "medium"),
            (.systemLarge, 360, 376, "large"), (.systemExtraLarge, 720, 376, "extra-large")
        ]
        var stress = EcosystemSnapshot.preview
        let index = stress.usage!.days.count - 1
        stress.usage?.days[index].value = 1_234_567_890_000
        stress.projects[0].name = "A project with a very long descriptive name"
        stress.projects += [.init(id: "preview-3", name: "Client", host: "Studio"), .init(id: "preview-4", name: "Website", host: "MacBook")]
        var offline = EcosystemSnapshot.preview
        offline.refreshFailed = true
        let snapshots: [(String, EcosystemSnapshot)] = [("activity", .preview), ("empty", .empty), ("stress", stress), ("offline", offline)]
        for dark in [false, true] {
            for (family, width, height, name) in families {
                for (state, snapshot) in snapshots {
                    let entry = TokenstatWidgetEntry(date: Date(), snapshot: snapshot)
                    render(TokenstatUsageView(entry: entry, familyOverride: family), width: width, height: height, dark: dark,
                           url: directory.appendingPathComponent("usage-\(name)-\(dark ? "dark" : "light")-\(state).png"))
                }
                if family != .systemExtraLarge {
                    for (state, snapshot) in snapshots.prefix(3) {
                        let entry = TokenstatWidgetEntry(date: Date(), snapshot: snapshot)
                        render(TokenstatLauncherView(entry: entry, familyOverride: family), width: width, height: height, dark: dark,
                               url: directory.appendingPathComponent("launcher-\(name)-\(dark ? "dark" : "light")-\(state).png"))
                    }
                }
            }
        }
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, url: URL) {
        let renderer = ImageRenderer(content: view.padding(16).frame(width: width, height: height)
            .background(WidgetStyle.background(dark)).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
