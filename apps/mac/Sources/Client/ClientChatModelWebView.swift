// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import WebKit

/// A profile-free, offline WebGL surface for portable game model files.
/// The document CSP denies network access and only the selected attachment's
/// bytes cross into its renderer. File access remains inside the app bundle.
struct ClientChatModelWebView: ViewRepresentable {
    let name: String
    let data: Data?
    let file: URL?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { dismantle(view, coordinator: coordinator) }
    #endif

    private func makeView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        #if os(macOS)
        web.underPageBackgroundColor = NSColor(Theme.background)
        #else
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.background)
        web.scrollView.isScrollEnabled = false
        #endif
        context.coordinator.start(web: web, name: name, data: data, file: file,
                                  background: colorScheme == .dark ? "#08070d" : "#fbfbfd")
        return web
    }

    private static func dismantle(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.dispose()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var web: WKWebView?
        private var bytes: Data?
        private var task: Task<Void, Never>?
        private var extensionName = ""
        private var background = ""
        private var loaded = false
        private var sent = false

        func start(web: WKWebView, name: String, data: Data?, file: URL?, background: String) {
            self.web = web
            self.extensionName = (name as NSString).pathExtension.lowercased()
            self.background = background
            guard let directory = Bundle.main.url(forResource: "runtime", withExtension: nil) else { return }
            web.loadFileURL(directory.appendingPathComponent("model.html"), allowingReadAccessTo: directory)
            task = Task { [weak self] in
                let result = await Task.detached(priority: .utility) { () -> Data? in
                    if let data { return data.count <= 12 * 1024 * 1024 ? data : nil }
                    guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size > 0, size <= 12 * 1024 * 1024 else { return nil }
                    return try? Data(contentsOf: file, options: .mappedIfSafe)
                }.value
                guard !Task.isCancelled else { return }
                self?.bytes = result
                self?.sendIfReady()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.web === webView else { return }
            loaded = true
            sendIfReady()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }

        private func sendIfReady() {
            guard loaded, !sent, let web, let bytes else { return }
            sent = true
            let code = "TokenstatModel.load('\(bytes.base64EncodedString())','\(extensionName)','\(background)')"
            web.evaluateJavaScript(code, completionHandler: nil)
            self.bytes = nil
        }

        func dispose() {
            task?.cancel()
            bytes = nil
            web = nil
        }
    }
}

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#else
private typealias ViewRepresentable = UIViewRepresentable
#endif
