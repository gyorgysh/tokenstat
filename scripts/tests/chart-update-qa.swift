// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Appended to ChatChartView.swift by check-chart-updates.py to exercise its private coordinator.
import AppKit

private final class ChartUpdateBrowser: WKWebView {
    var scripts: [String] = []
    var callbacks: [@MainActor (Any?, Error?) -> Void] = []
    override func evaluateJavaScript(_ script: String, completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
        scripts.append(script)
        if let completionHandler { callbacks.append(completionHandler) }
    }
}

private final class ChartRequestReference {
    weak var value: ChartWebView.RenderRequest?
    init(_ value: ChartWebView.RenderRequest) { self.value = value }
}

@main struct ChartUpdateQA {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "Chart update check failed") {
            if !condition() { fputs(message + "\n", stderr); exit(1) }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let examples = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.main.url(forResource: "examples", withExtension: "json")!)) as! [[String: Any]]
        let json = String(data: try JSONSerialization.data(withJSONObject: examples[0]), encoding: .utf8)!
        let source = json + String(repeating: " ", count: 256 * 1024 - json.utf8.count)
        let light = Color.white.resolve(in: EnvironmentValues())
        let dark = Color.black.resolve(in: EnvironmentValues())
        var failures: [String] = []
        func owner(_ source: String, dark: Bool = false, panel: Color.Resolved? = nil, motion: Bool = false) -> ChartWebView {
            ChartWebView(source: source, dark: dark, panel: panel ?? light, reduceMotion: motion, height: .constant(430),
                         onExport: { _, _ in }, onError: { failures.append($0) })
        }
        let original = owner(source)
        let coordinator = original.makeCoordinator()
        let web = ChartUpdateBrowser(frame: CGRect(x: 0, y: 0, width: 640, height: 430))
        let surface = ChartSurfaceView(browser: web, size: web.bounds.size)
        coordinator.webView = web
        coordinator.surface = surface
        coordinator.webView(web, didFinish: nil)
        precondition(web.scripts.count == 1)
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { coordinator.update(original) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print("Apple chart preparation: 100 unchanged 256 KiB updates; median of 7 = \(samples.sorted()[3]) ms")
        precondition(web.scripts.count == 1, "Unchanged updates must preserve the live chart")
        let copied = String(decoding: Array(source.utf8), as: UTF8.self)
        let copiedOwner = owner(copied)
        samples.removeAll(keepingCapacity: true)
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<100 { coordinator.update(copiedOwner) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        print("Apple chart preparation: 100 equal 256 KiB inputs from another allocation; median of 7 = \(samples.sorted()[3]) ms")
        precondition(web.scripts.count == 1, "Equal source bytes in a different allocation must preserve the live chart")
        let initial = web.scripts[0]
        precondition(initial.contains(Data(source.utf8).base64EncodedString()))
        coordinator.update(owner(source, dark: true, panel: dark))
        precondition(web.scripts.count == 3, "Appearance bootstrap and chart render must both update")
        precondition(web.scripts.last!.contains("\"dark\":true"))
        coordinator.update(owner(source, dark: true, panel: dark, motion: true))
        precondition(web.scripts.count == 4 && web.scripts.last!.contains("\"reducedMotion\":true"))
        let replacement = String(data: try JSONSerialization.data(withJSONObject: examples[1]), encoding: .utf8)!
        coordinator.update(owner(replacement, dark: true, panel: dark, motion: true))
        precondition(web.scripts.count == 5 && web.scripts.last!.contains(Data(replacement.utf8).base64EncodedString()))
        web.callbacks[0](nil, NSError(domain: "old render", code: 1))
        precondition(failures.isEmpty, "An old render error must not appear on the replacement chart")
        coordinator.update(original)
        web.callbacks[0](nil, NSError(domain: "old identical render", code: 1))
        precondition(failures.isEmpty, "Returning to the original source must not revive its old callbacks")
        web.callbacks.last!(nil, NSError(domain: "current render", code: 2))
        precondition(failures.count == 1, "A current render error must remain visible")
        let retired = ChartRequestReference(coordinator.prepare())
        coordinator.unmount(web)
        precondition(retired.value == nil, "Offscreen charts must release cached payloads")
        coordinator.webView(web, didFinish: nil)
        web.callbacks.last!(nil, NSError(domain: "retired render", code: 3))
        precondition(web.scripts.count == 7 && failures.count == 1, "A retired browser must not render or publish errors")

        let inputs = ChartWebView.RenderInputs(source: source, dark: false, panel: light, reduceMotion: false, locale: "en_US")
        let request = ChartWebView.RenderRequest(inputs, previous: nil)
        let same = ChartWebView.RenderRequest(inputs, previous: nil)
        precondition(request.previewKey(width: 640) == same.previewKey(width: 640), "Remounts must find the same preview")
        precondition(request.previewKey(width: 320) != request.previewKey(width: 640), "Different widths need different previews")
        let translated = ChartWebView.RenderRequest(.init(source: source, dark: false, panel: light, reduceMotion: false, locale: "hu_HU"), previous: request)
        precondition(translated.paintToken != request.paintToken && translated.settingsText!.contains("hu-HU"), "Locale changes must invalidate the preview and formatting")
        precondition(translated.payload == request.payload, "Formatting changes must retain source bytes")

        let composed = "{\"version\":1,\"type\":\"bar\",\"title\":\"Café\",\"categories\":[\"A\"],\"series\":[{\"name\":\"Count\",\"data\":[1]}]}"
        let decomposed = composed.replacingOccurrences(of: "é", with: "e\u{301}")
        precondition(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8))
        let unicodeOwner = owner(composed)
        let unicode = unicodeOwner.makeCoordinator()
        let unicodeWeb = ChartUpdateBrowser()
        unicode.webView = unicodeWeb
        unicode.webView(unicodeWeb, didFinish: nil)
        unicode.update(owner(decomposed))
        precondition(unicodeWeb.scripts.count == 2 && unicodeWeb.scripts.last!.contains(Data(decomposed.utf8).base64EncodedString()),
                     "Canonically equivalent text must still deliver the exact new JSON bytes")
        unicode.dispose()
        print("Apple chart updates: source bytes, theme, motion, locale, width, stale/current errors, return to original source and payload release passed")
    }
}

enum Theme {
    static var callout: Font { .system(size: 12) }
    static var panel: Color { .white }
}
