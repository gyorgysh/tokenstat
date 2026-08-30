// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import StoreKit

#if !os(macOS)

enum ClientStoreInterval: String {
    case year
    case month
}

/// App Store plans. Same rungs and prices as the website, billed by
/// Apple. The Mac target must not compile this file into a purchase path.
enum ClientStoreProduct: String, CaseIterable, Identifiable {
    case supporter = "ai.tokenstat.supporter.yearly"
    case patron = "ai.tokenstat.patron.yearly"
    case legend = "ai.tokenstat.legend.yearly"
    case patronMonthly = "ai.tokenstat.patron.monthly"
    case legendMonthly = "ai.tokenstat.legend.monthly"

    var id: String { rawValue }

    var interval: ClientStoreInterval {
        switch self {
        case .supporter, .patron, .legend: return .year
        case .patronMonthly, .legendMonthly: return .month
        }
    }

    var tier: String {
        switch self {
        case .supporter: return "supporter"
        case .patron, .patronMonthly: return "patron"
        case .legend, .legendMonthly: return "legend"
        }
    }

    var title: String {
        switch self {
        case .supporter: return "Supporter"
        case .patron, .patronMonthly: return "Patron"
        case .legend, .legendMonthly: return "Legend"
        }
    }

    var summary: String {
        switch self {
        case .supporter: return "A year of heatmap across your devices, encrypted vault sync, and a public profile worth sharing."
        case .patron, .patronMonthly: return "For people running agents on everything they own, and reaching those machines from anywhere."
        case .legend, .legendMonthly: return "The top plan. View and control your own screen remotely, plus more devices, faster sync, and the read API."
        }
    }

    /// Same ladder as the website and the StoreKit group.
    var rank: Int {
        switch self {
        case .supporter: return 1
        case .patron, .patronMonthly: return 2
        case .legend, .legendMonthly: return 3
        }
    }

    /// Website `TIERS[].feats`, shortened for a phone. Same words.
    var feats: [String] {
        switch self {
        case .supporter:
            return [
                "Everything in Free",
                "4 devices, added up into one profile",
                "A year of history on your profile, not 30 days",
                "End-to-end encrypted SSH vault sync across your devices",
                "The supporter star next to your name",
            ]
        case .patron, .patronMonthly:
            return [
                "Everything in Supporter",
                "Remote management: your other devices, from the app",
                "6 devices, added up into one profile",
                "Every day you have ever synced, with no window",
                "Profile updates every 10 minutes",
                "The patron badge next to your name",
            ]
        case .legend, .legendMonthly:
            return [
                "Everything in Patron",
                "Remote screen viewing and control",
                "Direct connection first; end-to-end encrypted relay fallback",
                "10 devices, added up into one profile",
                "Profile updates every 5 minutes",
                "The legend crown next to your name",
                "Read API: your numbers as JSON or CSV",
                "First in line when something new lands",
            ]
        }
    }

    static func from(tier: String?, interval: ClientStoreInterval = .year) -> ClientStoreProduct? {
        switch (tier?.lowercased(), interval) {
        case ("supporter", _): return .supporter
        case ("patron", .month): return .patronMonthly
        case ("patron", _): return .patron
        case ("legend", .month): return .legendMonthly
        case ("legend", _): return .legend
        default: return nil
        }
    }

    static func interval(from raw: String?) -> ClientStoreInterval {
        raw == "month" ? .month : .year
    }

    static func catalog(interval: ClientStoreInterval) -> [ClientStoreProduct] {
        allCases.filter { $0.interval == interval }
    }
}

/// StoreKit 2 purchases for the iOS client.
///
/// After Apple confirms a transaction, the signed JWS is posted to the
/// account host so entitlement matches the website. One live plan per
/// account. A Paddle plan is not bought again here.
@Observable
@MainActor
final class ClientStore {
    var products: [Product] = []
    var isLoading = false
    var purchasingProductID: String?
    var isRestoring = false
    var errorMessage: String?
    var showPaywall = false
    var showManageSheet = false
    /// StoreKit's current product in the `tokenstat.plans` group.
    var currentProductID: String?
    /// What will renew next. Lower than current means a queued downgrade.
    var autoRenewProductID: String?
    var willAutoRenew = true
    var expirationDate: Date?

    /// Written by the root so a successful purchase updates the same account
    /// model the rest of the app is already reading.
    @ObservationIgnored var onAccountChange: ((Account) -> Void)?
    /// Current signed-in account, if any. A product-page tap has to attach
    /// this account's `appAccountToken` or the receipt has no owner.
    @ObservationIgnored var currentAccount: (() -> Account?)?

    private var updatesTask: Task<Void, Never>?
    private var intentsTask: Task<Void, Never>?
    /// Product-page tap waiting on sign-in. One at a time.
    private var pendingIntent: PurchaseIntent?

    var isBusy: Bool { isLoading || purchasingProductID != nil || isRestoring }

    func product(for item: ClientStoreProduct) -> Product? {
        products.first { $0.id == item.rawValue }
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                // Quietly: nobody asked for this one. StoreKit redelivers
                // unfinished transactions at launch, and a phone that is
                // offline or not signed in yet cannot activate them. Writing
                // the failure here put a message on the paywall that the
                // person then met later, about something they had not done.
                // The transaction stays unfinished and comes back.
                await self?.handle(result, quietly: true)
            }
        }
        // App Store Connect will not turn Streamlined Purchasing off until
        // the latest approved binary listens on `PurchaseIntent.intents`.
        intentsTask = Task { [weak self] in
            for await intent in PurchaseIntent.intents {
                await self?.handle(intent)
            }
        }
        Task { await loadProducts() }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        intentsTask?.cancel()
        intentsTask = nil
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = ClientStoreProduct.allCases.map(\.rawValue)
            products = try await Product.products(for: ids)
                .sorted { $0.price < $1.price }
            errorMessage = nil
            await refreshSubscriptionStatus()
        } catch {
            errorMessage = "Could not load App Store plans."
        }
    }

    /// A tap from the App Store product page. Completes now if someone is
    /// signed in, otherwise waits for `finishPendingIntent`.
    func handle(_ intent: PurchaseIntent) async {
        guard ClientStoreProduct(rawValue: intent.product.id) != nil else { return }
        pendingIntent = intent
        if let account = currentAccount?() {
            await finishPendingIntent(with: account)
        }
    }

    func finishPendingIntent(with account: Account) async {
        guard let intent = pendingIntent, purchasingProductID == nil else { return }
        var offer: Product.SubscriptionOffer?
        if #available(iOS 18.0, *) {
            offer = intent.offer
        }
        await purchase(intent.product, account: account, offer: offer)
    }

    func purchase(
        _ product: Product,
        account: Account,
        offer: Product.SubscriptionOffer? = nil
    ) async {
        guard purchasingProductID == nil else { return }
        guard let raw = account.billing?.appAccountToken,
              let token = UUID(uuidString: raw) else {
            errorMessage = "Could not start this purchase. Sign out and sign in again."
            return
        }
        purchasingProductID = product.id
        errorMessage = nil
        defer { purchasingProductID = nil }
        // The intent has been acted on the moment StoreKit is asked, whatever
        // comes back. Clearing it only on success and cancel left it standing
        // through "waiting for approval" and through a thrown purchase, and
        // every later account refresh calls `finishPendingIntent` again: a
        // child waiting on Ask to Buy would get the purchase sheet put back in
        // front of them on a loop.
        //
        // Deliberately below the guards above. A purchase that never reached
        // StoreKit because the account had no token yet is worth retrying once
        // there is one, and that is the case this does not cover.
        defer { if pendingIntent?.id == product.id { pendingIntent = nil } }
        do {
            var options: Set<Product.PurchaseOption> = [.appAccountToken(token)]
            if #available(iOS 18.0, *), let offer, offer.type == .winBack {
                options.insert(.winBackOffer(offer))
            }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                try await activate(verification)
                await reportRenewal()
            case .userCancelled:
                break
            case .pending:
                errorMessage = "This purchase is waiting for approval."
            @unknown default:
                errorMessage = "The purchase did not finish."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            var activated = false
            for await result in Transaction.currentEntitlements {
                if await handle(result) { activated = true }
            }
            if !activated {
                errorMessage = "No App Store purchase found for this Apple ID."
            }
            await reportRenewal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func handle(_ result: VerificationResult<Transaction>, quietly: Bool = false) async -> Bool {
        do {
            try await activate(result)
            return true
        } catch {
            if !quietly { errorMessage = error.localizedDescription }
            return false
        }
    }

    private func activate(_ result: VerificationResult<Transaction>) async throws {
        let transaction = try checkVerified(result)
        let account = try await Bridge.appleActivate(signedTransaction: result.jwsRepresentation)
        onAccountChange?(account)
        await transaction.finish()
        await refreshSubscriptionStatus()
    }

    /// What StoreKit will do at the next renewal. A downgrade often has no
    /// new transaction until then, so this is the only way the website sees
    /// the queued drop immediately.
    func reportRenewal() async {
        await refreshSubscriptionStatus()
        for product in products {
            guard let statuses = try? await product.subscription?.status else { continue }
            for status in statuses {
                if let account = try? await Bridge.appleRenewal(
                    signedRenewalInfo: status.renewalInfo.jwsRepresentation
                ) {
                    onAccountChange?(account)
                    return
                }
            }
        }
    }

    func refreshSubscriptionStatus() async {
        var liveProductID: String?
        var liveAutoRenewID: String?
        var liveWillRenew = false
        var liveExpiration: Date?
        var foundLive = false
        for product in products {
            guard let statuses = try? await product.subscription?.status, !statuses.isEmpty else {
                continue
            }
            for status in statuses {
                switch status.state {
                case .subscribed, .inGracePeriod, .inBillingRetryPeriod:
                    foundLive = true
                    if let info = try? checkVerified(status.renewalInfo) {
                        liveAutoRenewID = info.autoRenewPreference
                        liveWillRenew = info.willAutoRenew
                    }
                    if let transaction = try? checkVerified(status.transaction) {
                        liveProductID = transaction.productID
                        liveExpiration = transaction.expirationDate
                    }
                default:
                    break
                }
            }
            if foundLive { break }
        }
        if foundLive {
            currentProductID = liveProductID
            autoRenewProductID = liveAutoRenewID
            willAutoRenew = liveWillRenew
            expirationDate = liveExpiration
        } else {
            currentProductID = nil
            autoRenewProductID = nil
            willAutoRenew = false
            expirationDate = nil
        }
    }

    func currentProduct(from account: Account) -> ClientStoreProduct? {
        // A paid tier is not an App Store product. Founder / family access and
        // a website subscription must not open Apple's manage sheet.
        guard account.isAppleBilled else { return nil }
        if let id = currentProductID {
            return ClientStoreProduct(rawValue: id)
        }
        return ClientStoreProduct.from(
            tier: account.tier,
            interval: ClientStoreProduct.interval(from: account.billing?.interval)
        )
    }

    func queuedProduct() -> ClientStoreProduct? {
        guard let id = autoRenewProductID, id != currentProductID else { return nil }
        return ClientStoreProduct(rawValue: id)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}

#endif
