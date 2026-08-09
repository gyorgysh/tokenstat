// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

#if os(iOS)
import SwiftUI
import WebKit

/// The website's data settings in an in-app web view.
///
/// App Store Guideline 5.1.1(v) requires account deletion to be available
/// within the app. A Safari link alone is sometimes rejected. Presenting the
/// website's own delete page here lets the user start and finish deletion
/// without leaving the app, and needs no backend endpoint of our own.
struct AccountDeletionWebView: UIViewRepresentable {
    var url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
