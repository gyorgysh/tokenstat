// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
import WebKit

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Presents website pages without sending the person away from the app.
///
/// `SFSafariViewController` used to own these pages, but its toolbar is a
/// system control that always offers Share and Open in Safari, and the delete
/// page is a place the app wants the person to finish, not hand off. This is a
/// plain `WKWebView` with the two controls such a sheet needs and nothing else:
/// a close button and a reload. Navigation is not restricted, so an OAuth
/// provider's redirects are followed exactly as Safari would follow them and
/// a sign-in on the delete page comes back to the same sheet.
///
/// `mobile=1` is what the site uses to drop the header, footer and marketing
/// links. App Review treats a full website in this sheet as a way to leave
/// the app. The flag is layout only.
struct ClientWebBrowser: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var reloadToken = 0
    @State private var host = ""
    @State private var isLoading = false
    @State private var progress: Double = 0

    var body: some View {
        NavigationStack {
            ClientInAppWebView(
                url: ClientWebPages.withMobileFlag(url),
                reloadToken: reloadToken,
                onLoadingChange: { isLoading = $0 },
                onProgress: { progress = $0 },
                onHostChange: { if !$0.isEmpty { host = $0 } }
            )
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                if isLoading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(height: 2)
                        .animation(.linear(duration: 0.15), value: progress)
                        .transition(.opacity)
                }
            }
            .navigationTitle(host.isEmpty ? (url.host ?? "tokenstat.ai") : host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.controlGlyph)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Theme.controlSeat))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Reload")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// The `WKWebView` itself, reporting enough state for the chrome around it.
private struct ClientInAppWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    var onLoadingChange: (Bool) -> Void
    var onProgress: (Double) -> Void
    var onHostChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadingChange: onLoadingChange, onProgress: onProgress, onHostChange: onHostChange)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if reloadToken != context.coordinator.lastReloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    /// Receives navigation events and progress. `WKNavigationDelegate` fires
    /// on the main thread; `estimatedProgress` KVO is hopped there explicitly
    /// so the state setters below are always on the main thread.
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoadingChange: (Bool) -> Void
        let onProgress: (Double) -> Void
        let onHostChange: (String) -> Void
        var lastReloadToken = 0
        private var progressObservation: NSKeyValueObservation?

        init(onLoadingChange: @escaping (Bool) -> Void, onProgress: @escaping (Double) -> Void, onHostChange: @escaping (String) -> Void) {
            self.onLoadingChange = onLoadingChange
            self.onProgress = onProgress
            self.onHostChange = onHostChange
        }

        func observe(_ webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let progress = webView.estimatedProgress
                DispatchQueue.main.async {
                    self?.onProgress(progress)
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url, let host = url.host {
                onHostChange(host)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onProgress(1)
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        // Every host is allowed so an OAuth provider's redirects land: the
        // site-host restriction is what broke sign-in from the delete page the
        // first time around. Only web pages belong here, though. Allowing a
        // mailto:, tel: or custom scheme makes WKWebView stall on a navigation
        // it cannot perform, so everything else is refused.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        // A target=_blank link opens a new web view; load it here instead so
        // it never escapes this sheet.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

#endif
