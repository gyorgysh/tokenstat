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
/// Always shows every rung. A live Apple plan still lists the others so
/// upgrade, switch-at-renewal, and cancel are on this page, not only in
/// Apple's manage sheet. A Paddle plan stays text only.
struct ClientPaywallView: View {
    @Environment(AccountModel.self) private var account
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                await store.refreshSubscriptionStatus()
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
        } else {
            planCards(signed)
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

    private func planCards(_ signed: Account) -> some View {
        let current = store.currentProduct(from: signed)
        let queued = store.queuedProduct()
            ?? ClientStoreProduct.from(tier: signed.billing?.scheduledTier)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
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
                planCard(item, account: signed, current: current, queued: queued)
            }

            compare
            renewNote
        }
    }

    private func planCard(
        _ item: ClientStoreProduct,
        account: Account,
        current: ClientStoreProduct?,
        queued: ClientStoreProduct?
    ) -> some View {
        let product = store.product(for: item)
        let trialUsed = account.billing?.trialUsed == true
        let intro = product?.subscription?.introductoryOffer
        let showTrial = item == .patron && current == nil && !trialUsed && intro != nil
        let busy = store.purchasingProductID == item.rawValue
        let isCurrent = current == item
        let isQueued = queued == item && current != item

        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                PaywallTierMark(tier: item.tier, reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(ClientType.sectionTitle)
                    if isCurrent {
                        Text("Your current plan")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    } else if isQueued {
                        Text("Switches next renewal")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.feats, id: \.self) { feat in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 14, height: 16)
                        Text(feat)
                            .font(ClientType.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
            if showTrial {
                Text("3 days free, then the yearly price. Once per account.")
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
            if isCurrent, !store.willAutoRenew {
                Text(renewalOffCaption(account: account, item: item))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            planActions(
                item,
                product: product,
                account: account,
                current: current,
                queued: queued,
                showTrial: showTrial,
                busy: busy
            )
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func planActions(
        _ item: ClientStoreProduct,
        product: Product?,
        account: Account,
        current: ClientStoreProduct?,
        queued: ClientStoreProduct?,
        showTrial: Bool,
        busy: Bool
    ) -> some View {
        let appleLive = account.billing?.isApple == true && account.billing?.blocksOtherStore == true
        if current == item {
            actionButton("Your current plan", accent: false, busy: false, enabled: false) {}
            actionButton("Manage on the App Store", accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
            actionButton("Turn off auto-renew", accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
        } else if current == nil {
            actionButton(
                showTrial ? "Start 3-day trial" : "Get \(item.title)",
                accent: true,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product else { return }
                Task { await store.purchase(product, account: account) }
            }
        } else if let current, item.rank > current.rank {
            actionButton(
                "Upgrade to \(item.title)",
                accent: true,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product else { return }
                Task { await store.purchase(product, account: account) }
            }
        } else if queued == item {
            actionButton("Switches next renewal", accent: false, busy: false, enabled: false) {}
            if let keep = store.product(for: current ?? item) {
                actionButton(
                    "Keep \(current?.title ?? "this plan")",
                    accent: false,
                    busy: store.purchasingProductID == keep.id,
                    enabled: !store.isBusy
                ) {
                    Task { await store.purchase(keep, account: account) }
                }
            }
        } else if appleLive || current != nil {
            actionButton(
                "Switch at next renewal",
                accent: false,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product else { return }
                Task { await store.purchase(product, account: account) }
            }
        }
    }

    private func actionButton(
        _ title: String,
        accent: Bool,
        busy: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView()
                } else {
                    Text(title)
                }
            }
            .font(ClientType.label.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Color.white : Theme.accent)
        .background(
            (accent ? Theme.accent : Theme.accentSoft),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.55)
    }

    private var compare: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                compareRow("Devices", values: ["4", "6", "10"])
                compareRow("History", values: ["1 year", "Everything", "Everything"])
                compareRow("Remote", values: ["No", "Yes", "Yes"])
                compareRow("Sync", values: ["30 min", "10 min", "5 min"])
                compareRow("Mark", values: ["Star", "Badge", "Crown"])
                compareRow("Read API", values: ["No", "No", "Yes"])
            }
            .padding(.top, Theme.Space.s)
        } label: {
            Text("Compare plans")
                .font(ClientType.label.weight(.semibold))
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .tint(Theme.accent)
    }

    private func compareRow(_ label: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(Array(zip(ClientStoreProduct.allCases, values)), id: \.0.id) { item, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(ClientType.caption)
                            .foregroundStyle(.tertiary)
                        Text(value)
                            .font(ClientType.label.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func renewalOffCaption(account: Account, item: ClientStoreProduct) -> String {
        if let end = store.expirationDate {
            let text = end.formatted(date: .abbreviated, time: .omitted)
            return "Renewal is off. You keep \(item.title) until \(text)."
        }
        if let raw = account.billing?.periodEnd, let parsed = ISO8601DateFormatter().date(from: raw) {
            let text = parsed.formatted(date: .abbreviated, time: .omitted)
            return "Renewal is off. You keep \(item.title) until \(text)."
        }
        return "Renewal is off. You keep \(item.title) until the period ends."
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

/// Website hover on the tier mark: a one-shot lift on appear.
private struct PaywallTierMark: View {
    let tier: String
    let reduceMotion: Bool
    @State private var lifted = false

    var body: some View {
        TierMark(tier: tier, size: 26)
            .offset(y: lifted ? 0 : 3)
            .rotationEffect(.degrees(lifted ? 0 : 6))
            .onAppear {
                guard !reduceMotion else {
                    lifted = true
                    return
                }
                withAnimation(.spring(duration: 0.48, bounce: 0.28)) {
                    lifted = true
                }
            }
    }
}

#endif
