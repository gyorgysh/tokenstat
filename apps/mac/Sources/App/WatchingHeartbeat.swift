// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if os(macOS)
import AppKit
#endif

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
/// On Mac, a visible chat keeps its claim even while another app has focus or
/// the person is reading without typing. Hidden windows and other destinations
/// release it; the host lease also handles crashes and lost connections.
struct WatchingHeartbeat: ViewModifier {
    /// The conversation on screen, or nil when there is none.
    var conversationID: String?
    /// The host that owns it. Nil is this computer.
    var peer: String?
    /// False while this pane is mounted but behind another destination.
    var isActive: Bool = true

    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @State private var windowReference = WatchingWindowReference()
    private var window: NSWindow? { windowReference.window }
    #endif

    private var enabled: Bool {
        #if os(macOS)
        isActive
        #else
        isActive && scenePhase == .active
        #endif
    }
    private var windowID: Int? {
        #if os(macOS)
        window?.windowNumber
        #else
        nil
        #endif
    }

    private struct Identity: Hashable {
        let conversation: String?
        let peer: String?
        let scope: WorkReference.Scope?
        let generation: UInt64
        let active: Bool
        let window: Int?
    }

    /// Comfortably inside the host's 30 second lease, so one slow or dropped
    /// request does not let a notification through.
    private static let beat: Duration = .seconds(10)

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .background(WatchingWindowBridge(reference: $windowReference).frame(width: 0, height: 0))
            #endif
            .task(id: Identity(conversation: conversationID, peer: peer,
                               scope: WorkSessionContext.shared.scope,
                               generation: WorkSessionContext.shared.generation,
                               active: enabled, window: windowID)) {
                guard enabled, let id = conversationID, !id.isEmpty,
                      let owner = WorkSessionContext.shared.scope else { return }
                // A late release from the previous scene phase must never
                // remove the foreground task's newly renewed lease.
                let ownerGeneration = WorkSessionContext.shared.generation
                let watcherID = UUID().uuidString
                #if os(macOS)
                UserPresence.shared.registerReadingWindow(window, conversation: id, watcher: watcherID)
                #endif
                defer {
                    #if os(macOS)
                    UserPresence.shared.removeReadingWindow(watcher: watcherID)
                    #endif
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
                            peer: host, expectedScope: owner, expectedGeneration: ownerGeneration
                        )
                    }
                }
                while !Task.isCancelled, WorkSessionContext.shared.scope == owner,
                      WorkSessionContext.shared.generation == ownerGeneration {
                    #if os(macOS)
                    let watching = UserPresence.visibleForReading(window)
                    #else
                    let watching = UserPresence.shared.isAtTheKeyboard
                    #endif
                    if watching {
                        await Bridge.watching(conversationID: id, watcherID: watcherID, peer: peer,
                                              expectedScope: owner, expectedGeneration: ownerGeneration)
                    } else {
                        await Bridge.stoppedWatching(conversationID: id, watcherID: watcherID, peer: peer,
                                                     expectedScope: owner, expectedGeneration: ownerGeneration)
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

#if os(macOS)
@MainActor
private final class WatchingWindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow? = nil) { self.window = window }
}

private struct WatchingWindowBridge: NSViewRepresentable {
    @Binding var reference: WatchingWindowReference
    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindowChange = { next in Task { @MainActor in reference = WatchingWindowReference(next) } }
        return view
    }
    func updateNSView(_ view: WindowReportingView, context: Context) {
        guard view.window !== reference.window else { return }
        let next = view.window
        Task { @MainActor in reference = WatchingWindowReference(next) }
    }
}
#endif
