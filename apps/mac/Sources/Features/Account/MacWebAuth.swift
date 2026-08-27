// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import AuthenticationServices
import SwiftUI

#if os(macOS)

/// Sign-in, in a sheet over the app rather than in the whole browser.
///
/// The Mac used to hand the device-flow URL to the default browser, which
/// dropped somebody into the full website — header, language switcher, footer
/// full of marketing links — to press one button. `app=mac` asks the site for
/// the same one-question page the phone gets, and this presents it attached to
/// the window that asked.
///
/// `ASWebAuthenticationSession` rather than a `WKWebView`, for the reason the
/// phone's `ClientWebAuth` gives: the page runs in Safari's own process, so a
/// provider login never touches this app.
///
/// Dismissing the sheet does **not** cancel signing in. The device-flow poll is
/// running underneath and notices the approval on its own, and somebody may
/// have approved on the page a moment before closing it. Only Cancel on the
/// Account screen stops it.
@MainActor
final class MacWebAuth: NSObject {
    static let shared = MacWebAuth()

    /// The scheme the site redirects to when approval finishes. The same one
    /// the phone uses, because it is the same approval.
    private static let callbackScheme = "tokenstat"

    private var session: ASWebAuthenticationSession?

    func start(_ url: URL) {
        // `app=mac` and not `mobile=1`: the Mac wants the site's chrome gone,
        // not the phone's full-width layout.
        let tagged = url.appending(queryItems: [URLQueryItem(name: "app", value: "mac")])

        let session = ASWebAuthenticationSession(
            url: tagged,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] _, _ in
            self?.session = nil
        }
        session.presentationContextProvider = self
        // Off, so the provider session already in Safari is the one used.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

extension MacWebAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // The window somebody is looking at. `windows.first` can be a
            // panel or a window behind everything else, and the sheet would
            // attach to that.
            NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
        }
    }
}

#endif
