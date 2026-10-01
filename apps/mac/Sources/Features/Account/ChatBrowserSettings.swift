// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum ChatBrowserPreferences {
    static let opensLinksKey = "chat.openLinksInBrowser"
}

#if os(macOS)
struct ChatBrowserSettings: View {
    @AppStorage(ChatBrowserPreferences.opensLinksKey) private var opensLinks = true

    var body: some View {
        Card(title: L10n.text("apple.chatbrowsersettings.chat_browser.d2fc9820"), subtitle: L10n.text("apple.chatbrowsersettings.keep_previews_beside_your_conversation.3df6d610"), mark: "mark_local") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Toggle(L10n.text("apple.chatbrowsersettings.open_chat_links_beside_the_conversation.c4350d58"), isOn: $opensLinks)
                    .toggleStyle(.brandCheckbox)
                    .font(Theme.callout)
                Text(L10n.text("apple.chatbrowsersettings.web_links_open_in_the_resizable_browser_pa.27b4b20a"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
