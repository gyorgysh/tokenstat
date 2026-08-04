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

    @State private var address: String
    @State private var command: BrowserCommand = .none
    @State private var commandID = 0

    init(url: String, onURLChange: @escaping (String) -> Void) {
        initialURL = url
        self.onURLChange = onURLChange
        _address = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState
            } else {
                WebBrowser(
                    url: normalizedURL(address),
                    command: command,
                    commandID: commandID,
                    onURLChange: { url in
                        address = url
                        onURLChange(url)
                    }
                )
            }
        }
        .background(Theme.background)
        .onChange(of: initialURL) { _, newURL in
            guard newURL != address else { return }
            address = newURL
            navigate()
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.xs) {
            Button { send(.back) } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back")
            Button { send(.forward) } label: {
                Image(systemName: "chevron.right")
            }
            .help("Forward")
            Button { send(.reload) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            TextField("Enter a URL, for example localhost:8000", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(11))
                .onSubmit { navigate() }

            Button("Go") { navigate() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
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

    private func navigate() {
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        if !address.contains("://") {
            address = "http://\(address)"
        }
        onURLChange(address)
        send(.navigate)
    }

    private func normalizedURL(_ raw: String) -> URL? {
        URL(string: raw.contains("://") ? raw : "http://\(raw)")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Open a project preview")
                .font(.title3.weight(.medium))
            Text("Enter a local development server or any URL above.")
                .font(.callout)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastCommandID: Int = 0
        let onURLChange: (String) -> Void

        init(onURLChange: @escaping (String) -> Void) {
            self.onURLChange = onURLChange
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url?.absoluteString {
                onURLChange(url)
            }
        }
    }
}
#endif
