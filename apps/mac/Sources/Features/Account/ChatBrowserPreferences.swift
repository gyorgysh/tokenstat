// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

enum ChatBrowserPreferences {
    static let opensLinksKey = "chat.openLinksInBrowser"
    static let remembersDestinationKey = "chat.linkDestinationRemembered"

    enum Destination: Equatable { case tokenstat, system }

    /// An existing default is only a suggestion until a person remembers it.
    static func savedDestination(defaults: UserDefaults = .standard) -> Destination? {
        guard defaults.bool(forKey: remembersDestinationKey) else { return nil }
        let inside = defaults.object(forKey: opensLinksKey) as? Bool ?? true
        return inside ? .tokenstat : .system
    }

    static func remember(_ destination: Destination, defaults: UserDefaults = .standard) {
        defaults.set(destination == .tokenstat, forKey: opensLinksKey)
        defaults.set(true, forKey: remembersDestinationKey)
    }
}
