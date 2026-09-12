// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum ChatBrowserPreferences {
    static let opensLinksKey = "chat.openLinksInBrowser"
}

#if os(macOS)
struct ChatBrowserSettings: View {
    @AppStorage(ChatBrowserPreferences.opensLinksKey) private var opensLinks = true

    var body: some View {
        Card(title: "Chat browser", subtitle: "Keep previews beside your conversation", mark: "mark_local") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Toggle("Open chat links beside the conversation", isOn: $opensLinks)
                    .toggleStyle(.brandCheckbox)
                    .font(Theme.callout)
                Text("Web links open in the resizable browser pane. Turn this off to use your default browser. You can always open the pane from the chat toolbar.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
