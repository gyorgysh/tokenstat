// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Whether this copy of the app came from TestFlight or from App Review rather
/// than from the App Store.
///
/// Exists for one reason: every screen in the client is behind a sign-in, and
/// sign-in is Apple, Google, GitHub or X through a page. There is no password
/// field, so Apple's usual "here are the demo account details" cannot be
/// honoured. A reviewer needs a door, and that door must not exist for anybody
/// who installed the app normally.
///
/// What this gates is a query flag on the sign-in page, nothing more. The
/// account it leads to is a real one on the account service, and whether the
/// page offers it is the site's decision. Read `ClientWebAuth.start`.
///
/// The receipt is what tells them apart. A build delivered by TestFlight, and a
/// build App Review is running, carry `sandboxReceipt`; an App Store install
/// carries `receipt`. App Review therefore sees the door, which is the point,
/// and a paying customer does not.
///
/// **Fails closed.** No receipt at all, or a name this does not recognise, and
/// the answer is no. A check that guesses yes when it cannot tell is a check
/// that ships a demo door to everybody the first time Apple changes a filename.
enum ReviewBuild {
    static let isTestFlight: Bool = {
        #if targetEnvironment(simulator)
        // A simulator has no receipt, and a developer running one is not a
        // reviewer. Debug builds get the door so the flow can be worked on;
        // a release build in a simulator does not.
        #if DEBUG
        return true
        #else
        return false
        #endif
        #else
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return url.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}
