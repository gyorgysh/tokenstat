// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The Chat section, before there is a Chat.
///
/// A section with nothing behind it, on purpose. The place people would look
/// for it is worth marking before the feature exists, and an honest empty
/// screen is a better answer than a row that is not there yet. No button:
/// a Notify me that does nothing would be worse than nothing.
struct ChatComingSoonView: View {
    /// The folder this was opened from, when there is one to name. It makes
    /// the sentence about the work in front of somebody rather than about a
    /// feature in general.
    var folderName: String?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ChatScene(seed: personaSeed(for: folderName ?? "chat"))
            Text("Chat is on the way")
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
        .navigationTitle("Chat")
        #endif
    }

    private var message: String {
        if let folderName, !folderName.isEmpty {
            return "A friendlier way to talk to the agents already running in \(folderName), without a terminal in between."
        }
        return "A friendlier way to talk to the agents already running in this folder, without a terminal in between."
    }
}

/// This folder's character, with nothing else in the picture.
///
/// It used to be a chat bubble with three pulsing dots and the four harness
/// marks orbiting it. The bubble was a picture of waiting, and nobody on this
/// screen is waiting yet: this is what somebody looks at while deciding
/// whether to start. The marks went with it. Naming four agents on an empty
/// screen is a decision nobody has to make here, and four things drifting
/// around a character that is already moving is two animations arguing.
///
/// So it is one creature, left to get on with something, and what that is
/// differs every time the screen is opened.
struct ChatScene: View {
    /// The character. Seeded from the folder, so a person's projects each keep
    /// their own, the same one every time they open it.
    var seed: UInt64 = personaSeed(for: "chat")

    var body: some View {
        PersonaPastime(seed: seed, size: 116, doing: .leisure)
            .frame(width: 168, height: 132)
            .accessibilityHidden(true)
    }
}
