// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

#if os(macOS)
import AppKit
import CoreGraphics
#else
import UIKit
#endif

/// Whether the person is watching a surface right now.
///
/// Read in two places, and they are not the same question asked twice. The
/// Mac's own banners consult it directly before posting. The host consults its
/// own copy, fed by `app.watching` from every client with a chat on screen,
/// before sending a push to this account's phones. Same fact, two audiences:
/// the second is what stops a phone buzzing about the reply on its own screen.
///
/// A notification exists to reach somebody who is not looking. Posting one
/// about a turn that finished in the conversation they are reading, in a
/// window that is in front of them, is the app talking over itself, and it is
/// how a notification switch gets turned off for good.
///
/// Mac chat windows count while visible on the current Space, including beside
/// another app. Mobile chat surfaces count while their scene is active.
@MainActor
@Observable
final class UserPresence {
    static let shared = UserPresence()

    /// How long without a keystroke, a click or a mouse move counts as away.
    /// Mac only: see `isAtTheKeyboard`.
    ///
    /// Generous on purpose. Reading a long reply without touching anything is
    /// ordinary, and five minutes of that is rarer than stepping away from a
    /// Mac that has been left unlocked.
    private static let idleAfter: TimeInterval = 5 * 60

    /// The conversation the chat surface is showing, or nil when chat is not
    /// the destination on screen.
    ///
    /// `ChatModel.selected` is not this. It keeps its selection while the
    /// person is on Insights or in a terminal, so it answers "which
    /// conversation would chat show" rather than "what are they looking at".
    private(set) var visibleConversationID: String?
    @ObservationIgnored private var chatSurfaces = ChatSurfacePresence()

    private init() {}

    /// Called by the chat surface as it appears, changes conversation, and
    /// goes away again.
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
        // The chat surface is one window among others. A Settings window in
        // front while chat is occluded must not count as watching: require a
        // visible, non-miniaturized window on the active Space, preferring
        // the key/main window but falling back to any window.
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        let window = candidates.first ?? NSApp.windows.first(where: { $0.isVisible })
        if let window {
            guard window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else {
                return false
            }
        } else if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace }) {
            // No key/main window (e.g. panel-only state) but something is on
            // screen. Count it rather than failing closed.
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

    /// True when this exact conversation is the one on screen and somebody is
    /// there to read it.
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
