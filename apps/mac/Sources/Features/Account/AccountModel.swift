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
#else
import UIKit
#endif

/// State for the Account screen, and the only place it talks to the bridge.
@Observable
@MainActor
final class AccountModel {
    /// Nil until the first load finishes, so the view can tell "unknown" from
    /// "signed out". Showing a sign-in button before we have checked would
    /// flash the wrong state on every launch.
    var account: Account?
    var pendingLogin: DeviceLogin?
    var isLoading = false
    var isSyncing = false
    var errorMessage: String?
    /// Set after a sync, cleared on the next action.
    var lastSyncSummary: String?
    var syncNotice: String?
    var syncNoticeIsError = false
    var syncCooldownUntil: Date?

    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    /// How the sign-in page is put in front of the user, when the platform has
    /// a better answer than handing the URL to another app.
    ///
    /// The Mac opens a browser window, which is right where the browser is one
    /// window away. The phone sets this to an authentication session that
    /// presents over the app and closes itself on the callback, so nobody has to
    /// leave, read a code and come back. Nil means "open a browser", which is
    /// what every other front end wants.
    @ObservationIgnored var signInPresenter: ((URL) -> Void)?

    /// How that presentation is taken away again, once there is nothing left to
    /// approve.
    ///
    /// Called on confirmation, on cancel and on expiry. The website redirecting
    /// into the app's own scheme also closes the sheet, and this exists because
    /// that redirect is not the only way a sign-in can finish: somebody can
    /// approve on a laptop, or be running against a build of the site that
    /// predates the redirect. A window this app opened is a window this app
    /// closes.
    @ObservationIgnored var signInDismisser: (() -> Void)?

    /// Something worth saying while the poll is running, such as the network
    /// having gone away. Not `errorMessage`: the sign-in has not failed, it is
    /// waiting, and the two must not read the same.
    private(set) var signInNotice: String?

    var signedIn: Bool { account?.signedIn == true }

    /// Whether the last sync was refused by the plan's rate gate, which is a
    /// warning rather than a failure: the sync machinery works, the account
    /// simply may not upload again yet.
    var isRateLimited: Bool {
        if syncCooldownUntil != nil { return true }
        return syncNotice?.contains("may sync once every") ?? false
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            account = try await Bridge.account()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Start the device flow, open the browser, then poll until confirmed.
    ///
    /// The browser is opened from here rather than from Rust so the app
    /// controls window behaviour, and so a headless or remote client can
    /// choose to do something else with the URL.
    func signIn() {
        // A sign-in is already running. Do not start a second one: a second
        // device code orphans the first, and the poll that is running belongs
        // to the code the user is looking at. Put the page back in front of
        // them instead, which is what tapping the button again means.
        //
        // It used to return silently here. On a phone that reads as a dead
        // button: the browser sheet can be dismissed while the sign-in is still
        // alive underneath, and every later tap did nothing at all.
        guard pollTask == nil else {
            presentSignInPage()
            return
        }
        errorMessage = nil
        lastSyncSummary = nil

        pollTask = Task {
            defer { pollTask = nil }
            do {
                let device = try await Bridge.startLogin()
                pendingLogin = device
                if let signInPresenter, let url = URL(string: device.openURL) {
                    signInPresenter(url)
                } else {
                    openInBrowser(device.openURL)
                }
                try await pollUntilConfirmed(device)
            } catch is CancellationError {
                await Bridge.cancelLogin()
            } catch {
                errorMessage = error.localizedDescription
            }
            pendingLogin = nil
        }
    }

    /// Put the approval page back in front of the user.
    ///
    /// Needed because the browser sheet can be dismissed while the sign-in it
    /// started is still perfectly alive underneath. `signIn()` cannot do this:
    /// it refuses while a poll is running, which is correct, since a second
    /// device code would orphan the first.
    func presentSignInPage() {
        guard let pending = pendingLogin else { return }
        if let signInPresenter, let url = URL(string: pending.openURL) {
            signInPresenter(url)
        } else {
            openInBrowser(pending.openURL)
        }
    }

    private func pollUntilConfirmed(_ device: DeviceLogin) async throws {
        var interval = device.interval
        let deadline = Date().addingTimeInterval(Double(device.expiresIn))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let poll: DevicePoll
            do {
                poll = try await Bridge.pollLogin()
            } catch {
                // **A dropped packet must not end a sign-in.** This used to
                // throw straight out of the loop, so one blocked poll, a moment
                // of no signal or a laptop lid closing meant starting over,
                // even though the code on screen was still valid for minutes.
                //
                // A poll failure is nearly always the network, and the answer
                // to that is to poll again. Say so on screen, keep the code
                // alive, and let the deadline be the thing that ends this.
                signInNotice = "Waiting for the network."
                try await Task.sleep(for: .seconds(max(interval, 3)))
                continue
            }
            signInNotice = nil

            if poll.isConfirmed {
                // Close the browser sheet ourselves rather than waiting for the
                // site to redirect into the app's scheme. The redirect is the
                // nice path, and it is one deploy, one old build of the website
                // or one person who approved on a different device away from
                // never arriving. This app knows the sign-in finished, so this
                // app closes the window it opened.
                signInDismisser?()
                await load()
                return
            }
            // The server can widen the interval when it wants less traffic.
            // Honour that rather than keeping the original cadence.
            interval = poll.interval ?? interval
        }

        signInDismisser?()
        signInNotice = nil
        await Bridge.cancelLogin()
        errorMessage = "The sign-in code expired before it was confirmed."
    }

    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingLogin = nil
        signInNotice = nil
        signInDismisser?()
        Task { await Bridge.cancelLogin() }
    }

    func signOut() async {
        do {
            try await Bridge.signOut()
            lastSyncSummary = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sync() async {
        guard !isSyncing, syncCooldownUntil == nil else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let result = try await Bridge.sync()
            lastSyncSummary = "Sent \(result.rows) rows for \(result.from) to \(result.to)."
            showSyncNotice(lastSyncSummary!, isError: false)
            startSyncCooldown()
            await load()
        } catch {
            // Sync failures are action feedback, not account state. Keep them
            // in the transient notice so a plan cooldown cannot pin the footer.
            errorMessage = nil
            showSyncNotice(error.localizedDescription, isError: true)
        }
    }

    private func showSyncNotice(_ message: String, isError: Bool) {
        noticeGeneration += 1
        let generation = noticeGeneration
        syncNotice = message
        syncNoticeIsError = isError
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.noticeGeneration == generation else { return }
            self.syncNotice = nil
            self.syncNoticeIsError = false
        }
    }

    private func startSyncCooldown() {
        let until = Date().addingTimeInterval(5 * 60)
        syncCooldownUntil = until
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5 * 60))
            guard let self, self.syncCooldownUntil == until else { return }
            self.syncCooldownUntil = nil
        }
    }
}

/// Open a URL in the user's browser.
private func openInBrowser(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
