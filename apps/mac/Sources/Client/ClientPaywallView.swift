// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import StoreKit
import SwiftUI

#if !os(macOS)

/// In-app plans, yearly by default. Required chrome: Restore, Privacy, Terms.
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
    @State private var bill: ClientStoreInterval = .year

    /// What a failed purchase says.
    ///
    /// A network fault during a purchase means the request never got anywhere,
    /// and the one thing somebody needs to hear is that they were not charged.
    /// Anything else keeps the store's own words: they are about the account
    /// or the product, not about the connection.
    private func purchaseFailureText(_ message: String) -> String {
        let kind = NetworkClassifier.kind(code: "", message: message)
        guard kind.isNetwork else { return message }
        return L10n.text("apple.clientpaywallview.could_not_reach_the_store_so_nothing_was_c.511c677d")
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
            .navigationTitle(L10n.text("apple.clientpaywallview.plans.dfe8b2f0"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done")) { dismiss() }
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
            Text(isPaddle ? L10n.text("apple.clientpaywallview.website_subscription.37c4d8a0") : L10n.text("apple.clientpaywallview.plan.fa8ed0bd"))
                .font(ClientType.sectionTitle)
            Text(isPaddle
                 ? L10n.text("apple.clientpaywallview.you_subscribed_on_the_website_manage_that.1604fdbb")
                 : L10n.text("apple.clientpaywallview.this_plan_is_not_an_app_store_purchase_man.20f36b31"))
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
            ?? ClientStoreProduct.from(
                tier: signed?.billing?.scheduledTier,
                interval: ClientStoreProduct.interval(from: signed?.billing?.scheduledInterval)
            )
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: bill == .year ? L10n.text("apple.clientpaywallview.yearly_plans.e8f5b2a7") : L10n.text("apple.clientpaywallview.monthly_plans.f804dd95"), mark: "mark_plan")
            Text(L10n.text("apple.clientpaywallview.the_app_stays_free_a_plan_unlocks_more_dev.6c61f921"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            intervalSwitch
            if bill == .year {
                Text(L10n.text("apple.clientpaywallview.two_months_free_versus_monthly.4c985981"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("apple.clientpaywallview.supporter_is_yearly_only.927c1185"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(ClientStoreProduct.catalog(interval: bill)) { item in
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
        // Two separate gates, and both have to hold. `trialUsed` is the
        // account's, `isIntroEligible` is the Apple ID's: one person can be new
        // here and have spent the group's offer under a previous account, and
        // promising them three free days puts the full price in Apple's sheet.
        let showTrial = item == .patron && item.interval == .year && current == nil
            && !trialUsed && intro != nil && store.isIntroEligible
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
                        Text(L10n.text("apple.clientpaywallview.your_current_plan.2653f9e7"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    } else if isQueued {
                        Text(L10n.text("apple.clientpaywallview.switches_next_renewal.e700c0d8"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 0)
                if let product {
                    Text(product.displayPrice + (item.interval == .month ? L10n.text("apple.clientpaywallview.month.38428048") : L10n.text("apple.clientpaywallview.year.af0dde2c")))
                        .font(ClientType.label.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.products.isEmpty ? L10n.text("apple.clientpaywallview.loading_price.50992858") : L10n.text("apple.clientpaywallview.price_unavailable.6a9e657b"))
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
            if let caption = relayCaption(for: item) {
                Text(caption)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showTrial {
                Text(L10n.text("apple.clientpaywallview.3_days_free_then_the_yearly_price_once_per.6b22ed3a"))
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
            // Only when StoreKit has actually answered. `willAutoRenew` is
            // false both for "renewal is off" and for "nobody has said", and
            // an offline open must not present the second as the first.
            if isCurrent, store.renewalStatusKnown, !store.willAutoRenew {
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
        let change = store.planChange(from: current, to: item)
        if current == item {
            actionButton(L10n.text("apple.clientpaywallview.your_current_plan.2653f9e7"), .currentPlan, accent: false, busy: false, enabled: false) {}
            actionButton(L10n.text("apple.clientpaywallview.manage_on_the_app_store.7a235c13"), .appStore, accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
            actionButton(L10n.text("apple.clientpaywallview.turn_off_auto_renew.be139632"), .cancelPlan, accent: false, busy: false, enabled: true) {
                store.showManageSheet = true
            }
        } else if current == nil {
            actionButton(
                showTrial ? L10n.text("apple.clientpaywallview.start_3_day_trial.bb80ecdc") : L10n.text("apple.clientpaywallview.get_0.2db432a7", "\(item.title)"),
                .billing,
                accent: true,
                busy: busy,
                enabled: product != nil && account != nil && !store.isBusy
            ) {
                guard let product, let account else { return }
                Task { await store.purchase(product, account: account) }
            }
        } else if queued == item {
            actionButton(L10n.text("apple.clientpaywallview.switches_next_renewal.e700c0d8"), .scheduled, accent: false, busy: false, enabled: false) {}
            // Only when the plan being kept is known. `current ?? item` fell
            // back to the queued product itself when the store could not name
            // the current one, which made "keep this plan" buy the switch the
            // card said would wait.
            if let current, let keep = store.product(for: current) {
                actionButton(
                    L10n.text("apple.clientpaywallview.keep_0.82638326", "\(current.title)"),
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
            // What the button says is what the App Store will do, because both
            // read the same group order. Guessing it from the tier ladder
            // promised "next renewal" for a switch Apple charges on the spot.
            let climb = current.map { item.rank > $0.rank } ?? false
            let now = change == .immediate
            actionButton(
                now ? (climb ? L10n.text("apple.clientpaywallview.upgrade_to_0.db452b51", "\(item.title)") : L10n.text("apple.clientpaywallview.switch_to_0_now.9760382d", "\(item.title)"))
                    : L10n.text("apple.clientpaywallview.switch_at_next_renewal.75e7e87b"),
                now ? .plans : .scheduled,
                accent: now && climb,
                busy: busy,
                enabled: product != nil && !store.isBusy
            ) {
                guard let product, let account else { return }
                Task { await store.purchase(product, account: account) }
            }
            if now {
                Text(L10n.text("apple.clientpaywallview.charged_today_apple_refunds_the_time_you_h.05b565ee"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        ComparePlan(tier: "free", title: L10n.text("apple.clientpaywallview.free.f411a1fb")),
        ComparePlan(tier: "supporter", title: L10n.text("apple.clientpaywallview.supporter.2ce6c010")),
        ComparePlan(tier: "patron", title: L10n.text("apple.clientpaywallview.patron.dbcd07c6")),
        ComparePlan(tier: "legend", title: L10n.text("apple.clientpaywallview.legend.7482e374")),
    ]

    private struct CompareFeature: Identifiable {
        let label: String
        let values: [String]
        var id: String { label }
    }

    private static let compareFeatures: [CompareFeature] = [
        CompareFeature(label: L10n.text("common.devices"), values: ["2", "4", "6", "10"]),
        CompareFeature(label: L10n.text("common.history"), values: ["30 days", "1 yr", L10n.text("apple.clientpaywallview.all.a52ace42"), L10n.text("apple.clientpaywallview.all.a52ace42")]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.terminal_ssh.501f07aa"), values: [L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes"), L10n.text("common.yes")]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.view_screen.56dea3b5"), values: [L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes")]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.relay_traffic.250c5414"), values: [L10n.text("apple.clientpaywallview.100_mib.98243968"), L10n.text("apple.clientpaywallview.1_gib.7dd46450"), L10n.text("apple.clientpaywallview.5_gib.aa5f04aa"), L10n.text("apple.clientpaywallview.20_gib.4488c54a")]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.sync.8d261a37"), values: [L10n.text("apple.clientpaywallview.hourly.eab0cd8f"), "30 min", "10 min", "5 min"]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.mark.d7cda0ca"), values: [L10n.text("apple.clientpaywallview.none.dc937b59"), L10n.text("apple.clientpaywallview.star.e357d396"), L10n.text("apple.clientpaywallview.badge.002474e3"), L10n.text("apple.clientpaywallview.crown.29968c38")]),
        CompareFeature(label: L10n.text("apple.clientpaywallview.read_api.178531ea"), values: [L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.no"), L10n.text("common.yes")]),
    ]

    private var compare: some View {
        DisclosureGroup {
            compareGrid
                .padding(.top, Theme.Space.s)
        } label: {
            Text(L10n.text("apple.clientpaywallview.compare_plans.30d9abfd"))
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
                Text(L10n.text("apple.clientpaywallview.your_plan.d9ab76c6"))
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
                    .accessibilityLabel(L10n.text("common.yes"))
            } else if value == "No" {
                Image(systemName: "xmark")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .accessibilityLabel(L10n.text("common.no"))
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

    /// Direct connections do not count. These numbers are the hosted relay
    /// only, the same ladder the host already uses: try a local address,
    /// then fall back to the tunnel.
    private func relayCaption(for item: ClientStoreProduct) -> String? {
        switch item.tier {
        case "supporter":
            return L10n.text("apple.clientpaywallview.connections_try_a_direct_path_first_relaye.06561ccb")
        case "patron":
            return L10n.text("apple.clientpaywallview.connections_try_a_direct_path_first_relaye.144646ae")
        case "legend":
            return L10n.text("apple.clientpaywallview.connections_try_a_direct_path_first_relaye.fa4da6d5")
        default:
            return nil
        }
    }

    private func renewalOffCaption(account: Account?, item: ClientStoreProduct) -> String {
        if let end = store.expirationDate {
            let text = end.formatted(date: .abbreviated, time: .omitted)
            return L10n.text("apple.clientpaywallview.renewal_is_off_you_keep_0_until_1.1a7747ba", "\(item.title)", "\(text)")
        }
        if let raw = account?.billing?.periodEnd, let parsed = ISO8601DateFormatter().date(from: raw) {
            let text = parsed.formatted(date: .abbreviated, time: .omitted)
            return L10n.text("apple.clientpaywallview.renewal_is_off_you_keep_0_until_1.1a7747ba", "\(item.title)", "\(text)")
        }
        return L10n.text("apple.clientpaywallview.renewal_is_off_you_keep_0_until_the_period.544d96a4", "\(item.title)")
    }

    private var intervalSwitch: some View {
        HStack(spacing: 0) {
            intervalOption(L10n.text("apple.clientpaywallview.yearly.6e69b59e"), .year)
            intervalOption(L10n.text("apple.clientpaywallview.monthly.9b11f6b7"), .month)
        }
        .padding(4)
        .background(Theme.accentSoft, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.clientpaywallview.billing_period.a4a987fb"))
    }

    private func intervalOption(_ title: String, _ value: ClientStoreInterval) -> some View {
        Button {
            bill = value
        } label: {
            Text(title)
                .font(ClientType.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .foregroundStyle(bill == value ? Color.white : Theme.accent)
                .background(
                    bill == value ? Theme.accent : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(bill == value ? .isSelected : [])
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
                    ActionIcon.restore.label(L10n.text("apple.clientpaywallview.restore_purchases.c6399925"))
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
            Button(L10n.text("apple.clientpaywallview.privacy.54a57c31"), .external) { webURL = ClientWebPages.privacy() }
            Button(L10n.text("apple.clientpaywallview.terms.ede54899"), .external) { webURL = ClientWebPages.terms() }
        }
        .font(ClientType.caption.weight(.semibold))
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
    }

    private var renewNote: some View {
        Text(L10n.text("apple.clientpaywallview.plans_renew_automatically_unless_you_turn.45d3025b"))
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
