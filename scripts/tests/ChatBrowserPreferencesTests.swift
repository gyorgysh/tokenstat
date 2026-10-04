// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatBrowserPreferences.swift using swiftc -parse-as-library.
import Foundation

@main
struct ChatBrowserPreferencesTests {
    static func main() {
        let suite = "ChatBrowserPreferencesTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        precondition(ChatBrowserPreferences.savedDestination(defaults: defaults) == nil,
                     "First use must ask before navigating")
        defaults.set(false, forKey: ChatBrowserPreferences.opensLinksKey)
        precondition(ChatBrowserPreferences.savedDestination(defaults: defaults) == nil,
                     "A previous default must not silently bypass the new choice")
        ChatBrowserPreferences.remember(.system, defaults: defaults)
        precondition(ChatBrowserPreferences.savedDestination(defaults: defaults) == .system)
        ChatBrowserPreferences.remember(.tokenstat, defaults: defaults)
        precondition(ChatBrowserPreferences.savedDestination(defaults: defaults) == .tokenstat)
        defaults.set(false, forKey: ChatBrowserPreferences.remembersDestinationKey)
        precondition(ChatBrowserPreferences.savedDestination(defaults: defaults) == nil,
                     "Settings must allow asking again")
        precondition(defaults.bool(forKey: ChatBrowserPreferences.opensLinksKey),
                     "Asking again must retain the previous destination suggestion")
        print("ChatBrowserPreferencesTests passed")
    }
}
