// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct ChatComingSoonView: View {
    var folderName: String?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ChatScene(seed: personaSeed(for: folderName ?? "chat"))
            Text(L10n.text("apple.chatcomingsoonview.chat_is_on_the_way.b1d7ba9c"))
                .font(Theme.title3.weight(.semibold))
            Text(message)
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.l)
        .background(Theme.background)
        #if os(macOS)
        .navigationTitle(L10n.text("apple.chatcomingsoonview.chat.460b3a7d"))
        #endif
    }

    private var message: String {
        if let folderName, !folderName.isEmpty {
            return L10n.text("apple.chatcomingsoonview.a_friendlier_way_to_talk_to_the_agents_alr.8d3a19d6", "\(folderName)")
        }
        return L10n.text("apple.chatcomingsoonview.a_friendlier_way_to_talk_to_the_agents_alr.e1682232")
    }
}

struct ChatScene: View {
    var seed: UInt64 = personaSeed(for: "chat")

    var body: some View {
        PersonaPastime(seed: seed, size: 116, doing: .leisure)
            .frame(width: 168, height: 132)
            .accessibilityHidden(true)
    }
}
