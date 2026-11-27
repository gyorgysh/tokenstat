// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
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
    private(set) var screenRecording = false
    /// Accessibility, which is what synthesised clicks and keystrokes need.
    private(set) var accessibility = false

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
        guard askedScreenRecording else {
            screenRecording = false
            needsRelaunch = false
            return
        }
        let real = await Self.canActuallyCapture()
        screenRecording = real
        needsRelaunch = real
    }

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

    enum Ask {
        case granted
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

    func openSettings(_ kind: Kind) {
        let pane = switch kind {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard application != nil, error == nil else { return }
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    enum Kind {
        case screenRecording
        case accessibility

        var title: String {
            switch self {
            case .screenRecording: L10n.text("apple.screenaccess.screen_recording.bc3c7428")
            case .accessibility: L10n.text("apple.screenaccess.accessibility.d3368cbf")
            }
        }

        var need: String {
            switch self {
            case .screenRecording: L10n.text("apple.screenaccess.needed_for_another_device_to_see_this_scre.368b885b")
            case .accessibility: L10n.text("apple.screenaccess.needed_for_another_device_to_click_and_typ.7a99e357")
            }
        }

        var settingsHint: String {
            switch self {
            case .screenRecording:
                L10n.text("apple.screenaccess.macos_only_asks_once_switch_tokenstat_on_u.a62eeed0")
            case .accessibility:
                L10n.text("apple.screenaccess.macos_only_asks_once_switch_tokenstat_on_u.edc64440")
            }
        }
    }
}
#endif
