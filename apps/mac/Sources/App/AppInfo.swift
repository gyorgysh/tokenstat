// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// Static app metadata and outbound links, read once from the bundle so the
/// About window and anything else that quotes a version share one source
/// rather than each reaching into the info dictionary with its own fallback.
enum AppInfo {
    /// Marketing version, e.g. "0.2.9".
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// Build number, e.g. "2".
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// "0.2.9 (2)".
    static var versionString: String { "\(version) (\(build))" }

    /// Copyright line, taken from the bundle so the app and the generated
    /// Info.plist cannot disagree about the year or the company.
    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© pueev OÜ. All rights reserved."
    }

    /// Tags outbound links to sites we own, so analytics can tell app traffic
    /// apart from search and social. Left off mailto and GitHub, which have
    /// nothing to read it.
    static let referrer = "tokenstat_app"

    /// The public website.
    static let website = URL(string: "https://tokenstat.ai/?ref=\(referrer)")!
    static let websiteLabel = "tokenstat.ai"

    /// The source repository. Readable and auditable, not redistributable:
    /// see LICENSE. Linked because the privacy claim is only worth what a
    /// reader can check.
    static let repository = URL(string: "https://github.com/gyorgysh/tokenstat")!

    /// Who made it, and how to reach them. Shown in the About window.
    enum Author {
        static let name = "Gyorgy"
        static let role = "AI-native product engineer"
        static let site = URL(string: "https://gyorgy.sh/?ref=\(AppInfo.referrer)")!
        static let siteLabel = "gyorgy.sh"
        static let email = URL(string: "mailto:gyorgy@pueev.com")!
    }
}
