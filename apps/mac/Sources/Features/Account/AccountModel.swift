// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Observable
@MainActor
final class AccountModel {
    var account: Account? {
        didSet {
            let previous = WorkSessionContext.shared.scope
            WorkSessionContext.shared.update(account: account)
            EcosystemPublisher.verifyOwner(account: account)
            if let previous, previous != WorkSessionContext.shared.scope {
                WorkSearchHistory.invalidate(except: WorkSessionContext.shared.scope)
                Task { try? await ChatAttachmentCache.shared.purge() }
            }
        }
    }
    var remoteStatus: RemoteStatus?
    var pendingLogin: DeviceLogin?
    var isLoading = false
    var isSyncing = false
    var isSigningOut = false
    var limitsSyncEnabled: Bool { PlanLimitsStore.shared.enabled }
    var limitsSkip: [String] { PlanLimitsStore.shared.skip }
    var limitsProviders: [ProviderLimits] { PlanLimits.visible(PlanLimitsStore.shared.providers) }
    var isLoadingLimits = false
    #if os(macOS)
    var hostPolicy: HostPolicy?
    var isSavingHostPolicy = false
    #endif
    var errorMessage: String?
    var lastSyncSummary: String?
    private(set) var syncGeneration = 0
    var syncNotice: String?
    private(set) var syncNoticeDismissed = false
    var syncNoticeIsError = false
    var syncCooldownUntil: Date?
    var lastSyncWasRateLimited = false

    private var pollTask: Task<Void, Never>?
    private var noticeGeneration = 0

    @ObservationIgnored var signInPresenter: ((URL) -> Void)?

    @ObservationIgnored var signInDismisser: (() -> Void)?

    private(set) var signInNotice: String?

    private(set) var authChecked = false

    private(set) var authCheckError: String?

    private(set) var deletionConfirmed = false

    var signedIn: Bool { account?.signedIn == true }

    var authPending: Bool { !authChecked && authCheckError == nil }

    var authNeedsRetry: Bool { !authChecked && authCheckError != nil }

    var isRateLimited: Bool { lastSyncWasRateLimited }

    private var accountLoadGeneration: UInt64 = 0

    func load(afterSignOut: Bool = false) async {
        guard !isLoading, !isSigningOut || afterSignOut else { return }
        isLoading = true
        let generation = accountLoadGeneration
        defer { if generation == accountLoadGeneration { isLoading = false } }
        do {
            let previous = account
            let next = try await Bridge.account()
            guard generation == accountLoadGeneration else { return }
            account = next
            errorMessage = nil
            authCheckError = nil
            authChecked = true
            let verifiedScope = WorkSessionContext.shared.scope.map(WorkCache.scope)
            await WorkCacheCleanupJournal.shared.recover(verifiedScope: verifiedScope,
                accountKnown: !next.signedIn || verifiedScope != nil,
                stillValid: { generation == self.accountLoadGeneration && (!self.isSigningOut || afterSignOut) },
                deleteKey: { await WorkCacheKey.delete(for: $0) },
                clear: { _ = try await Bridge.cacheClearScope(scope: $0) })
            guard generation == accountLoadGeneration else { return }
            if let status = try? await Bridge.remoteStatus() {
                guard generation == accountLoadGeneration else { return }
                remoteStatus = status
            }
            #if os(macOS)
            let limitsRead = PlanLimitsStore.shared.settingsRead()
            let limits = try? await Bridge.limitsSync()
            guard generation == accountLoadGeneration else { return }
            if let limits { PlanLimitsStore.shared.acceptCachedSettings(limits, requested: limitsRead) }
            let policy = try? await Bridge.hostPolicy()
            guard generation == accountLoadGeneration else { return }
            hostPolicy = policy
            #endif
            await Self.broadcastIfEntitlementChanged(from: previous, to: next)
        } catch {
            guard generation == accountLoadGeneration else { return }
            authCheckError = error.localizedDescription
            if authChecked {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = nil
            }
        }
    }

    func loadTraffic() async {
        if let status = try? await Bridge.remoteStatus() {
            remoteStatus = status
        }
    }

    func setRelayFallback(_ enabled: Bool) async throws {
        remoteStatus = try await Bridge.setRelayFallback(enabled)
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
            applyLimitsSync(try await Bridge.limitsSync())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLimitsSourceShared(_ source: String, shared: Bool) async {
        do {
            applyLimitsSync(try await Bridge.setLimitsSourceShared(source, shared: shared))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadLimitsIfNeeded() async {
        guard !isLoadingLimits else { return }
        isLoadingLimits = true
        defer { isLoadingLimits = false }
        try? await PlanLimitsStore.shared.refresh()
    }

    private func applyLimitsSync(_ state: LimitsSyncState) {
        PlanLimitsStore.shared.settingsChanged(state)
    }

    func sharesLimits(of source: String) -> Bool {
        !limitsSkip.contains(source)
    }
    #endif

    func signIn() {
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
        var consecutiveTransportFailures = 0

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()

            let poll: DevicePoll
            do {
                poll = try await Bridge.pollLogin()
            } catch {
                switch Self.signInPollFailure(error) {
                case .transport:
                    // A dropped packet is recoverable, but a dead path must not
                    // leave App Review looking at a spinner for fifteen minutes.
                    consecutiveTransportFailures += 1
                    if consecutiveTransportFailures < 3 {
                        signInNotice = L10n.text("apple.accountmodel.waiting_for_the_network.76a08f16")
                        try await Task.sleep(for: .seconds(max(interval, 3)))
                        continue
                    }
                    signInDismisser?()
                    signInNotice = nil
                    await Bridge.cancelLogin()
                    throw SignInFailure.message(
                        L10n.text("apple.accountmodel.the_account_service_could_not_be_reached_a.445bdbf0")
                    )
                case .invalidGrant:
                    signInDismisser?()
                    signInNotice = nil
                    await Bridge.cancelLogin()
                    throw SignInFailure.message(L10n.text("apple.accountmodel.that_sign_in_expired_start_again.28cffde9"))
                case .terminal:
                    signInDismisser?()
                    signInNotice = nil
                    await Bridge.cancelLogin()
                    throw error
                }
            }
            consecutiveTransportFailures = 0
            signInNotice = nil

            if poll.isConfirmed {
                signInDismisser?()
                await load()
                _ = try? await Bridge.reconsiderPlan()
                #if !os(macOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                return
            }
            interval = poll.interval ?? interval
        }

        signInDismisser?()
        signInNotice = nil
        await Bridge.cancelLogin()
        errorMessage = L10n.text("apple.accountmodel.the_sign_in_code_expired_before_it_was_con.84ac1b4b")
    }

    private enum SignInPollFailure {
        case transport
        case invalidGrant
        case terminal
    }

    private enum SignInFailure: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            }
        }
    }

    private static func signInPollFailure(_ error: Error) -> SignInPollFailure {
        guard let bridge = error as? BridgeError,
              case let .core(code, _) = bridge else {
            return error is URLError ? .transport : .terminal
        }
        switch code {
        case "device_transport", "offline", "host_timeout", "host_unreachable":
            return .transport
        case "device_invalid_grant":
            return .invalidGrant
        default:
            return .terminal
        }
    }

    func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingLogin = nil
        signInNotice = nil
        signInDismisser?()
        Task { await Bridge.cancelLogin() }
    }

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
        let purgeScope = account.flatMap { signed in
            WorkReference.Scope.accountIdentity(handle: signed.handle, id: signed.accountId)
                .flatMap { WorkReference.Scope.account(origin: signed.host, handle: $0) }
        }
        do {
            if let purgeScope { try WorkCacheCleanupJournal.shared.prepare(scope: WorkCache.scope(for: purgeScope)) }
            accountLoadGeneration &+= 1
            isLoading = false
            try await Bridge.signOut()
            EcosystemPublisher.clear()
            accountLoadGeneration &+= 1
            isLoading = false
            if let purgeScope { try? WorkCacheCleanupJournal.shared.confirm(scope: WorkCache.scope(for: purgeScope)) }
            lastSyncSummary = nil
            errorMessage = nil
            authCheckError = nil
            clearSyncPacing()
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
                authChecked = true
            }
            if let purgeScope { WorkAccessStore.shared.clear(scope: purgeScope) }
            await WorkCacheCleanupJournal.shared.recover(verifiedScope: nil, accountKnown: true,
                deleteKey: { await WorkCacheKey.delete(for: $0) },
                clear: { _ = try await Bridge.cacheClearScope(scope: $0) })
            await load(afterSignOut: true)
        } catch {
            let failure = error.localizedDescription
            await load(afterSignOut: true)
            if signedIn { errorMessage = failure }
        }
    }

    func sync() async {
        guard !isSyncing, syncCooldownUntil == nil else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let result = try await Bridge.sync()
            lastSyncSummary = L10n.text("apple.accountmodel.sent_0_rows_for_1_to_2.5066c9eb", "\(result.rows)", "\(result.from)", "\(result.to)")
            lastSyncWasRateLimited = false
            showSyncNotice(lastSyncSummary!, isError: false)
            await load()
            syncGeneration += 1
            startSyncCooldown(fromRateLimit: false)
        } catch {
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

    func dismissSyncNotice() {
        syncNoticeDismissed = true
        syncNotice = nil
    }

    private func showSyncNotice(_ message: String, isError: Bool) {
        syncNoticeDismissed = false
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
        syncNoticeDismissed = false
        syncNotice = nil
        syncNoticeIsError = false
        syncCooldownUntil = nil
        lastSyncWasRateLimited = false
    }

    static func isRateLimitMessage(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("may sync once every")
            || lower.contains("not accepting a sync")
            || lower.contains("too many requests")
            || lower.contains("rate limit")
            || lower.contains("http 429")
            || lower.contains("status 429")
    }

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
        return ["free", "supporter", "patron", "legend"].contains(tier)
    }

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


extension AccountModel {
    var handleOfferDue: Bool {
        guard let account, account.signedIn, (account.handle ?? "").isEmpty,
              account.profile?.handlePrompted == false else { return false }
        return !UserDefaults.standard.bool(forKey: Self.offerKey(account))
    }

    func beginHandleOffer() -> Bool {
        guard handleOfferDue, !Self.offeringHandle else { return false }
        Self.offeringHandle = true
        return true
    }

    func answerHandleOffer() async {
        Self.offeringHandle = false
        guard let account, account.signedIn else { return }
        UserDefaults.standard.set(true, forKey: Self.offerKey(account))
        guard (account.handle ?? "").isEmpty else { return }
        try? await adopt { try await Bridge.skipHandle() }
    }

    func claimHandle(_ handle: String) async throws {
        try await adopt { try await Bridge.claimHandle(handle) }
    }

    func setProfile(public isPublic: Bool? = nil, indexable: Bool? = nil) async throws {
        try await adopt { try await Bridge.setProfile(public: isPublic, indexable: indexable) }
    }

    private func adopt(_ change: () async throws -> Account) async throws {
        let generation = accountLoadGeneration
        let scope = WorkSessionContext.shared.scope
        let next = try await change()
        guard signedIn, !isSigningOut, scope == WorkSessionContext.shared.scope,
              generation == accountLoadGeneration || next.accountId == account?.accountId
        else { throw CancellationError() }
        accountLoadGeneration &+= 1
        isLoading = false
        account = next
    }

    private static var offeringHandle = false

    private static func offerKey(_ account: Account) -> String {
        "handle.offerAnswered.v1.\(account.host)|\(account.accountId ?? "")"
    }
}

private func openInBrowser(_ raw: String) {
    guard let url = URL(string: raw) else { return }
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
