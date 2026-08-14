// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import StoreKit
import SwiftUI

#if !os(macOS)

/// In-app yearly plans. Required chrome: Restore, Privacy, Terms.
///
/// Does not link to the website pricing page. A Paddle plan is text only.
struct ClientPaywallView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var legalURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = store.errorMessage {
                        Text(message)
                            .font(ClientType.body)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                            .cardSurface()
                    }

                    if let signed = account.account {
                        content(for: signed)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(Theme.Space.xl)
                    }

                    restoreRow
                    legalRow
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xl)
            }
            .background(Theme.background)
            .navigationTitle("Plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                store.start()
                if account.account == nil { await account.load() }
            }
            .sheet(isPresented: Binding(
                get: { legalURL != nil },
                set: { if !$0 { legalURL = nil } }
            )) {
                if let legalURL {
                    ClientLegalBrowser(url: legalURL)
                }
            }
            .manageSubscriptionsSheet(isPresented: Binding(
                get: { store.showManageSheet },
                set: { store.showManageSheet = $0 }
            ))
        }
    }

    @ViewBuilder
    private func content(for signed: Account) -> some View {
        let billing = signed.billing
        if billing?.isPaddle == true && billing?.blocksOtherStore == true {
            paddleCard
        } else if billing?.isApple == true && billing?.blocksOtherStore == true {
            appleManagedCard(signed)
        } else {
            buyCards(signed)
        }
    }

    private var paddleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Website subscription")
                .font(ClientType.sectionTitle)
            Text("You subscribed on the website. Manage that plan there. This app cannot change a web subscription.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func appleManagedCard(_ signed: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text((signed.tier?.capitalized ?? "Paid") + " plan")
                .font(ClientType.sectionTitle)
            Text("This plan was bought on the App Store. Change or cancel it there.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.showManageSheet = true
            } label: {
                Text("Manage subscription")
                    .font(ClientType.label.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func buyCards(_ signed: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Yearly plans")
                .font(ClientType.sectionTitle)
            Text("The app stays free. A plan unlocks more devices, longer history, and remote management.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isLoading && store.products.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Space.l)
            }

            ForEach(ClientStoreProduct.allCases) { item in
                planRow(item, account: signed)
            }

            renewNote
        }
    }

    private func planRow(_ item: ClientStoreProduct, account: Account) -> some View {
        let product = store.product(for: item)
        let trialUsed = account.billing?.trialUsed == true
        let intro = product?.subscription?.introductoryOffer
        let showTrial = item == .patron && !trialUsed && intro != nil
        let busy = store.purchasingProductID == item.rawValue

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(ClientType.sectionTitle)
                Spacer()
                if let product {
                    Text(product.displayPrice + " / year")
                        .font(ClientType.label.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.summary)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if showTrial {
                Text("3 days free, then the yearly price. Once per account.")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
            Button {
                guard let product else { return }
                Task { await store.purchase(product, account: account) }
            } label: {
                Group {
                    if busy {
                        ProgressView()
                    } else if showTrial {
                        Text("Start 3-day trial")
                    } else {
                        Text("Get \(item.title)")
                    }
                }
                .font(ClientType.label.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(product == nil || store.isBusy)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var restoreRow: some View {
        Button {
            guard account.account != nil else { return }
            Task { await store.restore() }
        } label: {
            Group {
                if store.isRestoring {
                    ProgressView()
                } else {
                    Text("Restore purchases")
                }
            }
            .font(ClientType.label.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy || account.account == nil)
    }

    private var legalRow: some View {
        HStack(spacing: Theme.Space.l) {
            Button("Privacy") { legalURL = ClientWebPages.privacy() }
            Button("Terms") { legalURL = ClientWebPages.terms() }
        }
        .font(ClientType.caption.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
    }

    private var renewNote: some View {
        Text("Yearly plans renew automatically unless you turn auto-renew off at least 24 hours before the period ends. Payment is charged to your Apple ID. Manage or cancel in Apple ID subscriptions.")
            .font(ClientType.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Space.s)
    }
}

#endif
