// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import AuthenticationServices
import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Sign-in, presented over the app instead of in another one.
///
/// `ASWebAuthenticationSession` rather than a `WKWebView`, and the difference is
/// not cosmetic: the page runs in Safari's own process, so the provider session
/// and anything typed into it belong to Safari and never touch this app. A
/// login screen embedded in a downloaded app is exactly what every provider
/// tells people not to type into.
///
/// The sheet closes by itself when tokenstat.ai redirects to `tokenstat://`.
/// That redirect is not deployed yet (see the sign-in section of
/// `docs/ios-client-ui.md`), so today the session ends when the person dismisses
/// it. Either way the app is polling the device flow underneath and notices the
/// approval on its own, which is why dismissing the sheet does **not** cancel
/// signing in. Only the Cancel button on the account screen does that.
///
/// No `CFBundleURLTypes` entry is needed: the session intercepts its own
/// callback, so no other app on the phone can claim the scheme and race it.
@MainActor
final class ClientWebAuth: NSObject {
    static let shared = ClientWebAuth()

    /// The scheme the site redirects to when approval finishes.
    private static let callbackScheme = "tokenstat"

    private var session: ASWebAuthenticationSession?

    /// Present the sign-in page. Returns immediately: the outcome arrives
    /// through the device-flow polling that started this, not through here.
    func start(_ url: URL) {
        // Marks this as the client flow, so the site can render the phone
        // variant of `/link` and redirect back when it is approved. Harmless on
        // a server that does not know the parameter yet, which is the point:
        // the app ships before the website does.
        // `mobile=1` asks for the app-shaped layout: no site header, no footer,
        // no marketing column, providers as full-width rows. A query flag and
        // not a user agent, because an authentication session gives an app no
        // way to set one and sniffing strings is a losing game.
        var flags = [
            URLQueryItem(name: "app", value: "ios"),
            URLQueryItem(name: "mobile", value: "1"),
        ]
        // TestFlight and App Review only. Every screen in this app is behind a
        // sign-in, and sign-in is Apple, Google, GitHub or X through this page:
        // there is no password field, so Apple's usual "here are the demo
        // account details" cannot be honoured. The flag asks the page to offer
        // a demo account beside the four providers.
        //
        // The app carries no credential and no secret. It says which kind of
        // build this is and the site decides what that is worth, so the door
        // can be closed after a review round without a new build. Harmless on
        // a site that does not know the parameter yet, the same way `app` and
        // `mobile` were harmless before it did.
        if ReviewBuild.isTestFlight {
            flags.append(URLQueryItem(name: "review", value: "1"))
        }
        let tagged = url.appending(queryItems: flags)

        let session = ASWebAuthenticationSession(
            url: tagged,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] _, _ in
            // Both outcomes are handled the same way on purpose. A callback
            // means the site approved and polling is about to see it. A
            // dismissal means the person closed the sheet, which is not the
            // same as abandoning the sign-in: they may have approved on the
            // page just before closing it. Cancelling here would throw away an
            // approval that already happened.
            self?.session = nil
        }
        session.presentationContextProvider = self
        // Off, so the provider session the phone already has in Safari is the
        // one used. Ephemeral would make every sign-in a fresh password entry,
        // which is a worse experience bought with no privacy: this is the
        // user's own account on their own device.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

extension ClientWebAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // The active foreground window. Not `windows.first`: with a scene
            // in the background (an iPad second window, or the app during a
            // state restore) that can be a window nobody is looking at, and the
            // sheet would present onto it.
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

#endif
