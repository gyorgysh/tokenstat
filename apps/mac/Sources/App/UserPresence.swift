// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

#if os(macOS)
import AppKit
import CoreGraphics
#else
import UIKit
#endif

@MainActor
@Observable
final class UserPresence {
    static let shared = UserPresence()

    private static let idleAfter: TimeInterval = 5 * 60

    private(set) var visibleConversationID: String?
    @ObservationIgnored private var chatSurfaces = ChatSurfacePresence()

    private init() {}

    func chatSurface(showing id: String?) {
        visibleConversationID = id
    }

    func chatSurface(showing id: String?, owner: UUID, sceneActive: Bool) {
        chatSurfaces.update(owner: owner, conversation: id, active: sceneActive)
        visibleConversationID = chatSurfaces.visibleConversation
    }

    func leaveChatSurface(owner: UUID) {
        chatSurfaces.remove(owner: owner)
        visibleConversationID = chatSurfaces.visibleConversation
    }

    /// True when the app is in front, on screen, and somebody has touched this
    /// device recently.
    ///
    /// The phone answers a shorter version of the same question. A foreground
    /// iOS app is on screen by definition, there is no window behind another
    /// window and no second Space, and iOS locks itself when it is put down,
    /// so "the app is active" already carries what the Mac has to check three
    /// things for.
    var isAtTheKeyboard: Bool {
        #if os(macOS)
        guard NSApp.isActive else { return false }
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        let window = candidates.first ?? NSApp.windows.first(where: { $0.isVisible })
        if let window {
            guard window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else {
                return false
            }
        } else if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace }) {
        } else if !NSApp.windows.isEmpty {
            return false
        }
        return secondsSinceInput < Self.idleAfter
        #else
        return chatSurfaces.visibleConversation != nil
        #endif
    }

    #if os(macOS)
    private final class ReadingWindow {
        weak var window: NSWindow?
        let conversation: String
        init(_ window: NSWindow?, conversation: String) { self.window = window; self.conversation = conversation }
    }
    @ObservationIgnored private var readingWindows: [String: ReadingWindow] = [:]

    func registerReadingWindow(_ window: NSWindow?, conversation: String, watcher: String) {
        readingWindows[watcher] = ReadingWindow(window, conversation: conversation)
    }
    func removeReadingWindow(watcher: String) { readingWindows.removeValue(forKey: watcher) }

    static func visibleForReading(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.isOnActiveSpace
            && window.occlusionState.contains(.visible)
    }
    #endif

    func isWatching(conversation id: String) -> Bool {
        #if os(macOS)
        readingWindows.values.contains { $0.conversation == id && Self.visibleForReading($0.window) }
        #else
        chatSurfaces.isWatching(id)
        #endif
    }

    /// Seconds since the last input event anywhere in this login session.
    ///
    /// `~0` is `kCGAnyInputEventType`, which C spells as a constant and Swift
    /// does not import. Reading it needs no accessibility permission: it is a
    /// timestamp, not the events themselves.
    #if os(macOS)
    private var secondsSinceInput: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
    #endif
}
