// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native WK fixture; run through check-chart-appearance.py in a macOS GUI session.
import AppKit
import SwiftUI
import WebKit

private struct ChartAppearanceFixture: View {
    let source: String
    let dark: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ChatChartView(source: source).padding(12)
                Color.clear.frame(height: 700)
            }
        }
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 650, height: 500)
    }
}

@main struct ChartAppearanceQA {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let examples = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.main.url(forResource: "examples", withExtension: "json")!)) as! [[String: Any]]
        let source = String(data: try JSONSerialization.data(withJSONObject: examples[0]), encoding: .utf8)!
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 650, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ChartAppearanceFixture(source: source, dark: true))
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        func browser(_ view: NSView) -> WKWebView? {
            if let browser = view as? WKWebView { return browser }
            return view.subviews.lazy.compactMap(browser).first
        }
        func wait(_ message: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition(), Date() < deadline { settle() }
            precondition(condition(), message)
        }
        func evaluate(_ web: WKWebView, _ script: String) -> Any? {
            var finished = false
            var value: Any?
            web.evaluateJavaScript(script) { result, _ in value = result; finished = true }
            wait("JavaScript evaluation did not finish") { finished }
            return value
        }
        func nativePanel(_ web: WKWebView, dark: Bool) {
            let color = web.underPageBackgroundColor.usingColorSpace(.sRGB)!
            let bytes = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
            precondition(bytes == (dark ? [16, 14, 26] : [255, 255, 255]), "The initial WK surface must use the app's resolved Theme.panel")
        }
        func beforeRender(_ web: WKWebView, dark: Bool, cached: Bool? = nil) {
            wait("The fixture did not capture the deferred native render") {
                evaluate(web, "!!window.__chartAppearanceFixture?.pending") as? Bool == true
            }
            nativePanel(web, dark: dark)
            let cover = web.superview!.subviews.compactMap { $0 as? NSImageView }.first!
            precondition(!cover.isHidden && cover.isOpaque, "A newly mounted browser must remain behind an opaque native cover until its real first paint")
            if let cached { precondition((cover.image != nil) == cached, "Preview cache must match the exact source and theme") }
            let scheme = dark ? "dark" : "light"
            let background = dark ? "rgb(16, 14, 26)" : "rgb(255, 255, 255)"
            let result = evaluate(web, """
                JSON.stringify({
                    theme: document.documentElement.dataset.theme,
                    scheme: getComputedStyle(document.documentElement).colorScheme,
                    paper: getComputedStyle(document.getElementById('root')).backgroundColor,
                    canvas: getComputedStyle(document.documentElement).backgroundColor,
                    valid: window.TokenstatChart.inspect().valid,
                    csp: document.querySelector('meta[http-equiv="Content-Security-Policy"]').content
                })
                """) as! String
            let snapshot = try! JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
            precondition(snapshot["theme"] as? String == scheme && snapshot["scheme"] as? String == scheme)
            precondition(snapshot["paper"] as? String == background && snapshot["canvas"] as? String == background,
                         "The page must use the app's appearance before the runtime paints a chart")
            precondition(snapshot["valid"] as? Bool == false, "The test must inspect pre-render appearance, not the runtime's later theme update")
            let csp = snapshot["csp"] as! String
            precondition(csp.contains("script-src 'self';") && csp.contains("connect-src 'none';") && !csp.contains("unsafe-eval"))
        }
        func render(_ web: WKWebView) {
            _ = evaluate(web, "window.__chartAppearanceFixture.release()")
            wait("The real bundled chart must still render normally") {
                evaluate(web, "!!window.TokenstatChart.inspect().valid && document.querySelectorAll('#plot svg path').length > 0") as? Bool == true
            }
            wait("A fully painted chart must become interactive") {
                web.superview?.subviews.compactMap { $0 as? NSImageView }.first?.isHidden == true
            }
        }

        wait("A visible chart did not mount its browser") { browser(host) != nil }
        let initial = browser(host)!
        beforeRender(initial, dark: true, cached: false)
        // Change the app appearance while its initial runtime render is still
        // deferred. The OS/window appearance deliberately remains opposite.
        window.appearance = NSAppearance(named: .darkAqua)
        host.rootView = ChartAppearanceFixture(source: source, dark: false)
        wait("A visible theme change did not update the native render") {
            evaluate(initial, "window.__chartAppearanceFixture?.pending?.[1]?.dark === false") as? Bool == true
        }
        beforeRender(initial, dark: false, cached: false)
        render(initial)
        for dark in [false, true] {
            host.alphaValue = 0
            wait("An invisible chart kept its old browser") { browser(host) == nil }
            window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            host.rootView = ChartAppearanceFixture(source: source, dark: dark)
            settle()
            host.alphaValue = 1
            wait("A visible chart did not recreate its browser") { browser(host) != nil }
            let recreated = browser(host)!
            precondition(recreated !== initial)
            beforeRender(recreated, dark: dark, cached: !dark)
            render(recreated)
        }
        func nativeScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(nativeScroll).first
        }
        let scroll = nativeScroll(host)!
        for _ in 0..<3 {
            let previous = browser(host)!
            let retainedHeight = previous.bounds.height
            let bottom = max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            wait("Scrolling offscreen must release the expensive browser") { browser(host) == nil }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            wait("Revisiting a chart must mount a fresh guarded browser") { browser(host) != nil }
            let revisited = browser(host)!
            precondition(revisited !== previous)
            beforeRender(revisited, dark: true, cached: true)
            precondition(revisited.bounds.height == retainedHeight, "The loading document cannot replace the chart's retained measured height")
            let preview = revisited.superview!.subviews.compactMap { $0 as? NSImageView }.first!
            precondition(!preview.isHidden && preview.image != nil,
                         "A revisited chart must keep its cached rendered preview while its new WK document is deferred")
            let retained = NSBitmapImageRep(data: preview.image!.tiffRepresentation!)!
            var marks = 0
            for y in stride(from: 0, to: retained.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: retained.pixelsWide, by: 4) {
                    let color = retained.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if color.redComponent > 0.35 && color.blueComponent > 0.6 && color.greenComponent < 0.65 && color.blueComponent - color.greenComponent > 0.2 { marks += 1 }
                }
            }
            precondition(marks > 100, "A retained chart preview must include its plotted data, not just a blank grid")
            let bitmap = revisited.superview!.bitmapImageRepForCachingDisplay(in: revisited.superview!.bounds)!
            revisited.superview!.cacheDisplay(in: revisited.superview!.bounds, to: bitmap)
            let color = bitmap.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!
            precondition(max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3,
                         "The actual native revisit cover cannot expose a white first frame")
            render(revisited)
        }
        let old = browser(host)!
        let staleToken = evaluate(old, "window.__chartAppearanceFixture.pending[1].paintToken") as! String
        window.orderOut(nil)
        wait("A hidden window kept its chart browser") { browser(host) == nil }
        let changed = String(data: try JSONSerialization.data(withJSONObject: examples[1]), encoding: .utf8)!
        host.rootView = ChartAppearanceFixture(source: changed, dark: true)
        window.orderFront(nil)
        wait("A changed chart did not mount") { browser(host) != nil }
        let changedBrowser = browser(host)!
        beforeRender(changedBrowser, dark: true, cached: false)
        let quotedToken = String(data: try JSONSerialization.data(withJSONObject: [staleToken]), encoding: .utf8)!
        _ = evaluate(changedBrowser, "webkit.messageHandlers.chart.postMessage({type:'ready',paintToken:\(quotedToken)[0]})")
        settle()
        precondition(changedBrowser.superview!.subviews.compactMap { $0 as? NSImageView }.first!.isHidden == false,
                     "A stale source/theme ready message cannot reveal the new unpainted browser")
        render(changedBrowser)
        window.orderOut(nil)
        wait("A hidden window kept its chart browser") { browser(host) == nil }
        let donut = String(data: try JSONSerialization.data(withJSONObject: examples.first { $0["type"] as? String == "donut" }!), encoding: .utf8)!
        host.rootView = ChartAppearanceFixture(source: donut, dark: true)
        window.orderFront(nil)
        wait("The donut did not mount") { browser(host) != nil }
        beforeRender(browser(host)!, dark: true, cached: false)
        render(browser(host)!)
        window.orderOut(nil)
        wait("The donut browser did not retire") { browser(host) == nil }
        window.orderFront(nil)
        wait("The donut did not remount") { browser(host) != nil }
        let revisitedDonut = browser(host)!
        beforeRender(revisitedDonut, dark: true, cached: true)
        let donutPreview = revisitedDonut.superview!.subviews.compactMap { $0 as? NSImageView }.first!
        let donutPixels = NSBitmapImageRep(data: donutPreview.image!.tiffRepresentation!)!
        var slices = 0
        for y in stride(from: donutPixels.pixelsHigh / 4, to: donutPixels.pixelsHigh * 3 / 4, by: 4) {
            for x in stride(from: donutPixels.pixelsWide / 5, to: donutPixels.pixelsWide * 4 / 5, by: 4) {
                let color = donutPixels.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if color.redComponent > 0.35 && color.blueComponent > 0.6 && color.blueComponent - color.greenComponent > 0.2 { slices += 1 }
            }
        }
        precondition(slices > 1000, "A donut preview must contain its real slices, not only the legend captured before its entry animation")
        render(revisitedDonut)
        window.orderOut(nil)
        wait("A hidden donut kept its chart browser") { browser(host) == nil }
        window.close()
        print("Chart appearance: explicit dark/light before first paint; 3 real scroll retire/remount cycles retain opaque rendered previews until first paint; native cover pixels stay dark; CSP and interactive WK rendering preserved")
    }
}

// The fixture mirrors the native panel token without loading the full app.
enum Theme {
    static var callout: Font { .system(size: 12) }
    static var panel: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 16 / 255, green: 14 / 255, blue: 26 / 255, alpha: 1) : .white
        })
    }
}
