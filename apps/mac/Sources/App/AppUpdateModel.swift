// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

import Foundation
import Observation

/// Finding a new version, fetching it, and putting it in place.
///
/// The whole thing happens without being asked, and then stops. Downloading and
/// verifying is work nobody wants to watch, so it runs quietly. Restarting is
/// not: an application that relaunches itself under somebody who is halfway
/// through a sentence has taken a decision that was not its to take. So the
/// last step is a button, and the sidebar carries it until it is pressed.
@MainActor
@Observable
final class AppUpdateModel {
    /// Where an update has got to. The interface shows something only in the
    /// last two, because the ones before it are not the user's business.
    enum Stage: Equatable {
        case idle
        case checking
        /// Found, and being fetched and checked.
        case installing
        /// In place. Restarting is all that is left.
        case readyToRelaunch
        /// It could not be installed, so the download page is the fallback.
        case failed(String)
    }

    private(set) var release: AppUpdate?
    private(set) var stage: Stage = .idle

    var isAvailable: Bool { release?.isAvailable == true }
    var latest: String { release?.latest ?? "" }
    var current: String { release?.current ?? "" }
    var htmlURL: String { release?.htmlURL ?? "" }
    var downloadURL: URL? { release?.downloadURL }

    /// The sidebar's card. Present only when there is something for a person to
    /// do, which is either restart or go and fetch it by hand.
    var isReady: Bool { stage == .readyToRelaunch }

    var failure: String? {
        if case .failed(let why) = stage { return why }
        return nil
    }

    var isChecking: Bool { stage == .checking || stage == .installing }

    /// What a hand-triggered check found, for a moment.
    ///
    /// The check on launch is deliberately silent: nobody asked for it, and
    /// "you are up to date" unprompted is noise. A check somebody pressed is
    /// the opposite. Pressing a button and getting nothing back reads as a
    /// broken button, so this says what happened and then goes away.
    private(set) var checkNotice: String?

    /// Check because a person asked.
    ///
    /// Separate from `checkAndInstall` only in that it will run again after a
    /// previous check came back with nothing. That guard exists so the launch
    /// check happens once; a person pressing the item means now.
    func checkNow() async {
        guard !isChecking else { return }
        checkNotice = nil
        let before = release?.latest
        stage = .idle
        await checkAndInstall()

        if isReady {
            checkNotice = "Update installed. Relaunch to finish."
        } else if let failure {
            checkNotice = failure
        } else if isAvailable, release?.latest != before {
            checkNotice = "Version \(latest) found."
        } else {
            checkNotice = "You are on the latest version."
        }

        try? await Task.sleep(for: .seconds(6))
        checkNotice = nil
    }

    /// Check, and install what is found.
    ///
    /// Failure is quiet in the sense that it never interrupts, but it is not
    /// swallowed: the card offers the manual download instead, so an update
    /// that cannot be automated still reaches the user.
    func checkAndInstall() async {
        guard stage == .idle || failure != nil else { return }
        stage = .checking
        do {
            let found = try await Bridge.appUpdateCheck()
            release = found
            guard found.isAvailable else {
                stage = .idle
                return
            }
        } catch {
            // An update check is not worth a banner. No network is the common
            // reason and the user already knows.
            stage = .idle
            return
        }

        #if os(macOS)
        stage = .installing
        do {
            let downloaded = try await Bridge.appUpdateDownload()
            // Off the main actor: mounting an image and copying a bundle would
            // otherwise freeze the window for the whole of it.
            try await Task.detached(priority: .utility) {
                try AppInstaller.install(imagePath: downloaded.path)
            }.value
            stage = .readyToRelaunch
        } catch {
            stage = .failed(error.localizedDescription)
        }
        #else
        // Nothing to install into on iOS. The card offers the release page.
        stage = .failed("Updates on this platform come from the App Store.")
        #endif
    }

    func relaunch() {
        #if os(macOS)
        AppInstaller.relaunch()
        #endif
    }

    /// A release the user said they did not want to hear about again.
    ///
    /// Per version rather than a blanket "stop checking": somebody skipping
    /// 0.2.0 has not asked to be kept off 0.3.0, and an updater that treats
    /// those as the same thing is one people turn off entirely.
    private static let skippedKey = "AppUpdate.skippedVersion"

    var isSkipped: Bool {
        guard let latest = release?.latest, !latest.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: Self.skippedKey) == latest
    }

    func skipThisVersion() {
        guard let latest = release?.latest, !latest.isEmpty else { return }
        UserDefaults.standard.set(latest, forKey: Self.skippedKey)
        stage = .idle
    }
}
