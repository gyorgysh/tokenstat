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
import ScreenCaptureKit

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

    /// Set once a grant was made while this process was running.
    ///
    /// `CGPreflightScreenCaptureAccess()` answers from a value cached for the
    /// life of the process, so a grant made in System Settings while the app
    /// is open keeps reading false however often the card refreshes. Nothing
    /// in the API clears that. The honest move is to notice, say so, and offer
    /// the relaunch, rather than leave a card quietly lying.
    private(set) var needsRelaunch = false

    init() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Re-read both, asking the real subsystem about screen recording.
    ///
    /// Accessibility is cheap and truthful, so it is just read again. Screen
    /// recording is the cached one, so a false preflight is checked a second
    /// time against `SCShareableContent`, which actually goes and asks. That
    /// is the call that notices a grant the preflight is still lying about.
    func refresh() async {
        accessibility = AXIsProcessTrusted()

        if CGPreflightScreenCaptureAccess() {
            screenRecording = true
            needsRelaunch = false
            return
        }
        // The preflight says no, and it may be a stale no. Only worth a second
        // opinion once this process has actually asked: `SCShareableContent`
        // raises the system prompt when no decision exists, so calling it
        // before somebody pressed Allow would make merely opening the screen
        // ask for a permission nobody requested.
        guard askedScreenRecording else {
            screenRecording = false
            needsRelaunch = false
            return
        }
        let real = await Self.canActuallyCapture()
        screenRecording = real
        // Granted in reality but not according to the cached preflight: the
        // grant landed while this process was running, and capture code that
        // preflights will keep refusing until the app is restarted.
        needsRelaunch = real
    }

    /// Whether a capture could actually start right now.
    ///
    /// `SCShareableContent` is refused outright without the permission, so it
    /// answers the real question. It is the heavier call, which is why it is
    /// only used to double-check a negative.
    private static func canActuallyCapture() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
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

    /// Quit and come back, because a cached preflight cannot be cleared.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
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
