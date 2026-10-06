// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native SwiftUI layout artifacts for QA. Excluded from shipping targets.
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers

@MainActor enum WidgetQARenderer {
    struct LiveWorkRender: Codable {
        var filename: String
        var width: Int
        var height: Int
        var nonBlackFraction: Double?
    }
    struct ExportReport: Codable {
        var liveWorkImages = 0
        var liveWork: [LiveWorkRender] = []
        var failures: [String] = []
        var summary: String {
            "Live Activity QA: \(liveWorkImages) images, \(failures.count) failures"
                + (failures.first.map { " · \($0)" } ?? "")
        }
    }
    static func export(liveWorkOnly: Bool = false, reportFilename: String = "live-work-report.json") -> ExportReport {
        let directory = ProcessInfo.processInfo.environment["TOKENSTAT_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("widget-layouts")
        var report = ExportReport()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            report.failures.append("Cannot create export directory: \(error.localizedDescription)")
            print("[Widget QA] \(report.summary)")
            return report
        }
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
        var old = EcosystemSnapshot.preview
        old.limits = ["claude_code", "codex", "grok"].enumerated().map { index, source in
            .init(source: source, observedAt: .now.addingTimeInterval(-45 * 60), stale: true,
                  windows: [.init(label: "5-hour", percent: Double(index * 15 + 8), resetsAt: .now.addingTimeInterval(3600)),
                            .init(label: "weekly (general)", percent: Double([15, 48, 0][index]), resetsAt: .now.addingTimeInterval(5 * 86400), rawLabel: "weekly", scope: "general")])
        }
        var working = old
        _ = working.beginRefresh(.limits); _ = working.beginRefresh(.usage)
        var complete = old
        let completeID = complete.beginRefresh(.limits)!
        complete.finishRefresh(.limits, id: completeID, success: true)
        var failed = old
        let failedID = failed.beginRefresh(.limits)!
        failed.finishRefresh(.limits, id: failedID, success: false)
        let snapshots: [(String, EcosystemSnapshot)] = [("activity", .preview), ("empty", .empty), ("stress", stress), ("offline", offline),
                                                        ("old", old), ("working", working), ("complete", complete), ("failed", failed)]
        let styles: [(String, EcosystemAppearance, EcosystemTint, Bool, WidgetRenderingMode)] = [
            ("light", .light, .brand, false, .fullColor), ("dark", .dark, .brand, true, .fullColor),
            ("clean-light", .clean, .brand, false, .fullColor), ("clean-dark", .clean, .brand, true, .fullColor),
            ("black", .black, .brand, true, .fullColor), ("teal", .light, .teal, false, .fullColor),
            ("monochrome", .black, .monochrome, true, .fullColor), ("tinted", .dark, .pink, false, .accented)
        ]
        let now = Date()
        let attributes = LiveWorkAttributes(startedAt: now.addingTimeInterval(-147).timeIntervalSince1970,
            owner: "preview", peer: "preview", key: "preview", revision: "1", projectName: "Studio", route: "tokenstat://open/workspaces")
        // Six variants across six states: 36 images, independent of the widget matrix.
        let variants: [(String, CGFloat, CGFloat, Bool, DynamicTypeSize, String)] = [
            ("", 390, 120, false, .large, "Studio"),
            ("narrow", 320, 120, false, .large, "Studio"),
            ("long-project", 390, 120, false, .large, "A project with a very long descriptive name"),
            ("dimmed", 390, 120, true, .large, "Studio"),
            ("large-text", 320, 160, false, .xxxLarge, "A project with a very long descriptive name"),
            ("accessibility", 320, 160, false, .accessibility3, "A project with a very long descriptive name")
        ]
        for (variant, width, height, dimmed, textSize, project) in variants {
            var variantAttributes = attributes
            variantAttributes.projectName = project
            for (phase, stale) in [(LiveWorkPhase.working, false), (.waiting, false), (.done, false), (.failed, false), (.stopped, false), (.working, true)] {
                let state = LiveWorkAttributes.ContentState(phase: phase, updatedAt: now.timeIntervalSince1970)
                let filename = "live-work-\(stale ? "reconnecting" : phase.rawValue)\(variant.isEmpty ? "" : "-\(variant)").png"
                let renderer = ImageRenderer(content: LiveWorkCard(attributes: variantAttributes, state: state, stale: stale)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .frame(width: width, height: height).background(Color.black)
                    .environment(\.colorScheme, .dark).environment(\.isLuminanceReduced, dimmed).environment(\.dynamicTypeSize, textSize))
                renderer.scale = 2
                exportLiveWork(renderer.cgImage, filename: filename, directory: directory, report: &report)
            }
        }
        writeReport(&report, directory: directory, filename: reportFilename)
        if liveWorkOnly { return report }
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
                    for selection in [EcosystemLimitWindowSelection.fiveHour, .weekly, .both] {
                        for display in [EcosystemGaugeStyle.rings, .bars] {
                            var quotas = old
                            quotas.limits = Array(quotas.limits!.prefix(2))
                            let quotaEntry = TokenstatLimitsEntry(date: .now, snapshot: quotas, display: display,
                                appearance: appearance, tint: tint, window: selection)
                            let styleEntry = TokenstatWidgetEntry(date: .now, snapshot: quotas, appearance: appearance, tint: tint)
                            render(TokenstatLimitsView(entry: quotaEntry, familyOverride: family), width: width, height: height,
                                entry: styleEntry, dark: dark, mode: mode,
                                url: directory.appendingPathComponent("limits-\(name)-\(style)-\(display.rawValue)-\(selection.rawValue).png"))
                        }
                    }
                    let simple = TokenstatWidgetEntry(date: .now, snapshot: old, appearance: appearance, tint: tint, showCharts: false)
                    render(TokenstatUsageView(entry: simple, familyOverride: family), width: width, height: height,
                        entry: simple, dark: dark, mode: mode, url: directory.appendingPathComponent("usage-\(name)-\(style)-no-charts.png"))
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
        return report
    }

    private static func exportLiveWork(_ image: CGImage?, filename: String, directory: URL, report: inout ExportReport) {
        let url = directory.appendingPathComponent(filename)
        // A prior successful artifact must not hide this run's missing render.
        try? FileManager.default.removeItem(at: url)
        guard let image else {
            report.failures.append("\(filename): ImageRenderer returned no image")
            return
        }
        let visible = nonBlackFraction(image)
        report.liveWork.append(.init(filename: filename, width: image.width, height: image.height, nonBlackFraction: visible))
        if let visible {
            // Detect an absent whole card, without depending on timer digits,
            // antialiasing, exact colors or a particular SwiftUI font rasterizer.
            if visible < 0.0025 { report.failures.append("\(filename): near-black card (\(visible))") }
        } else {
            report.failures.append("\(filename): cannot inspect rendered pixels")
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            report.failures.append("\(filename): cannot create PNG destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { report.liveWorkImages += 1 }
        else { report.failures.append("\(filename): cannot write PNG") }
    }

    private static func nonBlackFraction(_ image: CGImage) -> Double? {
        guard image.width > 0, image.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            context.flush()
            var visible = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[index + 3] > 24 && max(bytes[index], bytes[index + 1], bytes[index + 2]) > 24 { visible += 1 }
            }
            return Double(visible) / Double(image.width * image.height)
        }
    }

    private static func writeReport(_ report: inout ExportReport, directory: URL, filename: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch { report.failures.append("Cannot write render report: \(error.localizedDescription)") }
        print("[Widget QA] \(report.summary)")
        for failure in report.failures { print("[Widget QA] ERROR: \(failure)") }
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
