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
    var syncCooldownUntil: Date?

    private var pollTask: Task<Void, Never>?

    var signedIn: Bool { account?.signedIn == true }

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
        guard pollTask == nil else { return }
        errorMessage = nil
        lastSyncSummary = nil

        pollTask = Task {
            defer { pollTask = nil }
            do {
                let device = try await Bridge.startLogin()
                pendingLogin = device
                openInBrowser(device.openURL)
                try await pollUntilConfirmed(device)
            } catch is CancellationError {
                await Bridge.cancelLogin()
            } catch {
                errorMessage = error.localizedDescription
            }
            pendingLogin = nil
        }
    }

    private func pollUntilConfirmed(_ device: DeviceLogin) async throws {
        var interval = device.interval
        let deadline = Date().addingTimeInterval(Double(device.expiresIn))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let poll = try await Bridge.pollLogin()
            if poll.isConfirmed {
                await load()
                return
            }
            // The server can widen the interval when it wants less traffic.
            // Honour that rather than keeping the original cadence.
            interval = poll.interval ?? interval
        }

        await Bridge.cancelLogin()
        errorMessage = "The sign-in code expired before it was confirmed."
    }

    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingLogin = nil
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
            startSyncCooldown()
            await load()
        } catch {
            errorMessage = error.localizedDescription
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
