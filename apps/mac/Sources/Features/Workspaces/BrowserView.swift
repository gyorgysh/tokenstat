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
    var onURLChange: (String) -> Void

    /// What the user is typing. Never what the page is: a half-typed URL must
    /// not start loading, or the first keystroke throws a DNS error.
    @State private var text: String
    /// The address the page actually shows, set only on a committed
    /// navigation (Enter, a link, or the initial URL).
    @State private var loadedURL: String
    @State private var command: BrowserCommand = .none
    @State private var commandID = 0
    @State private var isLoading = false
    @State private var loadError = ""
    /// A non-loopback URL waiting for the user's go-ahead.
    @State private var remoteURL: RemoteNavigation?

    init(url: String, onURLChange: @escaping (String) -> Void) {
        initialURL = url
        self.onURLChange = onURLChange
        _text = State(initialValue: url)
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
                    url: normalizedURL(loadedURL),
                    command: command,
                    commandID: commandID,
                    onURLChange: { url in
                        text = url
                        loadedURL = url
                        onURLChange(url)
                    },
                    onRemoteNavigation: { url in
                        remoteURL = RemoteNavigation(url: url)
                    },
                    onLoadingChange: { isLoading = $0 },
                    onError: { loadError = $0 }
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
            text = newURL
            commit(newURL)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.xs) {
            Button { send(.back) } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back")
            .accessibilityLabel("Back")
            Button { send(.forward) } label: {
                Image(systemName: "chevron.right")
            }
            .help("Forward")
            .accessibilityLabel("Forward")
            Button { send(.reload) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
            .accessibilityLabel("Reload")
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

            Button("Go", .next) { commit(text) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
        if !candidate.contains("://") {
            // Local dev servers are plain HTTP; anything else defaults to
            // HTTPS so a mistyped or remote site is never sent in the clear.
            let probe = URL(string: "http://\(candidate)")
            candidate = (probe.map(isLoopbackHost) ?? true)
                ? "http://\(candidate)"
                : "https://\(candidate)"
        }
        guard let url = URL(string: candidate) else { return }
        if !isLoopbackHost(url) {
            // The browser is for local dev servers. A remote site deserves an
            // explicit go-ahead before it loads inside the app's chrome.
            remoteURL = RemoteNavigation(url: url)
            return
        }
        navigate(to: url)
    }

    private func navigate(to url: URL) {
        text = url.absoluteString
        loadedURL = url.absoluteString
        loadError = ""
        onURLChange(loadedURL)
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
    if host == "localhost" || host == "::1" || host == "0.0.0.0" {
        return true
    }
    // IPv4 127.0.0.0/8 only when every label is numeric (not 127.evil.com).
    let parts = host.split(separator: ".")
    if parts.count == 4,
       parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
       parts[0] == "127" {
        return true
    }
    return false
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
    case none, navigate, back, forward, reload
}

private struct WebBrowser: NSViewRepresentable {
    var url: URL?
    var command: BrowserCommand
    var commandID: Int
    var onURLChange: (String) -> Void
    var onRemoteNavigation: (URL) -> Void
    var onLoadingChange: (Bool) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onURLChange: onURLChange,
            onRemoteNavigation: onRemoteNavigation,
            onLoadingChange: onLoadingChange,
            onError: onError
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        // A deterministic, current Safari UA: some sites treat a bare WebKit
        // UA as a bot and stall instead of answering.
        view.customUserAgent = Self.safariUserAgent
        view.navigationDelegate = context.coordinator
        if let url {
            view.load(URLRequest(url: url))
        }
        context.coordinator.webView = view
        context.coordinator.lastCommandID = commandID
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.webView = view
        view.customUserAgent = Self.safariUserAgent
        guard context.coordinator.lastCommandID != commandID else { return }
        context.coordinator.lastCommandID = commandID
        switch command {
        case .navigate:
            if let url { view.load(URLRequest(url: url)) }
        case .back:
            if view.canGoBack { view.goBack() }
        case .forward:
            if view.canGoForward { view.goForward() }
        case .reload:
            view.reload()
        case .none:
            break
        }
    }

    /// Matches the current macOS Safari so the site negotiates with a browser
    /// it recognises rather than a WebKit shell.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastCommandID: Int = 0
        let onURLChange: (String) -> Void
        let onRemoteNavigation: (URL) -> Void
        let onLoadingChange: (Bool) -> Void
        let onError: (String) -> Void

        init(
            onURLChange: @escaping (String) -> Void,
            onRemoteNavigation: @escaping (URL) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onURLChange = onURLChange
            self.onRemoteNavigation = onRemoteNavigation
            self.onLoadingChange = onLoadingChange
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
            onError("")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadingChange(false)
            onError(error.localizedDescription)
        }

        /// Links inside a page can leave localhost; ask before letting them,
        /// the same way a typed address is asked about. Navigations the page
        /// itself starts (scripts, form posts) stay allowed — blocking those
        /// breaks real local apps.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               !isLoopbackHost(url)
            {
                onRemoteNavigation(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
            if let url = webView.url?.absoluteString {
                onURLChange(url)
            }
        }
    }
}
#endif
