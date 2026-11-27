// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L10n.text("common.unknown")
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? L10n.text("common.unknown")
    }

    static var versionString: String { "\(version) (\(build))" }

    /// Copyright line, taken from the bundle so the app and the generated
    /// Info.plist cannot disagree about the year or the company.
    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? L10n.text("apple.appinfo.pueev_o_all_rights_reserved.b1734f76")
    }

    static let referrer = "tokenstat_app"

    static let website = URL(string: "https://tokenstat.ai/?ref=\(referrer)")!
    static let websiteLabel = "tokenstat.ai"

    /// The source repository. Readable and auditable. Store builds are
    /// reserved: see LICENSE. Linked because the privacy claim is only worth what a
    /// reader can check.
    static let repository = URL(string: "https://github.com/gyorgysh/tokenstat")!

    enum Author {
        static let name = L10n.text("apple.appinfo.gyorgy.cdb983c1")
        static let role = L10n.text("apple.appinfo.ai_native_product_engineer.e8e5f442")
        static let site = URL(string: "https://gyorgy.sh/?ref=\(AppInfo.referrer)")!
        static let siteLabel = "gyorgy.sh"
        static let email = URL(string: "mailto:gyorgy@pueev.com")!
    }
}
