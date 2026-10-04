// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

#if os(macOS)
/// No navigation happens until a destination is chosen. The full URL stays
/// selectable, including paths and query strings, so the host is not the only
/// information available before opening a link.
struct ChatLinkOpenSheet: View {
    let url: URL
    let preferred: ChatBrowserPreferences.Destination
    let onOpen: (ChatBrowserPreferences.Destination, Bool) -> Void
    let onClose: () -> Void
    @State private var remember = false

    var body: some View {
        ThemedSheet(title: L10n.text("apple.chatlinks.title"),
                    subtitle: L10n.text("apple.chatlinks.subtitle"),
                    icon: .browser, scrolls: true, onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(url.absoluteString)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                Text(L10n.text("apple.chatlinks.explanation"))
                    .font(Theme.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.text("apple.chatlinks.remember"), isOn: $remember)
                    .toggleStyle(.brandCheckbox)
                    .font(Theme.callout)
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss, action: onClose)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            Button(L10n.text("apple.chatlinks.system"), .external) { onOpen(.system, remember) }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(preferred == .system ? .defaultAction : nil)
            Button(L10n.text("apple.chatlinks.tokenstat"), .browser) { onOpen(.tokenstat, remember) }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(preferred == .tokenstat ? .defaultAction : nil)
        }
        .modalFrame(width: 620, height: 360)
    }
}
#endif
