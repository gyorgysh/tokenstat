// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WebKit

enum Theme { static let background = Color.black; static let caption = Font.caption }
enum L10n { static func text(_ key: String) -> String { "This model cannot be previewed here. Open the original file." } }
@MainActor @Observable final class ModelProbe {
    var ready = false
    var draws = 0
    var scrollY = 0
    func findWeb(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb($0) }.first
    }
    func inspect() async {
        while !Task.isCancelled {
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            if let web = windows.lazy.compactMap({ self.findWeb($0) }).first {
                var ancestor = web.superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView { scrollY = Int(scroll.contentOffset.y); break }
                    ancestor = view.superview
                }
                // Observe the real renderer after load; do not replace its controls or render loop.
                let script = """
                (() => {
                  if (!window.modelProbe) {
                    window.modelProbe = {draws: 0};
                    for (const type of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
                      if (!type) continue;
                      for (const method of ['drawArrays', 'drawElements']) {
                        const original = type.prototype[method];
                        type.prototype[method] = function (...args) {
                          window.modelProbe.draws++;
                          return original.apply(this, args);
                        };
                      }
                    }
                  }
                  return {ready: document.getElementById('status')?.hidden === true, draws: window.modelProbe.draws};
                })()
                """
                if let result = try? await web.evaluateJavaScript(script) as? [String: Any] {
                    ready = result["ready"] as? Bool == true
                    draws = result["draws"] as? Int ?? 0
                }
            } else { ready = false }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}
private let cube = Data("""
v -1 -1 -1
v 1 -1 -1
v 1 1 -1
v -1 1 -1
v -1 -1 1
v 1 -1 1
v 1 1 1
v -1 1 1
f 1 4 3 2
f 5 6 7 8
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
""".utf8)
@main struct ModelQAApp: App {
    @State private var probe = ModelProbe()
    @State private var shown = true
    @State private var oversized = false
    var body: some Scene {
        WindowGroup {
            VStack {
                HStack {
                    Text(probe.ready ? "ready" : "loading").accessibilityIdentifier("ready")
                    Text("draws \(probe.draws)").accessibilityIdentifier("draws")
                    Text("position \(probe.scrollY)").accessibilityIdentifier("position")
                }.font(.caption)
                HStack {
                    Button(shown ? "Hide" : "Show") { shown.toggle() }.accessibilityIdentifier("toggle")
                    Button(oversized ? "Valid" : "Oversized") { oversized.toggle() }.accessibilityIdentifier("size")
                }
                ScrollView {
                    VStack(spacing: 20) {
                        Text("Chat before the model")
                        if shown {
                            ClientChatModelWebView(name: "cube.obj", data: oversized ? Data(repeating: 0, count: 12 * 1024 * 1024 + 1) : cube, file: nil)
                                .environment(\.colorScheme, .dark)
                                .id(oversized)
                                .frame(height: 300)
                        }
                        ForEach(0..<40) { index in Text("Chat row \(index)").frame(maxWidth: .infinity) }
                    }.padding(16)
                }
            }
            .preferredColorScheme(.dark)
            .task { await probe.inspect() }
        }
    }
}
