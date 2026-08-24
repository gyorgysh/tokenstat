// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// The two macOS permissions screen sharing needs, and the state of each.
///
/// The app used to call `CGRequestScreenCaptureAccess()` in one place, inside
/// a capture that was already starting, so the prompt arrived after the viewer
/// on the other device had already failed. Accessibility was never requested at
/// all, only checked, so turning on Control did nothing and said nothing.
///
/// Both are asked for here, at the moment somebody says what they want.
@MainActor
@Observable
final class ScreenAccess {
    /// Screen Recording. Preflight rather than a capture attempt: it answers
    /// without starting anything and without prompting.
    private(set) var screenRecording = false
    /// Accessibility, which is what synthesised clicks and keystrokes need.
    private(set) var accessibility = false

    init() { refresh() }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// What happened when we asked.
    ///
    /// Three answers, not two, and the third is the one that matters. Both
    /// system calls return the *current* state and raise their prompt
    /// asynchronously, so a first-ever request returns false while the dialog
    /// is on screen. Treating that as "refused" and opening System Settings
    /// slams a window over the prompt the person was about to answer.
    enum Ask {
        /// Already granted, nothing was shown.
        case granted
        /// The system prompt is now on screen. Leave them to it.
        case asked
        /// macOS already holds a decision and will not ask again, so the only
        /// remaining route is the Settings pane.
        case alreadyDecided
    }

    /// Whether this app has asked during this launch.
    ///
    /// macOS prompts once per app per permission and gives no way to ask
    /// whether it will. Remembering that we have asked is what separates "the
    /// dialog is up" from "there is no dialog coming".
    private var askedScreenRecording = false
    private var askedAccessibility = false

    /// Ask for Screen Recording.
    func requestScreenRecording() -> Ask {
        if CGPreflightScreenCaptureAccess() {
            screenRecording = true
            return .granted
        }
        let alreadyAsked = askedScreenRecording
        askedScreenRecording = true
        // Raises the prompt when macOS has no decision yet, and returns the
        // state as it stands, which is false either way.
        screenRecording = CGRequestScreenCaptureAccess()
        if screenRecording { return .granted }
        return alreadyAsked ? .alreadyDecided : .asked
    }

    /// Ask for Accessibility, with the prompt that names Tokenstat.
    ///
    /// `AXIsProcessTrusted()` only reads the answer. The options form is the
    /// one that asks, and it is the call that was missing.
    func requestAccessibility() -> Ask {
        if AXIsProcessTrusted() {
            accessibility = true
            return .granted
        }
        let alreadyAsked = askedAccessibility
        askedAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        if accessibility { return .granted }
        return alreadyAsked ? .alreadyDecided : .asked
    }

    /// Open the pane a person has to switch the row on in themselves.
    ///
    /// Only useful alongside a sentence naming the row: the pane is a list of
    /// applications with no indication of which one to look for, which is where
    /// the confusion came from.
    func openSettings(_ kind: Kind) {
        let pane = switch kind {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    enum Kind {
        case screenRecording
        case accessibility

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }

        var need: String {
            switch self {
            case .screenRecording: "Needed for another device to see this screen."
            case .accessibility: "Needed for another device to click and type on this screen."
            }
        }

        /// What to say when the prompt will not appear again. Naming the row is
        /// the whole point: the pane does not say which application to find.
        var settingsHint: String {
            switch self {
            case .screenRecording:
                "macOS only asks once. Switch Tokenstat on under Privacy & Security → Screen & System Audio Recording."
            case .accessibility:
                "macOS only asks once. Switch Tokenstat on under Privacy & Security → Accessibility."
            }
        }
    }
}
#endif
