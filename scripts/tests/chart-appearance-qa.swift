// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Native WK fixture; run through check-chart-appearance.py in a macOS GUI session.
import AppKit
import SwiftUI
import WebKit

private struct ChartAppearanceFixture: View {
    let source: String
    let dark: Bool
    var body: some View {
        ScrollView { ChatChartView(source: source).padding(12) }
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
        let host = NSHostingView(rootView: ChartAppearanceFixture(source: source, dark: true))
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        func browser(_ view: NSView) -> WKWebView? {
            if let viewport = view as? ChartViewportView { return viewport.content as? WKWebView }
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
        func beforeRender(_ web: WKWebView, dark: Bool) {
            wait("The fixture did not capture the deferred native render") {
                evaluate(web, "!!window.__chartAppearanceFixture?.pending") as? Bool == true
            }
            nativePanel(web, dark: dark)
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
        }

        wait("A visible chart did not mount its browser") { browser(host) != nil }
        let initial = browser(host)!
        beforeRender(initial, dark: true)
        // Change the app appearance while its initial runtime render is still
        // deferred. The OS/window appearance deliberately remains opposite.
        window.appearance = NSAppearance(named: .darkAqua)
        host.rootView = ChartAppearanceFixture(source: source, dark: false)
        wait("A visible theme change did not update the native render") {
            evaluate(initial, "window.__chartAppearanceFixture?.pending?.[1]?.dark === false") as? Bool == true
        }
        beforeRender(initial, dark: false)
        render(initial)
        for dark in [true, false] {
            host.alphaValue = 0
            wait("An invisible chart kept its old browser") { browser(host) == nil }
            window.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            host.rootView = ChartAppearanceFixture(source: source, dark: dark)
            settle()
            host.alphaValue = 1
            wait("A visible chart did not recreate its browser") { browser(host) != nil }
            let recreated = browser(host)!
            precondition(recreated !== initial)
            beforeRender(recreated, dark: dark)
            render(recreated)
        }
        window.orderOut(nil)
        wait("A hidden window kept its chart browser") { browser(host) == nil }
        window.close()
        print("Chart appearance: native and pre-render document surfaces follow explicit app dark/light, visible changes and offscreen recreation; CSP and normal WK rendering preserved")
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
