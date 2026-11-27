// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WatchingHeartbeat: ViewModifier {
    var conversationID: String?
    var peer: String?
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
                let ownerGeneration = WorkSessionContext.shared.generation
                let watcherID = UUID().uuidString
                #if os(macOS)
                UserPresence.shared.registerReadingWindow(window, conversation: id, watcher: watcherID)
                #endif
                defer {
                    #if os(macOS)
                    UserPresence.shared.removeReadingWindow(watcher: watcherID)
                    #endif
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
