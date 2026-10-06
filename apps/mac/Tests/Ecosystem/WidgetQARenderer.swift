// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native SwiftUI layout artifacts for QA. Excluded from shipping targets.
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum WidgetQARenderer {
    static func export() {
        let directory = ProcessInfo.processInfo.environment["TOKENSTAT_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-layouts")
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
        stress.limits = [.init(source: "provider_with_a_long_name", observedAt: .now.addingTimeInterval(-86_400), stale: true,
                               windows: [.init(label: "Weekly quota with long label", percent: 104, resetsAt: .now.addingTimeInterval(-60))])]
        var offline = EcosystemSnapshot.preview
        offline.refreshFailed = true
        let snapshots: [(String, EcosystemSnapshot)] = [("activity", .preview), ("empty", .empty), ("stress", stress), ("offline", offline)]
        let styles: [(String, EcosystemAppearance, EcosystemTint, Bool, WidgetRenderingMode)] = [
            ("light", .light, .brand, false, .fullColor), ("dark", .dark, .brand, true, .fullColor),
            ("clean-light", .clean, .brand, false, .fullColor), ("clean-dark", .clean, .brand, true, .fullColor),
            ("black", .black, .brand, true, .fullColor), ("teal", .light, .teal, false, .fullColor),
            ("monochrome", .black, .monochrome, true, .fullColor), ("tinted", .dark, .pink, false, .accented)
        ]
        let attributes = LiveWorkAttributes(startedAt: Date().addingTimeInterval(-147).timeIntervalSince1970,
            owner: "preview", peer: "preview", key: "preview", revision: "1", projectName: "Studio", route: "tokenstat://open/workspaces")
        for (phase, stale) in [(LiveWorkPhase.working, false), (.waiting, false), (.done, false), (.failed, false), (.stopped, false), (.working, true)] {
            let state = LiveWorkAttributes.ContentState(phase: phase, updatedAt: Date().timeIntervalSince1970)
            let renderer = ImageRenderer(content: LiveWorkCard(attributes: attributes, state: state, stale: stale)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .frame(width: 390, height: 120).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.cgImage,
               let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("live-work-\(stale ? "reconnecting" : phase.rawValue).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
            }
        }
        for (style, appearance, tint, dark, mode) in styles {
            for (family, width, height, name) in families {
                for (state, snapshot) in snapshots {
                    let entry = TokenstatWidgetEntry(date: Date(), snapshot: snapshot, appearance: appearance, tint: tint)
                    render(TokenstatUsageView(entry: entry, familyOverride: family), width: width, height: height, entry: entry, dark: dark, mode: mode,
                           url: directory.appendingPathComponent("usage-\(name)-\(style)-\(state).png"))
                }
                if family != .systemExtraLarge {
                    for (state, snapshot) in snapshots {
                        let quotas = state == "stress" ? stress : snapshot
                        let entry = TokenstatLimitsEntry(date: .now, snapshot: quotas, appearance: appearance, tint: tint)
                        render(TokenstatLimitsView(entry: entry, familyOverride: family), width: width, height: height,
                               entry: TokenstatWidgetEntry(date: .now, snapshot: quotas, appearance: appearance, tint: tint), dark: dark, mode: mode,
                               url: directory.appendingPathComponent("limits-\(name)-\(style)-\(state).png"))
                    }
                }
                if family != .systemExtraLarge {
                    for display in [EcosystemGaugeStyle.rings, .bars] {
                        for count in [1, 3, 4, 9] {
                            var quotas = EcosystemSnapshot.preview
                            quotas.limits = (0..<count).map { index in
                                var reading = EcosystemSnapshot.preview.limits![index % 3]
                                if index >= 3 { reading.source = "vendor_\(index)" }
                                return reading
                            }
                            let quotaEntry = TokenstatLimitsEntry(date: .now, snapshot: quotas, display: display, appearance: appearance, tint: tint)
                            let styleEntry = TokenstatWidgetEntry(date: .now, snapshot: quotas, appearance: appearance, tint: tint)
                            render(TokenstatLimitsView(entry: quotaEntry, familyOverride: family), width: width, height: height, entry: styleEntry, dark: dark, mode: mode,
                                   url: directory.appendingPathComponent("limits-\(name)-\(style)-\(display.rawValue)-\(count).png"))
                        }
                    }
                }
                if family != .systemExtraLarge {
                    for (state, snapshot) in snapshots.prefix(3) {
                        let entry = TokenstatWidgetEntry(date: Date(), snapshot: snapshot, appearance: appearance, tint: tint)
                        render(TokenstatLauncherView(entry: entry, familyOverride: family), width: width, height: height, entry: entry, dark: dark, mode: mode,
                               url: directory.appendingPathComponent("launcher-\(name)-\(style)-\(state).png"))
                    }
                }
            }
            #if os(iOS)
            for (family, width, height, name) in [(WidgetFamily.accessoryCircular, CGFloat(76), CGFloat(76), "circular"),
                                                  (.accessoryRectangular, 170, 76, "rectangular")] {
                let entry = TokenstatWidgetEntry(date: Date(), snapshot: .preview, appearance: appearance, tint: tint)
                render(TokenstatLauncherView(entry: entry, familyOverride: family), width: width, height: height,
                       entry: entry, dark: dark, mode: mode, url: directory.appendingPathComponent("launcher-\(name)-\(style).png"))
            }
            #endif
        }
    }

    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, entry: TokenstatWidgetEntry,
                                        dark: Bool, mode: WidgetRenderingMode, url: URL) {
        let renderer = ImageRenderer(content: TokenstatWidgetSurface(appearance: entry.appearance) { view }
            .padding(16).frame(width: width, height: height)
            .background(WidgetStyle.background(entry.appearance, dark: dark))
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.widgetRenderingMode, mode))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
