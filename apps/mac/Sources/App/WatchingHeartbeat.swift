// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Tell the host, while this screen is up, that somebody is reading this
/// conversation.
///
/// One modifier for both chat surfaces: the Mac and iPad's `ChatView`, and the
/// phone's `ClientChatView`, which is the case that matters most. A phone
/// driving a chat on a desktop used to buzz about the turn finishing on its own
/// screen, because the host that sent the push had no way to know the person
/// was holding the thing it was notifying.
///
/// The claim is renewed rather than set once, and the host's copy expires on
/// its own. That is what makes a force-quit, a crash or a lost connection
/// recover by itself instead of leaving an account permanently quiet. See
/// `crate::presence` on the host for the other half.
///
/// Renewing stops the moment `UserPresence` says nobody is there, so a Mac left
/// on an open conversation goes back to notifying about a minute later, without
/// anybody closing anything.
struct WatchingHeartbeat: ViewModifier {
    /// The conversation on screen, or nil when there is none.
    var conversationID: String?
    /// The host that owns it. Nil is this computer.
    var peer: String?
    /// False while this pane is mounted but behind another destination.
    var isActive: Bool = true

    /// One stable id for this mounted chat surface. A host uses it to keep
    /// separate leases for a Mac and phone viewing the same conversation.
    @State private var watcherID = UUID().uuidString

    /// Comfortably inside the host's 30 second lease, so one slow or dropped
    /// request does not let a notification through.
    private static let beat: Duration = .seconds(10)

    func body(content: Content) -> some View {
        content
            .task(id: "\(conversationID ?? "")-\(peer ?? "")-\(isActive)") {
                guard isActive, let id = conversationID, !id.isEmpty else { return }
                defer {
                    // Leaving the screen. The lease would expire anyway, and
                    // saying so makes the next half minute behave correctly.
                    // Detached: the view may already be gone when this runs.
                    let leaving = id
                    let host = peer
                    let watcher = watcherID
                    Task.detached {
                        await Bridge.stoppedWatching(
                            conversationID: leaving,
                            watcherID: watcher,
                            peer: host
                        )
                    }
                }
                while !Task.isCancelled {
                    if UserPresence.shared.isAtTheKeyboard {
                        await Bridge.watching(conversationID: id, watcherID: watcherID, peer: peer)
                    }
                    try? await Task.sleep(for: Self.beat)
                }
            }
    }
}

extension View {
    /// See `WatchingHeartbeat`.
    func watching(conversationID: String?, peer: String? = nil, isActive: Bool = true) -> some View {
        modifier(
            WatchingHeartbeat(conversationID: conversationID, peer: peer, isActive: isActive)
        )
    }
}
