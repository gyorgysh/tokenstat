// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

// The client is iOS and iPadOS only. The Mac has `RootView`, and these
// screens lean on toolbar placements and a tab bar that macOS does not
// have, so compiling them there would only break the desktop build.
#if !os(macOS)

/// The account, as a sheet over whatever screen the avatar was tapped on.
///
/// A sheet rather than a tab: signing in, checking a tier and signing out are
/// things people do rarely and then leave, which is exactly the shape a sheet
/// has and exactly the shape a tab does not. It also keeps the fourth tab for a
/// screen someone opens the app to see.
///
/// The content is phone-native, not a port of the Mac Account pane. Fixed 13pt
/// card chrome and a plain system "Sign out" looked like a desktop window
/// squeezed onto a phone; this layout uses the client type scale and full-width
/// actions that match the rest of the app.
struct ClientAccountSheet: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ClientAccountContent()
                .navigationTitle(L10n.text("common.account"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.text("common.done")) { dismiss() }
                    }
                }
        }
        // Sign-out swaps the root to the login door. Leave the sheet with it,
        // or the person stays looking at Account while the app under it has
        // already moved on.
        .onChange(of: account.signedIn) { _, signedIn in
            if !signedIn { dismiss() }
        }
    }
}

/// Phone-sized account settings, split the same way the Mac pane is: who
/// you are, what this device keeps, and the legal end.
///
/// Not private: search names these panes so it can send somebody to a setting
/// by name rather than to the sheet's front page. See `ClientAppPlaces`.
enum ClientAccountPane: String, CaseIterable, Hashable {
    case account
    case thisDevice
    case legal

    var label: String {
        switch self {
        case .account: return L10n.text("common.account")
        case .thisDevice: return L10n.text("apple.clientaccountsheet.this_device.d052579c")
        case .legal: return L10n.text("apple.clientaccountsheet.legal.4787eaf7")
        }
    }
}

/// Phone-sized account settings: identity, plan, devices, sign out, legal.
private struct ClientAccountContent: View {
    @Environment(AccountModel.self) private var model
    @Environment(ClientTabCustomization.self) private var tabCustomization
    @Environment(ClientNavigationModel.self) private var navigation

    @State private var showSample = false
    @State private var showLicenses = false
    @State private var showPaywall = false
    @State private var showTabs = false
    @State private var showDeletionWeb = false
    @State private var deletionURL: URL?
    @State private var webURL: URL?
    @State private var confirmSignOut = false
    /// Read by `ClientRootView`, written here. See `ClientLayoutPreference`.
    @AppStorage("client.layoutMode") private var layoutPreference = ClientLayoutPreference.automatic.rawValue
    @AppStorage("client.accountPane") private var pane = ClientAccountPane.account

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(
                options: ClientAccountPane.allCases,
                selection: $pane
            ) { $0.label }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        Text(message)
                            .font(ClientType.body)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                            .cardSurface()
                    }

                    switch pane {
                    case .account:
                        accountPane
                    case .thisDevice:
                        thisDevicePane
                    case .legal:
                        legalPane
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.xl)
            }
            .id(pane)
        }
        .background(Theme.background)
        .sheet(isPresented: $showSample) { ClientSampleWorkspace() }
        .sheet(isPresented: $showTabs) { ClientTabEditor(customization: tabCustomization) }
        .sheet(isPresented: $showLicenses) {
            ClientLicensesSheet()
        }
        // The paywall presents over this sheet, not from the root. The root's
        // `showPaywall` sheet is another sheet on the same view that presents
        // the account sheet, and SwiftUI queues two sheets on one view instead
        // of stacking them: "See plans" only appeared once the account sheet
        // closed, with a long pause. A sheet on this sheet stacks on top.
        .sheet(isPresented: $showPaywall) {
            ClientPaywallView()
        }
        .sheet(isPresented: $showDeletionWeb) {
            ClientWebBrowser(url: deletionURL ?? Self.defaultDeletionURL)
        }
        // Deletion happens on the website, which the browser cannot report on.
        // When the sheet closes, ask the account again: a gone account answers
        // signed-out, which drops the session and tells the login door why.
        .onChange(of: showDeletionWeb) { _, shown in
            if !shown {
                Task { await model.checkAfterAccountDeletion() }
            }
        }
        .sheet(isPresented: Binding(
            get: { webURL != nil },
            set: { if !$0 { webURL = nil } }
        )) {
            if let webURL {
                ClientWebBrowser(url: webURL)
            }
        }
        .task {
            if model.account == nil { await model.load() }
        }
        // Search sent somebody to a setting by name. Land on its pane, and
        // open the screen it lives on when it is one screen deeper.
        .onChange(of: navigation.accountRequest, initial: true) { _, request in
            guard let request else { return }
            navigation.accountRequest = nil
            pane = request.pane
            switch request.detail {
            case .tabs: showTabs = true
            case .plans: showPaywall = true
            case .sample: showSample = true
            case .licenses: showLicenses = true
            case nil: break
            }
        }
    }

    @ViewBuilder
    private var accountPane: some View {
        if model.signedIn, let account = model.account {
            identity(account)
            planCard(account)
            RelayUsageCard(usage: account.relayUsage) { await model.load() }
            lastSync(account)
            devices(account)
            signOutButton
        } else if model.account != nil {
            signedOut
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(Theme.Space.xl)
        }
        dangerZone
    }

    private var sampleHelp: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("common.help")).font(ClientType.sectionTitle)
            Button { showSample = true } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: ActionIcon.run.symbol).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(L10n.text("apple.clientaccountsheet.see_a_sample.ae8b0f8d")).font(ClientType.label.weight(.semibold))
                        Text(L10n.text("apple.clientaccountsheet.explore_a_project_with_invented_data_right.968c6aff"))
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.sample")
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    /// Ending the account, kept apart from everything above it.
    ///
    /// Deletion used to sit under Legal, between the terms links and the third
    /// party notices, because having it in the app at all is a store
    /// requirement. That put the most destructive thing here can start in the
    /// one tab nobody opens to change a setting. It is not a document. It ends
    /// the account, so it lives at the end of the account, behind a rule that
    /// says the rest of the pane has finished.
    ///
    /// It stays visible when signed out: the website's flow signs the person in
    /// first, and a delete that is only reachable from one state is a delete
    /// somebody cannot find.
    @ViewBuilder
    private var dangerZone: some View {
        ThemeRule()
            .padding(.top, Theme.Space.m)
        Text(L10n.text("apple.clientaccountsheet.danger_zone.fd8b8dae"))
            .font(ClientType.caption.weight(.semibold))
            .foregroundStyle(Theme.danger)
            .tracking(0.7)
            .padding(.leading, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
        deleteAccountCard
    }

    /// Notifications first. That switch is why most people open this pane,
    /// and it used to sit under the cache, below the fold on a phone.
    @ViewBuilder
    private var thisDevicePane: some View {
        notificationsCard
        tabsCard
        LocalTrafficCard(traffic: model.remoteStatus?.traffic) {
            await model.loadTraffic()
        }
        LaunchSettings()
        ChatCacheSettings()
        SavedWorkSettings()
        layoutCard
    }

    /// This device's tab bar and sidebar, arranged by the person holding it.
    /// Tabs are device furniture like the layout above: an iPad with a
    /// keyboard lives in different tabs than a phone in hand, and neither
    /// arrangement follows the account.
    private var tabsCard: some View {
        Button { showTabs = true } label: {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.tabs.8e5ea509"), mark: "mark_device")
                    Text(tabSummary)
                        .font(ClientType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityLabel(L10n.text("apple.clientaccountsheet.arrange_tabs.c6454b2e"))
        .accessibilityValue(tabSummary)
    }

    private var tabSummary: String {
        let visible = tabCustomization.visibleTabs
        switch visible.count {
        case 0: return L10n.text("common.home")
        case 1...3: return visible.map(\.label).joined(separator: ", ")
        default:
            let rest = visible.count - 2
            return visible.prefix(2).map(\.label).joined(separator: ", ")
                + L10n.text("apple.clientaccountsheet.and_0_more.5a1fce7b", "\(rest)")
        }
    }

    @ViewBuilder
    private var legalPane: some View {
        sampleHelp
        legalCard
        licensesCard
        privacyNote
    }

    private func identity(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Avatar(url: account.avatar, name: account.title, handle: account.handle, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Text(account.title ?? L10n.text("apple.clientaccountsheet.signed_in.ca566c89"))
                            .font(ClientType.screenTitle)
                            .lineLimit(2)
                        if let tier = account.tier, !tier.isEmpty {
                            TierMark(tier: tier, size: 18)
                        }
                    }
                    if let handle = account.handle {
                        Text("@\(handle)")
                            .font(ClientType.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let tier = account.tier, !tier.isEmpty {
                        Text(tier.capitalized + L10n.text("apple.clientaccountsheet.plan.56aeaecb"))
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let handle = account.handle {
                Button {
                    webURL = ClientWebPages.publicProfile(host: account.host, handle: handle)
                } label: {
                    ActionIcon.external.label(L10n.text("apple.clientaccountsheet.view_public_profile.9acb2dbb"))
                        .font(ClientType.label.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func planCard(_ account: Account) -> some View {
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if let tier = account.tier, !tier.isEmpty {
                    TierMark(tier: tier, size: 22)
                } else {
                    FeatureMark(name: "mark_plan", tint: Theme.accent, size: 22)
                }
                Text(L10n.text("apple.clientaccountsheet.plan.fa8ed0bd"))
                    .font(ClientType.sectionTitle)
            }
            if let tier = account.tier, !tier.isEmpty {
                let period = account.billing?.interval == "month" ? " monthly"
                    : account.isPaidTier ? " yearly" : ""
                Text(tier.capitalized + period
                    + (account.billing?.periodEnd.map { L10n.text("apple.clientaccountsheet.until_0.f33ca039", "\(Self.shortDay($0))") } ?? ""))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
            }
            if account.isAppleBilled {
                Text(L10n.text("apple.clientaccountsheet.bought_on_the_app_store_see_every_plan_her.44164b98"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = account.billing?.scheduledTier, !next.isEmpty {
                    let nextPeriod = account.billing?.scheduledInterval == "month" ? " monthly"
                        : " yearly"
                    Text(L10n.text("apple.clientaccountsheet.switches_to_0_1_at_the_next_renewal.ebb7b074", "\(next.capitalized)", "\(nextPeriod)"))
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button {
                    showPaywall = true
                } label: {
                    ActionIcon.plans.label(L10n.text("apple.clientaccountsheet.see_plans.d9898933"))
                        .labelStyle(ActionLabelStyle())
                        .font(ClientType.label.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if account.isPaddleBilled {
                Text(L10n.text("apple.clientaccountsheet.you_subscribed_on_the_website_manage_that.e063184d"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.isWebManagedPlan {
                Text(L10n.text("apple.clientaccountsheet.this_plan_is_not_an_app_store_purchase_man.20f36b31"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("apple.clientaccountsheet.the_app_stays_free_a_yearly_plan_unlocks_m.1b526c33"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showPaywall = true
                } label: {
                    ActionIcon.plans.label(L10n.text("apple.clientaccountsheet.see_plans.d9898933"))
                        .labelStyle(ActionLabelStyle())
                        .font(ClientType.label.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Which shape the client draws itself in, on an iPad.
    ///
    /// Automatic is the answer for almost everybody and it is what the app
    /// ships with. The card exists for the two cases a heuristic cannot see:
    /// a keyboard used only for typing, and a person who prefers one shape.
    /// It is absent on iPhone, where there is only ever one shape.
    @ViewBuilder
    private var layoutCard: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.layout.a5119091"), mark: "mark_device")
                SegmentedTabs(
                    options: ClientLayoutPreference.allCases.map(\.rawValue),
                    selection: $layoutPreference
                ) { ClientLayoutPreference(rawValue: $0)?.label ?? $0 }
                Text(
                    (ClientLayoutPreference(rawValue: layoutPreference) ?? .automatic).detail
                )
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private func lastSync(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.last_sync.71967fca"), mark: "mark_sync")
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(L10n.text("apple.clientaccountsheet.from_any_device.e91c4f05"))
                    .foregroundStyle(.secondary)
                Text(formatRelativeDate(account.lastSyncAt) ?? L10n.text("common.never"))
                    .monospacedDigit()
            }
            .font(ClientType.label)
            Text(L10n.text("apple.clientaccountsheet.this_device_reads_that_data_it_does_not_up.a22bca17"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func devices(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("common.devices"), mark: "mark_device")
            Text(
                account.machines.isEmpty
                    ? L10n.text("apple.clientaccountsheet.none_linked_yet_install_tokenstat_on_a_com.8fcd63a6")
                    : L10n.text("apple.clientaccountsheet.0_linked_to_this_account.323c9727", "\(account.machines.count)")
            )
            .font(ClientType.body)
            .foregroundStyle(.secondary)

            if !account.machines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(account.machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 {
                            ThemeRule().padding(.vertical, Theme.Space.s)
                        }
                        deviceRow(machine, isThis: machine.machineID == account.thisMachineID)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func deviceRow(_ machine: Machine, isThis: Bool) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: ClientDeviceIcon.symbol(for: machine))
                .font(Theme.body)
                .foregroundStyle(isThis ? Theme.accent : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(deviceName(machine))
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isThis {
                        Text(L10n.text("apple.clientaccountsheet.this_device.cf3cc23e"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if machine.reportsArchiveSync {
                    Text(formatRelativeDate(machine.lastSyncAt) ?? L10n.text("apple.clientaccountsheet.never_synced.ee394cab"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                    Text(L10n.text("apple.clientaccountsheet.last_used_0.acf5f8f5", "\(seen)"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func deviceName(_ machine: Machine) -> String {
        if let label = machine.label, !label.isEmpty { return label }
        if let id = machine.machineID {
            guard id.count > 12 else { return id }
            return "\(id.prefix(6))…\(id.suffix(4))"
        }
        return machine.displayName
    }

    private var signOutButton: some View {
        Button {
            confirmSignOut = true
        } label: {
            Group {
                if model.isSigningOut {
                    ProgressView()
                        .tint(Theme.danger)
                } else {
                    ActionIcon.signOut.label(L10n.text("common.sign_out"))
                        .labelStyle(ActionLabelStyle())
                        .font(ClientType.label.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.danger.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isSyncing || model.isSigningOut)
        .accessibilityHint(L10n.text("apple.clientaccountsheet.signs_out_of_this_device_and_ends_the_onli.521a544a"))
        .sheet(isPresented: $confirmSignOut) { WorkSignOutReview(model: model) }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.not_signed_in.491fc91c"), mark: "mark_account")
            Text(L10n.text("apple.clientaccountsheet.signing_in_lets_this_device_read_usage_fro.7011d5ec"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            Button {
                model.signIn()
            } label: {
                ActionIcon.signIn.label(L10n.text("common.sign_in"))
                    .labelStyle(ActionLabelStyle())
                    .font(ClientType.label.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .clientProminentStyle()
            .controlSize(.large)
            .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Terms and privacy, reachable from inside the app.
    ///
    /// Required rather than decorative: App Review expects an app that creates
    /// accounts to link its privacy policy, and one that sells anything to link
    /// its terms, from somewhere in the app and not only from the store page.
    /// They open in the browser because they are the same documents the website
    /// serves, and a copy in the bundle is a copy that goes stale.
    private var legalCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.terms_and_privacy.8d60f3a9"), mark: "mark_license")
            legalLink(L10n.text("apple.clientaccountsheet.privacy_policy.ba445cff"), url: ClientWebPages.privacy())
            ThemeRule()
            legalLink(L10n.text("apple.clientaccountsheet.terms_of_service.e69e0614"), url: ClientWebPages.terms())
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder
    private func legalLink(_ title: String, url: URL) -> some View {
        Button {
            webURL = url
        } label: {
            HStack {
                Text(title)
                    .font(ClientType.label)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Notifications for this phone or iPad.
    ///
    /// Work finishes on a Mac. With this app closed there is nothing here to
    /// notice it, so the account asks Apple to wake the device. That is the
    /// whole reason this needs an account when the Mac's own version does not.
    ///
    /// What arrives is composed on the server from a fixed list of reasons and
    /// the machine's own label. No folder name, no prompt, no path is eligible,
    /// which is the same boundary sync keeps.
    private var notificationsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.notifications.78801183"), mark: "mark_device")
            Toggle(isOn: Binding(
                get: { PushRegistrar.shared.isOn },
                set: { on in
                    Task {
                        if on {
                            await PushRegistrar.shared.enable()
                        } else {
                            await PushRegistrar.shared.disable()
                        }
                    }
                }
            )) {
                Text(L10n.text("apple.clientaccountsheet.notify_this_device.961006a8"))
                    .font(ClientType.label)
            }
            .tint(Theme.accent)
            .disabled(!model.signedIn || PushRegistrar.shared.isWorking)
            Text(model.signedIn
                ? L10n.text("apple.clientaccountsheet.when_an_agent_run_or_a_chat_on_one_of_your.61c29a32")
                : L10n.text("apple.clientaccountsheet.sign_in_first_a_notification_has_to_reach.c1314d42"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = PushRegistrar.shared.errorMessage {
                Text(message)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if PushRegistrar.shared.isOn {
                Button(L10n.text("apple.clientaccountsheet.send_a_test.edc01436"), .preview) {
                    Task { await PushRegistrar.shared.sendTest() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .font(ClientType.label)
                .disabled(PushRegistrar.shared.isWorking)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var licensesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.open_source_licenses.1a1b83db"), mark: "mark_license")
            Text(L10n.text("apple.clientaccountsheet.third_party_notices_for_the_libraries_bund.6e6b4668"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            Button {
                showLicenses = true
            } label: {
                ActionIcon.docs.label(L10n.text("apple.clientaccountsheet.view_licenses.84534935"))
                    .labelStyle(ActionLabelStyle())
                    .font(ClientType.label.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var deleteAccountCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.delete_this_account.5e78b966"), mark: "mark_delete", tint: Theme.danger)
            Text(
                model.account?.billing?.isApple == true
                    && model.account?.billing?.blocksOtherStore == true
                    ? L10n.text("apple.clientaccountsheet.permanent_you_can_delete_immediately_on_th.26177f28")
                    : L10n.text("apple.clientaccountsheet.permanent_confirmed_on_the_website_s_data.fd5ff108")
            )
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openAccountDeletion()
            } label: {
                ActionIcon.delete.label(L10n.text("apple.clientaccountsheet.delete_on_website.22e9668a"))
                    .font(ClientType.label.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.danger)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.danger.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.danger.opacity(0.22), lineWidth: 1)
            )
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var privacyNote: some View {
        // Client Legal, not a host's sync screen. This phone does not upload
        // an archive; the boundary is what the computers put on the account
        // and what a remote session carries. Same card chrome as Licenses.
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.clientaccountsheet.sync_privacy.9f408670"), mark: "mark_sync")
            Text(L10n.text("apple.clientaccountsheet.your_computers_put_aggregate_counts_on_the.4e5bcb48"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                privacyLine(
                    title: L10n.text("apple.clientaccountsheet.on_account.b7b9c2b1"),
                    detail: L10n.text("apple.clientaccountsheet.counts_per_day_tool_and_model_project_name.49914859")
                )
                privacyLine(
                    title: L10n.text("apple.clientaccountsheet.not_synced.87cde3ef"),
                    detail: L10n.text("apple.clientaccountsheet.prompts_replies_file_contents_file_paths_a.22d61c00")
                )
                privacyLine(
                    title: L10n.text("apple.clientaccountsheet.remote.ffa98e02"),
                    detail: L10n.text("apple.clientaccountsheet.folders_terminals_and_agents_go_device_to.2cab47c4")
                )
            }
            .padding(.top, 2)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private func privacyLine(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text(title)
                .font(ClientType.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 78, alignment: .leading)
            Text(detail)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    private static var defaultDeletionURL: URL {
        ClientWebPages.accountDeletion()
    }

    private static func shortDay(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func openAccountDeletion() {
        let host = model.account?.host ?? ClientWebPages.host
        deletionURL = ClientWebPages.accountDeletion(host: host)
        showDeletionWeb = true
    }
}

/// Full-screen, lazy-scrolling third-party notices.
///
/// The Mac sheet used a fixed 620×520 frame and a single SwiftUI `Text` of a
/// half-megabyte file. On a phone that clipped the sheet, froze layout, and
/// looked broken. `UITextView` sizes lines lazily, which is the same fix the
/// Mac path already applied with `NSTextView`.
private struct ClientLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String?
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ClientNoticesTextView(text: text)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    ContentUnavailableView(
                        L10n.text("apple.clientaccountsheet.notices_missing.8fc6574b"),
                        systemImage: "doc.questionmark",
                        description: Text(L10n.text("apple.clientaccountsheet.the_third_party_notices_are_generated_at_b.4594fa7d"))
                    )
                } else {
                    ProgressView(L10n.text("apple.clientaccountsheet.loading_licenses.2de539a6"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle(L10n.text("apple.clientaccountsheet.open_source_licenses.1a1b83db"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            text = await Self.loadNotices()
            loadFailed = text == nil
        }
    }

    private static func loadNotices() async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }.value
    }
}

/// Lazy monospaced reader for the notices file.
private struct ClientNoticesTextView: UIViewRepresentable {
    let text: String
    /// Observed so a Dynamic Type change re-runs `updateUIView` and rescales
    /// the monospaced body. Trait collection alone does not always do that.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        view.textColor = .label
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        // Find is useful in a 500 KB notices file.
        view.isFindInteractionEnabled = true
        view.font = Self.scaledFont(for: view.traitCollection)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let _ = dynamicTypeSize
        let font = Self.scaledFont(for: view.traitCollection)
        if view.font != font {
            view.font = font
        }
        if view.text != text {
            view.text = text
        }
    }

    /// Monospaced body that follows Dynamic Type, not a fixed 13 pt.
    private static func scaledFont(for traits: UITraitCollection) -> UIFont {
        let base = AppFonts.terminal(size: 13)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
    }
}

#endif
