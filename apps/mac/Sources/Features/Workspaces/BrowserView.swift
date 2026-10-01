// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI
import WebKit

/// A lightweight project browser, useful for local dev servers and previews.
struct BrowserView: View {
    var initialURL: String
    var onURLChange: (String, BrowserNavigationEpoch.Completion) -> Bool
    var allowsExternalNavigation: Bool
    var navigationGeneration: Int
    var loadRevision: Int
    var displayURL: String?
    var recentPorts: [Int]
    var onNavigate: ((String) -> Void)?
    var displayAddress: ((String) -> String)?
    var onLocalNavigation: ((URLRequest, Bool) -> Bool)?

    /// What the user is typing. Never what the page is: a half-typed URL must
    /// not start loading, or the first keystroke throws a DNS error.
    @State private var text: String
    /// The address the page actually shows, set only on a committed
    /// navigation (Enter, a link, or the initial URL).
    @State private var loadedURL: String
    @State private var command: BrowserCommand = .none
    @State private var commandID = 0
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var loadError = ""
    /// A non-loopback URL waiting for the user's go-ahead.
    @State private var remoteURL: RemoteNavigation?

    init(url: String, allowsExternalNavigation: Bool = false, navigationGeneration: Int = 0, loadRevision: Int = 0, displayURL: String? = nil,
         recentPorts: [Int] = [], onNavigate: ((String) -> Void)? = nil,
         displayAddress: ((String) -> String)? = nil, onLocalNavigation: ((URLRequest, Bool) -> Bool)? = nil,
         onURLChange: @escaping (String, BrowserNavigationEpoch.Completion) -> Bool) {
        initialURL = url
        self.allowsExternalNavigation = allowsExternalNavigation
        self.onURLChange = onURLChange
        self.navigationGeneration = navigationGeneration
        self.loadRevision = loadRevision
        self.displayURL = displayURL
        self.recentPorts = recentPorts
        self.onNavigate = onNavigate
        self.displayAddress = displayAddress
        self.onLocalNavigation = onLocalNavigation
        _text = State(initialValue: displayURL ?? url)
        _loadedURL = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !loadError.isEmpty {
                Banner(text: loadError, severity: .danger)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.xs)
            }
            ThemeRule()
            if loadedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else {
                WebBrowser(
                    allowsExternalNavigation: allowsExternalNavigation,
                    url: normalizedURL(loadedURL),
                    navigationGeneration: navigationGeneration,
                    command: command,
                    commandID: commandID,
                    onURLChange: { url, completion in
                        guard completion.generation == navigationGeneration, onURLChange(url, completion) else { return false }
                        text = displayAddress?(url) ?? url
                        loadedURL = url
                        return true
                    },
                    onRemoteNavigation: { url in
                        if allowsExternalNavigation { navigate(to: url) }
                        else { remoteURL = RemoteNavigation(url: url) }
                    },
                    onLoadingChange: { isLoading = $0 },
                    onHistoryChange: { back, forward in canGoBack = back; canGoForward = forward },
                    onError: { loadError = $0 },
                    onLocalNavigation: onLocalNavigation
                )
            }
        }
        .background(Theme.background)
        .alert(item: $remoteURL) { item in
            Alert(
                title: Text("Open an external site?"),
                message: Text(
                    "\(item.url.host ?? item.url.absoluteString) is not a local development server. It will load inside the app's browser."
                ),
                primaryButton: .default(Text("Open")) {
                    navigate(to: item.url)
                },
                secondaryButton: .cancel()
            )
        }
        .onChange(of: initialURL) { _, newURL in
            guard newURL != loadedURL else { return }
            text = displayURL ?? newURL
            loadedURL = newURL
            loadError = ""
            if loadRevision == 0 { send(.navigate) }
        }
        .onChange(of: loadRevision) { _, _ in
            loadedURL = initialURL
            text = displayURL ?? initialURL
            loadError = ""
            send(.navigate)
        }
        .onChange(of: displayURL) { _, address in
            if let address { text = address }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.xs) {
            Button { send(.back) } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back")
            .accessibilityLabel("Back")
            .disabled(!canGoBack)
            Button { send(.forward) } label: {
                Image(systemName: "chevron.right")
            }
            .help("Forward")
            .accessibilityLabel("Forward")
            .disabled(!canGoForward)
            Button { send(isLoading ? .stop : .reload) } label: {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(isLoading ? "Stop loading" : "Reload")
            .accessibilityLabel(isLoading ? "Stop loading" : "Reload")
            .disabled(loadedURL.isEmpty)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, Theme.Space.xs)
                    .accessibilityLabel("Loading")
            }

            TextField("Enter a URL, for example localhost:8000", text: $text)
                .textFieldStyle(.themed)
                .font(Theme.mono(11))
                .onSubmit { commit(text) }

            if !recentPorts.isEmpty {
                Menu {
                    ForEach(recentPorts, id: \.self) { port in
                        Button(String(port), .browser) { text = "http://127.0.0.1:\(port)/" }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .help("Recent ports for this project")
                .accessibilityLabel("Recent project ports")
            }

            Button("Go", .next) { commit(text) }
                .buttonStyle(AccentButtonStyle(small: true))
                .controlSize(.small)
            Button {
                if let url = normalizedURL(loadedURL) { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .disabled(loadedURL.isEmpty)
            .help("Open in default browser")
            .accessibilityLabel("Open in default browser")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(Theme.panel)
    }

    private func send(_ next: BrowserCommand) {
        command = next
        commandID += 1
    }

    private func commit(_ raw: String) {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        if let target = BrowserTarget(candidate), let url = URL(string: target.url) {
            navigate(to: url)
            return
        }
        if candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
            loadError = "Choose a port from 1 to 65535."
            return
        }
        if !candidate.contains("://") {
            // Local dev servers are plain HTTP; anything else defaults to
            // HTTPS so a mistyped or remote site is never sent in the clear.
            let probe = URL(string: "http://\(candidate)")
            candidate = (probe.map(isLoopbackHost) ?? true)
                ? "http://\(candidate)"
                : "https://\(candidate)"
        }
        guard let url = URL(string: candidate) else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            NSWorkspace.shared.open(url)
            return
        }
        if !allowsExternalNavigation && !isLoopbackHost(url) {
            // The browser is for local dev servers. A remote site deserves an
            // explicit go-ahead before it loads inside the app's chrome.
            remoteURL = RemoteNavigation(url: url)
            return
        }
        navigate(to: url)
    }

    private func navigate(to url: URL) {
        if let onNavigate {
            onNavigate(url.absoluteString)
            return
        }
        text = url.absoluteString
        loadedURL = url.absoluteString
        loadError = ""
        _ = onURLChange(loadedURL, .init(generation: navigationGeneration, registered: true))
        send(.navigate)
    }

    private func normalizedURL(_ raw: String) -> URL? {
        URL(string: raw.contains("://") ? raw : "http://\(raw)")
    }
}

/// A non-loopback URL the user has not approved yet.
private struct RemoteNavigation: Identifiable {
    var id: String { url.absoluteString }
    let url: URL
}

/// Whether a URL points at this machine. The browser exists for local dev
/// servers, so anything else is treated as external and asked about first.
private func isLoopbackHost(_ url: URL) -> Bool {
    // Missing host is not loopback: fail closed so odd URLs get a confirm.
    guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
    return BrowserTarget.isLoopback(host)
}

private extension BrowserView {
    var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "globe")
                .font(Theme.font(34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Open a project preview")
                .font(Theme.title3.weight(.medium))
            Text("Enter a local development server or any URL above.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private enum BrowserCommand {
    case none, navigate, back, forward, reload, stop
}

private struct WebBrowser: NSViewRepresentable {
    var allowsExternalNavigation: Bool
    var url: URL?
    var navigationGeneration: Int
    var command: BrowserCommand
    var commandID: Int
    var onURLChange: (String, BrowserNavigationEpoch.Completion) -> Bool
    var onRemoteNavigation: (URL) -> Void
    var onLoadingChange: (Bool) -> Void
    var onHistoryChange: (Bool, Bool) -> Void
    var onError: (String) -> Void
    var onLocalNavigation: ((URLRequest, Bool) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowsExternalNavigation: allowsExternalNavigation,
            onURLChange: onURLChange,
            onRemoteNavigation: onRemoteNavigation,
            onLoadingChange: onLoadingChange,
            onHistoryChange: onHistoryChange,
            onError: onError,
            onLocalNavigation: onLocalNavigation
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        // A deterministic, current Safari UA: some sites treat a bare WebKit
        // UA as a bot and stall instead of answering.
        view.customUserAgent = Self.safariUserAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.epochs.current = navigationGeneration
        if let url {
            context.coordinator.epochs.register(view.load(URLRequest(url: url)), generation: navigationGeneration)
        }
        context.coordinator.webView = view
        context.coordinator.onLocalNavigation = onLocalNavigation
        context.coordinator.lastCommandID = commandID
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.webView = view
        context.coordinator.onLocalNavigation = onLocalNavigation
        context.coordinator.onURLChange = onURLChange
        context.coordinator.epochs.current = navigationGeneration
        view.customUserAgent = Self.safariUserAgent
        guard context.coordinator.lastCommandID != commandID else { return }
        context.coordinator.lastCommandID = commandID
        switch command {
        case .navigate:
            if let url { context.coordinator.epochs.register(view.load(URLRequest(url: url)), generation: navigationGeneration) }
        case .back:
            if view.canGoBack { context.coordinator.epochs.register(view.goBack(), generation: navigationGeneration) }
        case .forward:
            if view.canGoForward { context.coordinator.epochs.register(view.goForward(), generation: navigationGeneration) }
        case .reload:
            context.coordinator.epochs.register(view.reload(), generation: navigationGeneration)
        case .stop:
            view.stopLoading()
            DispatchQueue.main.async { onLoadingChange(false) }
        case .none:
            break
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        coordinator.webView = nil
    }

    /// Matches the current macOS Safari so the site negotiates with a browser
    /// it recognises rather than a WebKit shell.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let allowsExternalNavigation: Bool
        weak var webView: WKWebView?
        var lastCommandID: Int = 0
        var epochs = BrowserNavigationEpoch()
        var onURLChange: (String, BrowserNavigationEpoch.Completion) -> Bool
        let onRemoteNavigation: (URL) -> Void
        let onLoadingChange: (Bool) -> Void
        let onHistoryChange: (Bool, Bool) -> Void
        let onError: (String) -> Void
        var onLocalNavigation: ((URLRequest, Bool) -> Bool)?

        init(
            allowsExternalNavigation: Bool,
            onURLChange: @escaping (String, BrowserNavigationEpoch.Completion) -> Bool,
            onRemoteNavigation: @escaping (URL) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onHistoryChange: @escaping (Bool, Bool) -> Void,
            onError: @escaping (String) -> Void,
            onLocalNavigation: ((URLRequest, Bool) -> Bool)?
        ) {
            self.allowsExternalNavigation = allowsExternalNavigation
            self.onURLChange = onURLChange
            self.onRemoteNavigation = onRemoteNavigation
            self.onLoadingChange = onLoadingChange
            self.onHistoryChange = onHistoryChange
            self.onError = onError
            self.onLocalNavigation = onLocalNavigation
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard epochs.started(navigation) else { return }
            onLoadingChange(true)
            onError("")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard epochs.finish(navigation) != nil else { return }
            onLoadingChange(false)
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            guard epochs.finish(navigation) != nil else { return }
            onLoadingChange(false)
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }

        /// Links inside a page can leave localhost; ask before letting them,
        /// the same way a typed address is asked about. Navigations the page
        /// itself starts through the current listener stay allowed. Unmapped
        /// remote forms and frames cannot fall back to this computer.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if onLocalNavigation?(navigationAction.request, navigationAction.targetFrame?.isMainFrame != false) == true {
                decisionHandler(.cancel)
                return
            }
            if let url = navigationAction.request.url, isLoopbackHost(url), BrowserTarget(url.absoluteString) == nil {
                decisionHandler(.cancel)
                return
            }
            if let url = navigationAction.request.url,
               !["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") {
                if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            if !allowsExternalNavigation, navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               !isLoopbackHost(url)
            {
                onRemoteNavigation(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                if onLocalNavigation?(navigationAction.request, true) == true { return nil }
                if (allowsExternalNavigation || isLoopbackHost(url)) && (!isLoopbackHost(url) || BrowserTarget(url.absoluteString) != nil) {
                    epochs.register(webView.load(navigationAction.request), generation: epochs.current)
                } else {
                    onRemoteNavigation(url)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let completion = epochs.finish(navigation) else { return }
            onLoadingChange(false)
            onHistoryChange(webView.canGoBack, webView.canGoForward)
            if let url = webView.url?.absoluteString {
                _ = onURLChange(url, completion)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLoadingChange(false)
            onError("The page stopped responding. Reload to try again.")
        }
    }
}
#endif
