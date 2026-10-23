// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// A chart is an offline document, with no access to a browser profile or host methods.
struct ChatChartView: View {
    let source: String
    var pending = false
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 430
    @State private var exportData = Data()
    @State private var exportType = UTType.json
    @State private var exportName = "chart.json"
    @State private var exporting = false
    @State private var failure: String?

    var body: some View {
        Group {
            if pending {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("common.chart.loading")).font(Theme.callout)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else if source.utf8.count > 256 * 1024 {
                Text(L10n.text("common.chart.too_large")).font(Theme.callout).padding(16)
            } else {
                ChartWebView(source: source, dark: colorScheme == .dark, panel: Theme.panel.resolve(in: environment), reduceMotion: reduceMotion,
                             height: $height, onExport: export, onError: { failure = $0 })
                    .frame(height: height)
                    .background(Theme.panel)
                    .accessibilityIdentifier("chat.chart")
            }
        }
        .fileExporter(isPresented: $exporting, document: ChartExportDocument(data: exportData),
                      contentType: exportType, defaultFilename: exportName) { result in
            if case let .failure(error) = result { failure = error.localizedDescription }
            exportData = Data()
        }
        .alert(L10n.text("common.chart.unavailable"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("common.close")) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func export(_ format: String, _ data: Data) {
        guard !exporting else { return }
        let types: [String: UTType] = ["png": .png, "svg": .svg, "csv": .commaSeparatedText, "json": .json]
        guard let type = types[format] else { return }
        exportType = type; exportName = "chart.\(format)"; exportData = data; exporting = true
    }
}

private struct ChartExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

#if os(macOS)
private typealias ChartRepresentable = NSViewRepresentable
#else
private typealias ChartRepresentable = UIViewRepresentable
#endif

private struct ChartWebView: ChartRepresentable {
    let source: String
    let dark: Bool
    let panel: Color.Resolved
    let reduceMotion: Bool
    @Binding var height: CGFloat
    let onExport: (String, Data) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    #if os(macOS)
    func makeNSView(context: Context) -> ChartViewportView { makeViewport(context.coordinator) }
    func updateNSView(_ view: ChartViewportView, context: Context) { context.coordinator.update(self); view.scheduleVisibilityUpdate() }
    static func dismantleNSView(_ view: ChartViewportView, coordinator: Coordinator) { view.shutdown(); coordinator.dispose() }
    #else
    func makeUIView(context: Context) -> ChartViewportView { makeViewport(context.coordinator) }
    func updateUIView(_ view: ChartViewportView, context: Context) { context.coordinator.update(self); view.scheduleVisibilityUpdate() }
    static func dismantleUIView(_ view: ChartViewportView, coordinator: Coordinator) { view.shutdown(); coordinator.dispose() }
    #endif

    private func makeViewport(_ coordinator: Coordinator) -> ChartViewportView {
        let view = ChartViewportView()
        view.makeContent = { [weak coordinator] in coordinator.map { $0.owner.makeView($0) } }
        view.releaseContent = { [weak coordinator] view in
            if let browser = view as? WKWebView { coordinator?.unmount(browser) }
        }
        return view
    }

    private func makeView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(coordinator, name: "chart")
        configuration.userContentController.addUserScript(WKUserScript(source: themeBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        applyNativeAppearance(view)
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        #endif
        coordinator.webView = view
        guard let directory = Bundle.main.url(forResource: "runtime", withExtension: nil),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            DispatchQueue.main.async { [weak coordinator, weak view] in
                guard let coordinator, !coordinator.stopped, let view, coordinator.webView === view else { return }
                coordinator.owner.onError(L10n.text("common.chart.resources_missing"))
            }
            return view
        }
        coordinator.pageURL = directory.appendingPathComponent("index.html")
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return view
    }

    private func applyNativeAppearance(_ view: WKWebView) {
        #if os(macOS)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = NSColor(srgbRed: Double(panel.red), green: Double(panel.green), blue: Double(panel.blue), alpha: Double(panel.opacity))
        #else
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        view.underPageBackgroundColor = UIColor(red: CGFloat(panel.red), green: CGFloat(panel.green), blue: CGFloat(panel.blue), alpha: CGFloat(panel.opacity))
        #endif
    }

    private var themeBootstrap: String {
        let scheme = dark ? "dark" : "light"
        let background = "rgba(\(Int((panel.red * 255).rounded())),\(Int((panel.green * 255).rounded())),\(Int((panel.blue * 255).rounded())),\(panel.opacity))"
        // The runtime waits for its font and its first render. Establish the
        // app's appearance before HTML/CSS can paint a default light surface.
        return """
        (() => {
            const apply = () => {
                const root = document.documentElement;
                if (!root) return false;
                root.dataset.theme = '\(scheme)';
                root.style.colorScheme = '\(scheme)';
                root.style.backgroundColor = '\(background)';
                return true;
            };
            if (!apply()) {
                const observer = new MutationObserver(() => { if (apply()) observer.disconnect(); });
                observer.observe(document, { childList: true });
            }
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var owner: ChartWebView
        weak var webView: WKWebView?
        var pageURL: URL?
        private var loaded = false
        private var rendered = ""
        fileprivate var stopped = false
        init(_ owner: ChartWebView) { self.owner = owner }
        func update(_ owner: ChartWebView) {
            let appearanceChanged = self.owner.dark != owner.dark || self.owner.panel != owner.panel
            self.owner = owner
            if appearanceChanged, let webView {
                owner.applyNativeAppearance(webView)
                let controller = webView.configuration.userContentController
                controller.removeAllUserScripts()
                controller.addUserScript(WKUserScript(source: owner.themeBootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                webView.evaluateJavaScript(owner.themeBootstrap, completionHandler: nil)
            }
            render()
        }
        func dispose() {
            stopped = true
            if let webView { unmount(webView) }
        }
        func unmount(_ browser: WKWebView) {
            guard webView === browser else { return }
            loaded = false; rendered = ""; pageURL = nil; webView = nil
            browser.stopLoading()
            browser.configuration.userContentController.removeScriptMessageHandler(forName: "chart")
            browser.navigationDelegate = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !stopped, self.webView === webView else { return }
            loaded = true; render()
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard !stopped, self.webView === webView else { return }
            // A scheme change can race a navigation that already captured its
            // document-start scripts. Reapply the latest owner at commit too.
            webView.evaluateJavaScript(owner.themeBootstrap, completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(!stopped && self.webView === webView && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == pageURL ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !stopped, self.webView === webView { owner.onError(error.localizedDescription) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !stopped, self.webView === webView { owner.onError(error.localizedDescription) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !stopped, self.webView === webView { owner.onError(L10n.text("common.chart.unavailable")) }
        }
        private func render() {
            guard loaded, !stopped, let webView, owner.source.utf8.count <= 256 * 1024 else { return }
            let settings: [String: Any] = ["dark": owner.dark, "reducedMotion": owner.reduceMotion,
                                          "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), "strings": ChartWords.all]
            guard let json = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]),
                  let settingsText = String(data: json, encoding: .utf8) else { return }
            let payload = Data(owner.source.utf8).base64EncodedString()
            let revision = payload + settingsText
            guard revision != rendered else { return }
            rendered = revision
            let script = "window.TokenstatChart.render(new TextDecoder().decode(Uint8Array.from(atob('\(payload)'), c => c.charCodeAt(0))), \(settingsText));"
            webView.evaluateJavaScript(script) { [weak self, weak webView] _, error in
                guard let self, !self.stopped, let webView, self.webView === webView else { return }
                if let error { self.owner.onError(error.localizedDescription) }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !stopped, message.frameInfo.isMainFrame, message.webView === webView,
                  message.frameInfo.request.url == pageURL, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "height":
                if let value = body["height"] as? Double, value.isFinite, (180...2200).contains(value) {
                    DispatchQueue.main.async { [weak self, weak browser = message.webView] in
                        guard let self, !self.stopped, let browser, self.webView === browser else { return }; self.owner.height = CGFloat(value)
                    }
                }
            case "copy":
                if let text = body["text"] as? String, text.utf8.count <= 64 * 1024 {
                    #if os(macOS)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    #else
                    UIPasteboard.general.string = text
                    #endif
                }
            case "export":
                guard let format = body["format"] as? String, ["png", "svg", "csv", "json"].contains(format),
                      (body["base64"] as? Bool == true) == (format == "png"),
                      let content = body["content"] as? String, content.utf8.count <= 12 * 1024 * 1024 else { return }
                let data = body["base64"] as? Bool == true ? Data(base64Encoded: content) : Data(content.utf8)
                if let data, data.count <= 8 * 1024 * 1024 { owner.onExport(format, data) }
            default: break
            }
        }
    }
}

private enum ChartWords {
    static var all: [String: String] { [
        "chart": L10n.text("common.chart.chart"), "data": L10n.text("common.chart.data"),
        "reset": L10n.text("common.chart.reset"), "expand": L10n.text("common.chart.expand"),
        "collapse": L10n.text("common.chart.collapse"), "copy": L10n.text("common.chart.copy"),
        "export": L10n.text("common.chart.export"), "choose": L10n.text("common.chart.choose"),
        "png": L10n.text("common.chart.png"), "svg": L10n.text("common.chart.svg"),
        "csv": L10n.text("common.chart.csv"), "json": L10n.text("common.chart.json"),
        "previous": L10n.text("common.chart.previous"), "next": L10n.text("common.chart.next"),
        "series": L10n.text("common.chart.series"), "category": L10n.text("common.chart.category"),
        "value": L10n.text("common.chart.value"), "missing": L10n.text("common.chart.missing"),
        "minimum": L10n.text("common.chart.minimum"), "q1": L10n.text("common.chart.q1"),
        "median": L10n.text("common.chart.median"), "q3": L10n.text("common.chart.q3"),
        "maximum": L10n.text("common.chart.maximum"), "size": L10n.text("common.chart.size"),
        "source": L10n.text("common.chart.source"), "page": L10n.text("common.chart.page"),
        "of": L10n.text("common.chart.of"), "copied": L10n.text("common.chart.copied"),
        "exported": L10n.text("common.chart.exported"), "unavailable": L10n.text("common.chart.unavailable"),
        "inspect": L10n.text("common.chart.inspect"), "loading": L10n.text("common.chart.loading")
    ] }
}
