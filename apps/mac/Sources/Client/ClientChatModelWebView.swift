// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI
import WebKit

/// A profile-free, offline WebGL surface for portable game model files.
/// The document CSP denies network access and only the selected attachment's
/// bytes cross into its renderer. File access remains inside the app bundle.
struct ClientChatModelWebView: View {
    let name: String
    let data: Data?
    let file: URL?
    @State private var failed = false

    var body: some View {
        if failed {
            Label(L10n.text("apple.clientchatmodelpreview.unavailable"), systemImage: "cube")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ModelWebSurface(name: name, data: data, file: file, onFailure: { failed = true })
        }
    }
}

private struct ModelWebSurface: ViewRepresentable {
    let name: String
    let data: Data?
    let file: URL?
    let onFailure: () -> Void
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
        ModelTouchClaim.attach(to: web)
        #endif
        context.coordinator.start(web: web, name: name, data: data, file: file,
                                  background: colorScheme == .dark ? "#08070d" : "#fbfbfd", onFailure: onFailure)
        return web
    }

    private static func dismantle(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.dispose()
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var web: WKWebView?
        private var payload: String?
        private var task: Task<Void, Never>?
        private var onFailure: (() -> Void)?
        private var extensionName = ""
        private var background = ""
        private var loaded = false
        private var sent = false

        func start(web: WKWebView, name: String, data: Data?, file: URL?, background: String,
                   onFailure: @escaping () -> Void) {
            self.web = web
            self.onFailure = onFailure
            self.extensionName = (name as NSString).pathExtension.lowercased()
            self.background = background
            task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                guard let directory = Bundle.main.url(forResource: "runtime", withExtension: nil) else {
                    self?.fail()
                    return
                }
                self?.web?.loadFileURL(directory.appendingPathComponent("model.html"), allowingReadAccessTo: directory)
                let result = await Task.detached(priority: .utility) { () -> String? in
                    let limit = 12 * 1024 * 1024
                    if let data {
                        return !data.isEmpty && data.count <= limit ? data.base64EncodedString() : nil
                    }
                    guard let file,
                          let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          values.isRegularFile == true, let size = values.fileSize,
                          size > 0, size <= limit,
                          let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                    defer { try? handle.close() }
                    // Bound the read even if the file grows after checking its size.
                    guard let bytes = try? handle.read(upToCount: limit + 1),
                          !bytes.isEmpty, bytes.count <= limit else { return nil }
                    return bytes.base64EncodedString()
                }.value
                guard !Task.isCancelled else { return }
                guard let result else { self?.fail(); return }
                self?.payload = result
                self?.sendIfReady()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.web === webView else { return }
            loaded = true
            sendIfReady()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if self.web === webView { fail() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if self.web === webView { fail() }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if self.web === webView { fail() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }

        private func sendIfReady() {
            guard loaded, !sent, let web, let payload else { return }
            sent = true
            let code = "void TokenstatModel.load('\(payload)','\(extensionName)','\(background)')"
            web.evaluateJavaScript(code) { [weak self, weak web] _, error in
                guard let self, let web, self.web === web, error != nil else { return }
                self.fail()
            }
            self.payload = nil
        }

        private func fail() {
            guard web != nil, let onFailure else { return }
            self.onFailure = nil
            task?.cancel()
            payload = nil
            onFailure()
        }

        func dispose() {
            task?.cancel()
            payload = nil
            onFailure = nil
            web?.evaluateJavaScript("window.TokenstatModel?.dispose()", completionHandler: nil)
            web = nil
        }
    }
}

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#else
private typealias ViewRepresentable = UIViewRepresentable
#endif

#if os(iOS)
/// Keeps a drag that starts on a 3D model for the model.
///
/// The chat transcript and a sheet's pull-down are pan recognizers on an
/// ancestor view. They took a vertical drag before the model's own orbit
/// handling saw it, so turning the model moved the page instead. This begins
/// on touch down, never cancels the model's touches, and makes every ancestor
/// pan except the edge swipe wait for it to fail, which it does not do while
/// a finger is down.
final class ModelTouchClaim: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var touching: Set<UITouch> = []

    static func attach(to view: UIView) {
        view.addGestureRecognizer(ModelTouchClaim())
    }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touching.formUnion(touches)
        if state == .possible { state = .began } else if state == .began || state == .changed { state = .changed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        touching.subtract(touches)
        if touching.isEmpty { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        touching.subtract(touches)
        if touching.isEmpty { state = .cancelled }
    }

    override func reset() {
        super.reset()
        touching = []
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        // The edge swipe back stays available: it starts outside the model's
        // inset and nobody means to orbit from the screen edge.
        guard other is UIPanGestureRecognizer, !(other is UIScreenEdgePanGestureRecognizer),
              let mine = view, let theirs = other.view else { return false }
        return mine !== theirs && mine.isDescendant(of: theirs)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
