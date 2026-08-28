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

    @State private var webURL: URL?

    /// What a failed purchase says.
    ///
    /// A network fault during a purchase means the request never got anywhere,
    /// and the one thing somebody needs to hear is that they were not charged.
    /// Anything else keeps the store's own words: they are about the account
    /// or the product, not about the connection.
    private func purchaseFailureText(_ message: String) -> String {
        let kind = NetworkClassifier.kind(code: "", message: message)
        guard kind.isNetwork else { return message }
        return "Could not reach the store, so nothing was charged. Try again once the "
            + "connection is back."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = store.errorMessage {
                        // A purchase that could not reach anything has to say
                        // plainly that no money moved. Anything vaguer and
                        // somebody presses buy again.
                        Text(purchaseFailureText(message))
                            .font(ClientType.body)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                            .cardSurface()
                    }

                    content(for: account.account)

                    if account.account?.isWebManagedPlan != true {
                        restoreRow
                    }
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
                get: { webURL != nil },
                set: { if !$0 { webURL = nil } }
            )) {
                if let webURL {
                    ClientWebBrowser(url: webURL)
                }
            }
            .manageSubscriptionsSheet(isPresented: Binding(
                get: { store.showManageSheet },
                set: { store.showManageSheet = $0 }
            ))
        }
    }

    @ViewBuilder
    private func content(for signed: Account?) -> some View {
        if signed?.isAppleBilled == true {
            planCards(signed)
        } else if signed?.isWebManagedPlan == true {
            webManagedCard(isPaddle: signed?.isPaddleBilled == true)
        } else {
            planCards(signed)
        }
    }

    /// Paddle, founder access, or any paid tier that is not Apple.
    ///
    /// No URL and no button. Guideline 3.1.1: this app also sells the same
    /// plans through StoreKit, so a link to the website would be a second
    /// purchase path.
    private func webManagedCard(isPaddle: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(isPaddle ? "Website subscription" : "Plan")
                .font(ClientType.sectionTitle)
            Text(isPaddle
                 ? "You subscribed on the website. Manage that plan there. This app cannot change a web subscription."
                 : "This plan is not an App Store purchase. Manage it on the web.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func planCards(_ signed: Account?) -> some View {
        let current: ClientStoreProduct?
        if let signed {
            current = store.currentProduct(from: signed)
        } else {
            current = nil
        }
        let queued = store.queuedProduct()
            ?? ClientStoreProduct.from(tier: signed?.billing?.scheduledTier)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: "Yearly plans", mark: "mark_plan")
            Text("The app stays free. A plan unlocks more devices, longer history, and remote management.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ClientStoreProduct.allCases) { item in
                planCard(item, account: signed, current: current, queued: queued)
            }

            compare
            renewNote
        }
    }

    private func planCard(
        _ item: ClientStoreProduct,
        account: Account?,
        current: ClientStoreProduct?,
        queued: ClientStoreProduct?
    ) -> some View {
        let product = store.product(for: item)
        let trialUsed = account?.billing?.trialUsed == true
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
                } else {
                    Text(store.products.isEmpty ? "Loading price…" : "Price unavailable")
                        .font(ClientType.caption)
                        .foregroundStyle(.tertiary)
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
                            .font(Theme.font(11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 14, height: 16)
                        Text(feat)
                            .font(ClientType.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
            if item == .legend {
                Text("Screen connections try a direct path first. If a relay is needed, it remains end-to-end encrypted. The current generous relay allowance is 20 GiB per rolling 30 days, one relayed screen at a time, with up to 10 minutes per relayed session before reconnecting.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        account: Account?,
        current: ClientStoreProduct?,
        queued: ClientStoreProduct?,
        showTrial: Bool,
        busy: Bool
    ) -> some View {
        let appleLive = account?.billing?.isApple == true && account?.billing?.blocksOtherStore == true
        if current == item {
            actionButton("Your current plan", .currentPlan, accent: false, busy: false, enabled: false) {}
            actionButton("Manage on the App Store", .appStore, accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
            actionButton("Turn off auto-renew", .cancelPlan, accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
        } else if current == nil {
            actionButton(
                showTrial ? "Start 3-day trial" : "Get \(item.title)",
                .billing,
                accent: true,
                busy: busy,
                enabled: product != nil && account != nil && !store.isBusy
            ) {
                guard let product, let account else { return }
                Task { await store.purchase(product, account: account) }
            }
        } else if let current, item.rank > current.rank {
            actionButton(
                "Upgrade to \(item.title)",
                .plans,
                accent: true,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product, let account else { return }
                Task { await store.purchase(product, account: account) }
            }
        } else if queued == item {
            actionButton("Switches next renewal", .scheduled, accent: false, busy: false, enabled: false) {}
            if let keep = store.product(for: current ?? item) {
                actionButton(
                    "Keep \(current?.title ?? "this plan")",
                    .save,
                    accent: false,
                    busy: store.purchasingProductID == keep.id,
                    enabled: !store.isBusy
                ) {
                    guard let account else { return }
                    Task { await store.purchase(keep, account: account) }
                }
            }
        } else if appleLive || current != nil {
            actionButton(
                "Switch at next renewal",
                .scheduled,
                accent: false,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product, let account else { return }
                Task { await store.purchase(product, account: account) }
            }
        }
    }

    private func actionButton(
        _ title: String,
        _ icon: ActionIcon,
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
                    icon.label(title)
                        .labelStyle(ActionLabelStyle())
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

    /// The comparison, Free included. Free is not for sale, but a plan's
    /// pitch ("four devices, a year of history") only lands when the free
    /// tier's own limits are beside it.
    private struct ComparePlan: Identifiable {
        let tier: String
        let title: String
        var id: String { tier }
    }

    private static let comparePlans: [ComparePlan] = [
        ComparePlan(tier: "free", title: "Free"),
        ComparePlan(tier: "supporter", title: "Supporter"),
        ComparePlan(tier: "patron", title: "Patron"),
        ComparePlan(tier: "legend", title: "Legend"),
    ]

    private struct CompareFeature: Identifiable {
        let label: String
        let values: [String]
        var id: String { label }
    }

    private static let compareFeatures: [CompareFeature] = [
        CompareFeature(label: "Devices", values: ["2", "4", "6", "10"]),
        CompareFeature(label: "History", values: ["30 days", "1 yr", "All", "All"]),
        CompareFeature(label: "Terminal + SSH", values: ["No", "No", "Yes", "Yes"]),
        CompareFeature(label: "View screen", values: ["No", "No", "No", "Yes"]),
        CompareFeature(label: "Sync", values: ["Hourly", "30 min", "10 min", "5 min"]),
        CompareFeature(label: "Mark", values: ["None", "Star", "Badge", "Crown"]),
        CompareFeature(label: "Read API", values: ["No", "No", "No", "Yes"]),
    ]

    private var compare: some View {
        DisclosureGroup {
            compareGrid
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

    /// The tier to draw as the reader's own column, or nil until the account
    /// has answered.
    private var currentTier: String? {
        guard let signed = account.account else { return nil }
        return store.currentProduct(from: signed)?.tier ?? signed.tier?.lowercased()
    }

    private var compareGrid: some View {
        let current = currentTier
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(Self.comparePlans) { plan in
                    compareHeader(plan, isCurrent: plan.tier == current)
                }
            }
            ForEach(Self.compareFeatures) { feature in
                GridRow {
                    Text(feature.label)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 7)
                        .padding(.trailing, 8)
                    ForEach(Array(zip(Self.comparePlans, feature.values)), id: \.0.id) { plan, value in
                        compareCell(value, isCurrent: plan.tier == current)
                    }
                }
            }
        }
    }

    private func compareHeader(_ plan: ComparePlan, isCurrent: Bool) -> some View {
        VStack(spacing: 2) {
            Text(plan.title)
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(isCurrent ? Theme.accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if isCurrent {
                Text("Your plan")
                    .font(Theme.font(9, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(compareBackground(isCurrent))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func compareCell(_ value: String, isCurrent: Bool) -> some View {
        Group {
            if value == "Yes" {
                Image(systemName: "checkmark")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Yes")
            } else if value == "No" {
                Image(systemName: "xmark")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .accessibilityLabel("No")
            } else {
                Text(value)
                    .font(ClientType.caption.weight(.medium))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 24)
        .padding(.vertical, 5)
        .background(compareBackground(isCurrent))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compareBackground(_ isCurrent: Bool) -> Color {
        isCurrent ? Theme.accent.opacity(0.08) : Color.clear
    }

    private func renewalOffCaption(account: Account?, item: ClientStoreProduct) -> String {
        if let end = store.expirationDate {
            let text = end.formatted(date: .abbreviated, time: .omitted)
            return "Renewal is off. You keep \(item.title) until \(text)."
        }
        if let raw = account?.billing?.periodEnd, let parsed = ISO8601DateFormatter().date(from: raw) {
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
                    ActionIcon.restore.label("Restore purchases")
                        .labelStyle(ActionLabelStyle())
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
            Button("Privacy", .external) { webURL = ClientWebPages.privacy() }
            Button("Terms", .external) { webURL = ClientWebPages.terms() }
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
