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
    var isSigningOut = false
    /// P2: post plan-limit readings after sync / limits refresh. Opt-in.
    var limitsSyncEnabled = false
    #if os(macOS)
    /// Nil until the host has answered. The switch must not flash the wrong default.
    var hostPolicy: HostPolicy?
    var isSavingHostPolicy = false
    #endif
    var errorMessage: String?
    /// Set after a sync, cleared on the next action.
    var lastSyncSummary: String?
    var syncNotice: String?
    var syncNoticeIsError = false
    /// After any accepted sync, and after a real 429, the next manual press
    /// would be refused. Used to disable the button. Not the same as a rate
    /// limit: success also starts this clock.
    var syncCooldownUntil: Date?
    /// True only when the last attempt was refused by the plan gate.
    ///
    /// A successful sync used to flip `isRateLimited` because it shared this
    /// cooldown, so Account settings said "synced" while the sidebar footer
    /// said "Rate limited" for the next five minutes.
    var lastSyncWasRateLimited = false

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

    /// True only after a definitive account answer: signed in, or honestly
    /// signed out (`account.status` returned `signedIn: false`).
    ///
    /// A network failure does **not** set this. Collapsing "could not check"
    /// into "signed out" was the cold-start bug: a phone with a valid token
    /// offline flashed the Sign in door and never recovered without a retry.
    private(set) var authChecked = false

    /// Why the last check failed, when it was not a clean signed-out answer.
    /// Nil while loading or after a successful check. The root uses this to
    /// show a retry surface instead of the login door.
    private(set) var authCheckError: String?

    /// Set when a check right after the deletion browser closes confirms the
    /// account is gone, so the login door can say what happened. Cleared on
    /// the next sign-in.
    private(set) var deletionConfirmed = false

    var signedIn: Bool { account?.signedIn == true }

    /// First check still in flight, or waiting for the host. Splash territory.
    var authPending: Bool { !authChecked && authCheckError == nil }

    /// First check failed (usually offline). Show retry, not Sign in.
    var authNeedsRetry: Bool { !authChecked && authCheckError != nil }

    /// Whether the last sync was refused by the plan's rate gate, which is a
    /// warning rather than a failure: the sync machinery works, the account
    /// simply may not upload again yet.
    ///
    /// Only the last attempt's classification. The notice used to be scanned
    /// as well, and "Sent 429 rows" from a success matched the bare "429".
    var isRateLimited: Bool { lastSyncWasRateLimited }

    func load() async {
        // A second load while one is in flight (connectivity restored + manual
        // retry) would race two writes into `account`. One at a time.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let previous = account
            let next = try await Bridge.account()
            account = next
            errorMessage = nil
            authCheckError = nil
            authChecked = true
            #if os(macOS)
            limitsSyncEnabled = (try? await Bridge.limitsSyncEnabled()) ?? false
            hostPolicy = try? await Bridge.hostPolicy()
            #endif
            await Self.broadcastIfEntitlementChanged(from: previous, to: next)
        } catch {
            // Keep any previous signed-in snapshot. A later offline refresh
            // must not wipe a working session from the screen.
            authCheckError = error.localizedDescription
            if authChecked {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
            }
        }
    }

    #if os(macOS)
    func setAlwaysOnHost(_ on: Bool) async {
        isSavingHostPolicy = true
        defer { isSavingHostPolicy = false }
        let previous = hostPolicy
        do {
            let next = try await Bridge.setHostPolicy(alwaysOn: on)
            do {
                try HostAgentInstaller.applyPolicy(alwaysOn: next.alwaysOn)
                hostPolicy = next
                errorMessage = nil
            } catch {
                if let previous {
                    _ = try? await Bridge.setHostPolicy(alwaysOn: previous.alwaysOn)
                    try? HostAgentInstaller.applyPolicy(alwaysOn: previous.alwaysOn)
                    hostPolicy = previous
                }
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLimitsSync(_ on: Bool) async {
        do {
            try await Bridge.setLimitsSyncEnabled(on)
            limitsSyncEnabled = on
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

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
        deletionConfirmed = false
        lastSyncSummary = nil
        clearSyncPacing()

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
                #if !os(macOS)
                // One haptic for a real sign-in, not for discovering an
                // existing session on cold launch.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
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

    /// Re-check the account after the deletion browser closes.
    ///
    /// The browser cannot report whether deletion finished, so the app asks
    /// again the moment the sheet is gone. A deleted account answers with
    /// `signedIn: false`, which drops the session (the root swaps to the
    /// login door) and lets that door say why. A present account, meaning the
    /// person closed the browser without deleting, changes nothing.
    func checkAfterAccountDeletion() async {
        await load()
        if account?.signedIn != true {
            deletionConfirmed = true
        }
    }

    func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try await Bridge.signOut()
            lastSyncSummary = nil
            errorMessage = nil
            authCheckError = nil
            clearSyncPacing()
            // Drop the signed-in snapshot immediately so the client root can
            // swap to the login door without waiting on a second network call.
            // load() still runs to refresh host defaults and clear any cache.
            if let host = account?.host {
                account = Account(
                    signedIn: false,
                    host: host,
                    handle: nil,
                    displayName: nil,
                    tier: nil,
                    avatar: nil,
                    lastSyncAt: nil,
                    thisMachineID: nil,
                    machines: [],
                    schemaCurrent: nil,
                    billing: nil
                )
            } else {
                // Still mark checked signed-out so we do not re-enter splash.
                authChecked = true
            }
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
            lastSyncWasRateLimited = false
            showSyncNotice(lastSyncSummary!, isError: false)
            await load()
            startSyncCooldown(fromRateLimit: false)
        } catch {
            // Sync failures are action feedback, not account state. Keep them
            // in the transient notice so a plan cooldown cannot pin the footer.
            errorMessage = nil
            let message = error.localizedDescription
            let rateLimited = Self.isRateLimitMessage(message)
            lastSyncWasRateLimited = rateLimited
            showSyncNotice(message, isError: !rateLimited)
            if rateLimited {
                startSyncCooldown(fromRateLimit: true, message: message)
            }
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

    /// Seconds the Sync now button stays quiet.
    ///
    /// After a success this is only a debounce, capped at five minutes, so a
    /// free-plan hour does not look like a stuck button. After a real 429 the
    /// remaining wait in the gate message is used, capped at the plan
    /// interval, so a press four minutes into a five-minute window is not
    /// held for another full five.
    private func syncCooldownSeconds(fromRateLimit: Bool, message: String? = nil) -> TimeInterval {
        let plan: TimeInterval
        if let secs = account?.syncInterval, secs > 0 {
            plan = TimeInterval(secs)
        } else {
            plan = 5 * 60
        }
        if fromRateLimit {
            if let remaining = message.flatMap(Self.retryAfterSeconds(from:)) {
                return min(max(remaining, 1), plan)
            }
            return plan
        }
        return min(plan, 5 * 60)
    }

    private func startSyncCooldown(fromRateLimit: Bool, message: String? = nil) {
        let seconds = syncCooldownSeconds(fromRateLimit: fromRateLimit, message: message)
        let until = Date().addingTimeInterval(seconds)
        syncCooldownUntil = until
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.syncCooldownUntil == until else { return }
            self.syncCooldownUntil = nil
            self.lastSyncWasRateLimited = false
        }
    }

    private func clearSyncPacing() {
        syncNotice = nil
        syncNoticeIsError = false
        syncCooldownUntil = nil
        lastSyncWasRateLimited = false
    }

    /// The words the host uses when the plan gate refuses, plus the usual
    /// HTTP phrasings a proxy puts in front of the same answer.
    ///
    /// A bare "429" is not enough: a success toast is "Sent 429 rows for …".
    static func isRateLimitMessage(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("may sync once every")
            || lower.contains("not accepting a sync")
            || lower.contains("too many requests")
            || lower.contains("rate limit")
            || lower.contains("http 429")
            || lower.contains("status 429")
    }

    /// Tell the rest of the app (and hostd) when `/me` shows a new plan.
    ///
    /// A purchase on the phone, or a Paddle checkout in the browser, lands
    /// here on the next `account.status`. Home's ten-minute series cache and
    /// hostd's `not_on_this_plan` stop must not outlive that answer.
    ///
    /// The first snapshot after launch is not a plan change. Remint then
    /// only if the tunnel is still sitting on a plan refusal.
    private static func broadcastIfEntitlementChanged(from previous: Account?, to next: Account) async {
        guard next.signedIn else { return }
        let nowAllowed = remoteAllowed(next)
        if previous == nil {
            if nowAllowed, await tunnelRefusedForPlan() {
                _ = try? await Bridge.reconsiderPlan()
            }
            return
        }
        let wasAllowed = remoteAllowed(previous)
        let tierChanged = (previous?.tier ?? "") != (next.tier ?? "")
        guard wasAllowed != nowAllowed || tierChanged else { return }
        if nowAllowed {
            _ = try? await Bridge.reconsiderPlan()
        }
        NotificationCenter.default.post(name: .tokenstatEntitlementDidChange, object: nil)
    }

    private static func tunnelRefusedForPlan() async -> Bool {
        guard let error = try? await Bridge.remoteStatus().tunnelError else { return false }
        let lower = error.lowercased()
        return lower.contains("not_on_this_plan")
            || lower.contains("paid-plan")
            || lower.contains("not on this plan")
    }

    private static func remoteAllowed(_ account: Account?) -> Bool {
        if let remote = account?.canRemote { return remote }
        guard let tier = account?.tier?.lowercased() else { return false }
        return ["patron", "legend"].contains(tier)
    }

    /// Remaining wait from "Try again in N minute(s).", or nil.
    static func retryAfterSeconds(from raw: String) -> TimeInterval? {
        let lower = raw.lowercased()
        guard let regex = try? NSRegularExpression(
            pattern: #"try again in (\d+)\s+(minutes?|hours?|seconds?)"#
        ) else { return nil }
        let ns = lower as NSString
        guard let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3,
              let n = Int(ns.substring(with: match.range(at: 1))),
              n > 0
        else { return nil }
        let unit = ns.substring(with: match.range(at: 2))
        if unit.hasPrefix("hour") { return TimeInterval(n) * 3600 }
        if unit.hasPrefix("second") { return TimeInterval(n) }
        return TimeInterval(n) * 60
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
