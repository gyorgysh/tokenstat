// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SafariServices
import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Presents website pages without sending the person away from the app.
/// Safari still owns the page, cookies, reader controls and dismissal gesture.
///
/// `mobile=1` is what the site uses to drop the header, footer and marketing
/// links. App Review treats a full website in this sheet as a way to leave
/// the app. The flag is layout only.
struct ClientWebBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: ClientWebPages.withMobileFlag(url))
    }

    func updateUIViewController(_ viewController: SFSafariViewController, context: Context) {}
}

#endif
