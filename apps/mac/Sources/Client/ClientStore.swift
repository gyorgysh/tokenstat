// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import StoreKit

#if !os(macOS)

/// App Store yearly plans. Same rungs and prices as the website, billed by
/// Apple. The Mac target must not compile this file into a purchase path.
enum ClientStoreProduct: String, CaseIterable, Identifiable {
    case supporter = "ai.tokenstat.supporter.yearly"
    case patron = "ai.tokenstat.patron.yearly"
    case legend = "ai.tokenstat.legend.yearly"

    var id: String { rawValue }

    var tier: String {
        switch self {
        case .supporter: return "supporter"
        case .patron: return "patron"
        case .legend: return "legend"
        }
    }

    var title: String {
        switch self {
        case .supporter: return "Supporter"
        case .patron: return "Patron"
        case .legend: return "Legend"
        }
    }

    var summary: String {
        switch self {
        case .supporter: return "A yearly plan. More devices, a longer history, and a nicer profile."
        case .patron: return "For people running agents on everything they own, and reaching those machines from anywhere."
        case .legend: return "The top plan. More devices, a faster page, the read API, and first in line when something new lands."
        }
    }

    /// Same ladder as the website and the StoreKit group.
    var rank: Int {
        switch self {
        case .supporter: return 1
        case .patron: return 2
        case .legend: return 3
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
                "Profile updates every 30 minutes, not hourly",
                "The supporter star next to your name",
            ]
        case .patron:
            return [
                "Everything in Supporter",
                "Remote management: your other devices, from the app",
                "6 devices, added up into one profile",
                "Every day you have ever synced, with no window",
                "Profile updates every 10 minutes",
                "The patron badge next to your name",
            ]
        case .legend:
            return [
                "Everything in Patron",
                "10 devices, added up into one profile",
                "Profile updates every 5 minutes",
                "The legend crown next to your name",
                "Read API: your numbers as JSON or CSV",
                "First in line when something new lands",
            ]
        }
    }

    static func from(tier: String?) -> ClientStoreProduct? {
        switch tier?.lowercased() {
        case "supporter": return .supporter
        case "patron": return .patron
        case "legend": return .legend
        default: return nil
        }
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

    private var updatesTask: Task<Void, Never>?

    var isBusy: Bool { isLoading || purchasingProductID != nil || isRestoring }

    func product(for item: ClientStoreProduct) -> Product? {
        products.first { $0.id == item.rawValue }
    }

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { await loadProducts() }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
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

    func purchase(_ product: Product, account: Account) async {
        guard purchasingProductID == nil else { return }
        guard let raw = account.billing?.appAccountToken,
              let token = UUID(uuidString: raw) else {
            errorMessage = "Could not start this purchase. Sign out and sign in again."
            return
        }
        purchasingProductID = product.id
        errorMessage = nil
        defer { purchasingProductID = nil }
        do {
            let options: Set<Product.PurchaseOption> = [.appAccountToken(token)]
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
    func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        do {
            try await activate(result)
            return true
        } catch {
            errorMessage = error.localizedDescription
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
        for product in products {
            guard let statuses = try? await product.subscription?.status else { continue }
            for status in statuses {
                if let info = try? checkVerified(status.renewalInfo) {
                    autoRenewProductID = info.autoRenewPreference
                    willAutoRenew = info.willAutoRenew
                }
                if let transaction = try? checkVerified(status.transaction) {
                    currentProductID = transaction.productID
                    expirationDate = transaction.expirationDate
                }
            }
            return
        }
    }

    func currentProduct(from account: Account) -> ClientStoreProduct? {
        if let id = currentProductID {
            return ClientStoreProduct(rawValue: id)
        }
        return ClientStoreProduct.from(tier: account.tier)
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
