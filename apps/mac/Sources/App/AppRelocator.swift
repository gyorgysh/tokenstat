// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation

/// Moving the application into /Applications the first time it is opened.
///
/// # Why this is not cosmetic
///
/// A .dmg is a mounted read-only image. Double-clicking the app inside it runs
/// a copy that vanishes when the image is ejected, and macOS makes that worse:
/// a quarantined bundle opened from outside /Applications is launched from a
/// randomised read-only path under /AppTranslocation. Three things this app
/// does break there.
///
/// - `AppInstaller` updates by replacing its own bundle. A read-only
///   translocated path cannot be replaced, so updates fail for as long as the
///   app lives in Downloads.
/// - The host helper is installed out of `Contents/Resources`, and the launch
///   agent that keeps it alive outlives the window. An app that moves every
///   time the user tidies their Downloads folder leaves that agent pointing at
///   copies of itself.
/// - Two copies in two folders are two applications as far as launchd and the
///   Finder are concerned, and both can be open at once.
///
/// # Why it asks
///
/// Moving a file the user downloaded is their business, so this asks once. It
/// is not a nag: declining is remembered, and the ordinary case where the app
/// already lives in a normal place says nothing at all.
enum AppRelocator {
    /// Set when the user has said no. Asking again on the next launch would be
    /// the same question with the same answer.
    private static let declinedKey = "AppRelocator.declined"

    /// Move to /Applications if this copy is somewhere it should not be.
    ///
    /// Returns `true` when the relaunch has been started, in which case the
    /// caller must do nothing else: this process is on its way out and any work
    /// it starts now belongs to a bundle that is about to be replaced.
    @MainActor
    static func relocateIfNeeded() -> Bool {
        #if DEBUG
        // A development build lives in DerivedData and belongs there.
        return false
        #else
        let bundle = Bundle.main.bundleURL
        guard needsRelocation(bundle) else { return false }
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return false }

        let destinationDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent(bundle.lastPathComponent)

        // Nothing to offer if the folder cannot be written and no authorisation
        // is going to be asked for. Better a working app in the wrong place
        // than a dialog the user cannot act on.
        guard FileManager.default.isWritableFile(atPath: destinationDirectory.path) else {
            return false
        }

        // An open copy in /Applications is the one that should be in front.
        // Moving over a running bundle would leave that process running an
        // image that no longer exists on disk.
        if let running = runningCopy(at: destination) {
            running.activate()
            NSApp.terminate(nil)
            return true
        }

        switch ask(replacing: FileManager.default.fileExists(atPath: destination.path)) {
        case .decline:
            UserDefaults.standard.set(true, forKey: declinedKey)
            return false
        case .skip:
            return false
        case .move:
            break
        }

        do {
            try move(bundle, to: destination)
        } catch {
            // Carry on from where it is. A failed tidy-up is not a reason to
            // refuse to open, and the alert says so rather than leaving the
            // user with an app that did nothing.
            report(error)
            return false
        }

        relaunch(destination)
        return true
        #endif
    }

    // MARK: - Deciding

    /// True when this copy is running from somewhere it cannot update itself.
    ///
    /// `~/Applications` counts as a real home: a user who keeps applications
    /// there did that on purpose, and it is writable, so updates work.
    private static func needsRelocation(_ bundle: URL) -> Bool {
        if isTranslocated(bundle) { return true }
        let path = bundle.path
        if path.hasPrefix("/Applications/") { return false }
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        if path.hasPrefix(userApplications + "/") { return false }
        return true
    }

    /// Gatekeeper's read-only shadow copy of a quarantined bundle.
    ///
    /// Detected by path because that is what it is: the real bundle is still
    /// wherever the user put it, and this process is looking at a mount that
    /// disappears when it quits.
    private static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.path.hasPrefix("/private/var/folders/")
            && bundle.path.contains("/AppTranslocation/")
    }

    /// Another copy of this app already running from the destination.
    ///
    /// Matched by path, not by bundle identifier. The identifier was
    /// `ai.tokenstat.Tokenstat` and is now `ai.tokenstat.tokenstat`, so a build
    /// from before the rename running out of /Applications is a different
    /// identifier and asking for our own would not have found it. What matters
    /// is that something is running from the folder we are about to replace.
    private static func runningCopy(at destination: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { other in
            other != .current
                && other.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
    }

    // MARK: - Asking

    private enum Answer {
        case move
        case skip
        case decline
    }

    @MainActor
    private static func ask(replacing: Bool) -> Answer {
        let alert = NSAlert()
        alert.messageText = "Move tokenstat to your Applications folder?"
        alert.informativeText = replacing
            ? """
            There is already a copy in Applications. Replacing it keeps one \
            application on this Mac, which is what lets tokenstat update itself \
            and keep its host helper pointed at a path that stays put.
            """
            : """
            Running from a disk image or your Downloads folder means tokenstat \
            cannot update itself, and a second copy can end up open alongside \
            this one. Moving it now avoids both.
            """
        alert.addButton(withTitle: replacing ? "Replace and Move" : "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .move
        case .alertThirdButtonReturn: return .decline
        default: return .skip
        }
    }

    @MainActor
    private static func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "tokenstat could not be moved to Applications."
        alert.informativeText = "\(error.localizedDescription)\n\nIt will keep running from where it is. Move it by hand when convenient."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    // MARK: - Moving

    private static func move(_ bundle: URL, to destination: URL) throws {
        let manager = FileManager.default

        // Copy, then remove the original, rather than a move. A translocated
        // bundle cannot be moved at all, and a copy that fails part way through
        // has not destroyed the only copy the user has.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).incoming")
        try? manager.removeItem(at: staged)
        try manager.copyItem(at: bundle, to: staged)

        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }

        // The quarantine flag is what causes translocation, so a copy that kept
        // it would be launched from a random read-only path again and the move
        // would have achieved nothing.
        let clear = Process()
        clear.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clear.arguments = ["-d", "-r", "com.apple.quarantine", destination.path]
        try? clear.run()
        clear.waitUntilExit()

        // The original, only when there is one to delete and it is ours to
        // delete. A translocated path is a mount, not the download, and the
        // real bundle behind it is not reachable from here.
        if !isTranslocated(bundle) {
            try? manager.trashItem(at: bundle, resultingItemURL: nil)
        }
    }

    @MainActor
    private static func relaunch(_ destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
#endif
