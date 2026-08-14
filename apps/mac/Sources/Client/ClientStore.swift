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
        case .supporter: return "A year of history and three devices."
        case .patron: return "Full history, more devices, remote management."
        case .legend: return "The top plan: more devices, faster sync, the read API."
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
    }

    private func checkVerified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            throw error
        }
    }
}

#endif
