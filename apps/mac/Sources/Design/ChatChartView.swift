// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import CryptoKit

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
        view.makeContent = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return nil }
            return coordinator.owner.makeView(coordinator, size: view.bounds.size)
        }
        view.releaseContent = { [weak coordinator] view in
            if let surface = view as? ChartSurfaceView { coordinator?.unmount(surface.browser) }
        }
        return view
    }

    private func makeView(_ coordinator: Coordinator, size: CGSize) -> ChartSurfaceView {
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
        let surface = ChartSurfaceView(browser: view, size: size)
        surface.prepare(revision: previewRevision, key: previewKey(width: size.width), panel: panel)
        coordinator.webView = view
        coordinator.surface = surface
        guard let directory = Bundle.main.url(forResource: "runtime", withExtension: nil),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else {
            DispatchQueue.main.async { [weak coordinator, weak view] in
                guard let coordinator, !coordinator.stopped, let view, coordinator.webView === view else { return }
                coordinator.owner.onError(L10n.text("common.chart.resources_missing"))
            }
            return surface
        }
        coordinator.pageURL = directory.appendingPathComponent("index.html")
        view.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        return surface
    }

    private var previewRevision: String {
        source + "\u{0}" + String(dark) + String(describing: panel) + String(reduceMotion) + Locale.current.identifier + String(describing: ChartWords.all.sorted { $0.key < $1.key })
    }

    fileprivate func previewKey(width: CGFloat) -> String {
        SHA256.hash(data: Data((previewRevision + "\u{0}" + String(Int(width.rounded()))).utf8))
            .map { String(format: "%02x", $0) }.joined()
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
        fileprivate weak var surface: ChartSurfaceView?
        private var capturing = false
        private var pendingCapture = false
        var pageURL: URL?
        private var loaded = false
        private var rendered = ""
        fileprivate var stopped = false
        init(_ owner: ChartWebView) { self.owner = owner }
        func update(_ owner: ChartWebView) {
            let appearanceChanged = self.owner.dark != owner.dark || self.owner.panel != owner.panel
            self.owner = owner
            if let surface {
                surface.prepare(revision: owner.previewRevision, key: owner.previewKey(width: surface.bounds.width), panel: owner.panel)
            }
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
            loaded = false; rendered = ""; pageURL = nil; webView = nil; surface = nil; capturing = false; pendingCapture = false
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
            let settings: [String: Any] = ["dark": owner.dark, "reducedMotion": owner.reduceMotion, "skipEntryAnimation": true,
                                          "paintToken": owner.previewKey(width: 0), "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), "strings": ChartWords.all]
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
        private func capturePaint() {
            guard loaded, !stopped, let webView, let surface, surface.isWaitingForPaint else { return }
            guard !capturing else { pendingCapture = true; return }
            capturing = true
            pendingCapture = false
            let revision = rendered
            let key = owner.previewKey(width: webView.bounds.width)
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 900)))
            webView.takeSnapshot(with: configuration) { [weak self, weak webView, weak surface] image, _ in
                guard let self, !self.stopped, let webView, self.webView === webView,
                      let surface, self.surface === surface else { return }
                self.capturing = false
                guard self.rendered == revision else {
                    if self.pendingCapture { self.capturePaint() }
                    return
                }
                guard let image else {
                    #if DEBUG && os(macOS)
                    ChartPaintDiagnostics.record(surface, event: "snapshot-error")
                    #endif
                    self.owner.onError(L10n.text("common.chart.unavailable"))
                    return
                }
                ChartPreviewCache.store(image, key: key)
                surface.reveal()
                #if DEBUG && os(macOS)
                ChartPaintDiagnostics.capture(surface, image: image, event: "painted")
                #endif
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !stopped, message.frameInfo.isMainFrame, message.webView === webView,
                  message.frameInfo.request.url == pageURL, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready", "error":
                if let token = body["paintToken"] as? String, token == owner.previewKey(width: 0) {
                    #if DEBUG && os(macOS)
                    if let surface { ChartPaintDiagnostics.record(surface, event: type) }
                    #endif
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.owner.previewKey(width: 0) == token else { return }
                        self.capturePaint()
                    }
                }
            case "height":
                guard let token = body["paintToken"] as? String, token == owner.previewKey(width: 0) else { return }
                if let value = body["height"] as? Double, value.isFinite, (180...2200).contains(value) {
                    DispatchQueue.main.async { [weak self, weak browser = message.webView] in
                        guard let self, !self.stopped, let browser, self.webView === browser,
                              self.owner.previewKey(width: 0) == token else { return }
                        self.owner.height = CGFloat(value)
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

#if os(macOS)
private typealias ChartPreviewImage = NSImage
private final class ChartPreviewImageView: NSImageView {
    var panelColor = NSColor.clear
    override var isOpaque: Bool { panelColor.alphaComponent == 1 }
    override func draw(_ dirtyRect: NSRect) {
        panelColor.setFill(); bounds.fill()
        super.draw(dirtyRect)
    }
}
#else
private typealias ChartPreviewImage = UIImage
private typealias ChartPreviewImageView = UIImageView
#endif

private enum ChartPreviewCache {
    private final class Entry: NSObject {
        let image: ChartPreviewImage
        init(_ image: ChartPreviewImage) { self.image = image }
    }
    private static let images: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 12
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static var costs: [String: Int] = [:]
    private static var order: [String] = []
    private static var bytes = 0
    private static func remove(_ key: String) {
        images.removeObject(forKey: key as NSString)
        bytes -= costs.removeValue(forKey: key) ?? 0
        order.removeAll { $0 == key }
    }
    #if DEBUG
    static var statistics: (count: Int, bytes: Int) { (order.count, bytes) }
    #endif
    static func image(for key: String) -> ChartPreviewImage? {
        guard let image = images.object(forKey: key as NSString)?.image else { remove(key); return nil }
        order.removeAll { $0 == key }; order.append(key)
        return image
    }
    static func store(_ image: ChartPreviewImage, key: String) {
        #if os(macOS)
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        #else
        let pixels = (image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0)
        #endif
        guard pixels > 0, pixels <= 2 * 1024 * 1024 else { return }
        let cost = pixels * 4
        remove(key)
        while (bytes + cost > 32 * 1024 * 1024 || order.count >= 12), let oldest = order.first { remove(oldest) }
        images.setObject(Entry(image), forKey: key as NSString, cost: cost)
        costs[key] = cost; bytes += cost; order.append(key)
    }
}

/// The browser's first native surface can paint before its document/runtime.
/// Keep it behind an opaque native panel or the previous rendered preview.
private final class ChartSurfaceView: ChartViewportContent {
    let browser: WKWebView
    private let preview = ChartPreviewImageView()
    private var revision = ""
    private(set) var isWaitingForPaint = true
    #if os(macOS)
    private var panelColor = NSColor.clear
    override var isOpaque: Bool { panelColor.alphaComponent == 1 }
    override func draw(_ dirtyRect: NSRect) { panelColor.setFill(); bounds.fill() }
    #endif
    #if DEBUG && os(macOS)
    fileprivate let diagnosticID = UUID().uuidString
    fileprivate var hasPreview: Bool { preview.image != nil }
    fileprivate var diagnosticKey: String {
        SHA256.hash(data: Data(revision.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #endif
    init(browser: WKWebView, size: CGSize) {
        self.browser = browser
        super.init(frame: CGRect(origin: .zero, size: size))
        #if os(macOS)
        wantsLayer = true
        preview.imageScaling = .scaleAxesIndependently
        preview.wantsLayer = true
        preview.setAccessibilityElement(false)
        #else
        preview.contentMode = .scaleToFill
        preview.isAccessibilityElement = false
        #endif
        for child in [browser, preview] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func prepare(revision: String, key: String, panel: Color.Resolved) {
        guard revision != self.revision else { return }
        self.revision = revision
        isWaitingForPaint = true
        preview.image = ChartPreviewCache.image(for: key)
        preview.isHidden = false
        #if os(macOS)
        panelColor = NSColor(srgbRed: Double(panel.red), green: Double(panel.green), blue: Double(panel.blue), alpha: Double(panel.opacity))
        layer?.backgroundColor = panelColor.cgColor
        preview.panelColor = panelColor
        preview.layer?.backgroundColor = panelColor.cgColor
        preview.needsDisplay = true
        needsDisplay = true
        #else
        backgroundColor = UIColor(red: CGFloat(panel.red), green: CGFloat(panel.green), blue: CGFloat(panel.blue), alpha: CGFloat(panel.opacity))
        preview.backgroundColor = backgroundColor
        preview.isOpaque = panel.opacity == 1
        #endif
        #if DEBUG && os(macOS)
        DispatchQueue.main.async { [weak self] in
            if let self, self.isWaitingForPaint { ChartPaintDiagnostics.capture(self, event: "covered") }
        }
        #endif
    }
    func reveal() {
        isWaitingForPaint = false
        preview.isHidden = true
    }
}

#if DEBUG && os(macOS)
/// Opt-in, bounded captures of this app's own chart views for local scroll QA.
/// Does not use Screen Recording APIs, other windows, or default diagnostics.
private enum ChartPaintDiagnostics {
    private static var count = 0
    private static var records = 0
    private static let started = ProcessInfo.processInfo.systemUptime
    private static var chartCounts: [String: Int] = [:]
    private static func directory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["TOKENSTAT_CHART_QA_DIR"],
              path.hasPrefix("/tmp/tokenstat-chart-") else { return nil }
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent().path == "/tmp" else { return nil }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            return target
        } catch { return nil }
    }
    static func record(_ surface: ChartSurfaceView, event: String, file: String? = nil) {
        guard records < 96, let target = directory() else { return }
        let entry: [String: Any] = ["seconds": max(0, ProcessInfo.processInfo.systemUptime - started),
                                   "event": event, "chart": surface.diagnosticKey, "instance": surface.diagnosticID,
                                   "covered": surface.isWaitingForPaint, "cachedPreview": surface.hasPreview,
                                   "width": surface.bounds.width, "height": surface.bounds.height, "file": file ?? "",
                                   "previewCacheBytes": ChartPreviewCache.statistics.bytes, "previewCacheCount": ChartPreviewCache.statistics.count]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        let log = target.appendingPathComponent("events.jsonl")
        do {
            if !FileManager.default.fileExists(atPath: log.path) { try Data().write(to: log) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            records += 1
        } catch { /* Diagnostic failures never affect a chart. */ }
    }
    static func capture(_ surface: ChartSurfaceView, image: NSImage? = nil, event: String) {
        guard count < 24, let target = directory(), !surface.bounds.isEmpty else { return }
        let key = surface.diagnosticKey
        guard chartCounts[key, default: 0] < 4 else { return }
        do {
            let bitmap: NSBitmapImageRep?
            if let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                bitmap = NSBitmapImageRep(cgImage: cgImage)
            } else {
                bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)
                if let bitmap { surface.cacheDisplay(in: surface.bounds, to: bitmap) }
            }
            guard let bitmap, let cgImage = bitmap.cgImage else { return }
            let scale = min(1, 640 / CGFloat(bitmap.pixelsWide), 480 / CGFloat(bitmap.pixelsHigh))
            let width = max(1, Int(CGFloat(bitmap.pixelsWide) * scale)), height = max(1, Int(CGFloat(bitmap.pixelsHigh) * scale))
            guard let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: small) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSImage(cgImage: cgImage, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = small.representation(using: .png, properties: [:]) else { return }
            let name = String(format: "%03d-%@.png", count, event)
            count += 1; chartCounts[key, default: 0] += 1
            let file = target.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            record(surface, event: event + "-frame", file: name)
        } catch { /* Diagnostic failures never affect a chart. */ }
    }
}
#endif

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
