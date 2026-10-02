// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Account is three jobs, not one scrolling pile: who you are, vendor quota
/// windows, and what this Mac itself does.
#if os(macOS)
private enum AccountSettingsPane: String, CaseIterable, Hashable {
    case account
    case planLimits
    case thisMac

    var label: String {
        switch self {
        case .account: return L10n.text("common.account")
        case .planLimits: return L10n.text("apple.accountview.plan_limits.925788cd")
        case .thisMac: return L10n.text("apple.accountview.this_mac.79a4aefc")
        }
    }

    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .planLimits: return "list.clipboard"
        case .thisMac: return "laptopcomputer"
        }
    }
}
#endif

struct AccountView: View {
    @Bindable var model: AccountModel
    @Environment(\.openURL) private var openURL
    /// Whether the third-party notices sheet is open.
    @State private var confirmSignOut = false
    @State private var showLicenses = false
    #if os(macOS)
    @AppStorage("account.settingsPane") private var pane = AccountSettingsPane.account
    #endif
    /// iOS only: the in-app browser that completes deletion on the website.
    @State private var showDeletionWeb = false
    @State private var deletionURL: URL?
    #if os(macOS)
    @State private var localModels = LocalModelsModel()
    @State private var forgeConnection: PullForgeConnection?
    @State private var forgeLogin: PullDeviceLogin?
    @State private var forgeError: String?
    @State private var forgeLoginError: String?
    @State private var forgeBusy = false
    @State private var forgeConnecting = false
    @State private var confirmingForgeSignOut = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            // Mac detail chrome only. The phone sheet already has a navigation
            // bar with Done, and Sync now is not offered there (no archive).
            #if os(macOS)
            DetailChromeBar {
                if model.signedIn {
                    ToolbarIconButton(
                        systemImage: "arrow.triangle.2.circlepath",
                        help: L10n.text("common.sync_now"),
                        isBusy: model.isSyncing,
                        isEnabled: !model.isSyncing && model.syncCooldownUntil == nil
                    ) {
                        Task {
                            LogoRefresh.began()
                            await model.sync()
                        }
                    }
                }
            }
            TabStrip(
                tabs: AccountSettingsPane.allCases.map { ($0, $0.label, $0.symbol) },
                selection: $pane
            )
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message)
                    }
                    #if os(macOS)
                    if let device = model.pendingLogin {
                        SignInCode(device: device) { model.cancelSignIn() }
                    }
                    paneBody
                    #else
                    if let device = model.pendingLogin {
                        SignInCode(device: device) { model.cancelSignIn() }
                    } else if model.signedIn, let account = model.account {
                        signedIn(account)
                    } else if model.account != nil {
                        signedOut
                    } else {
                        // Neither state is known yet. Showing "sign in" here would
                        // flash the wrong answer on every launch.
                        BusySpinner()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Space.l)
                    }
                    LaunchSettings()
                    ChatCacheSettings()
                    #if os(macOS)
                    ChatBrowserSettings()
                    #endif
                    SavedWorkSettings()
                    notificationsCard
                    licensesCard
                    deleteAccountCard
                    privacyNote
                    #endif
                }
                .padding(Theme.Space.m)
            }
            #if os(macOS)
            .id(pane)
            #endif
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("common.account"))
        .sheet(isPresented: $showLicenses) {
            LicensesSheet()
        }
        #if os(macOS)
        .sheet(isPresented: forgeLoginPresented) {
            forgeLoginSheet
        }
        #endif
        #if os(iOS)
        // App Store Guideline 5.1.1(v) wants deletion available inside the
        // app. The website's own data settings page in an in-app browser lets the
        // user start and finish it without leaving, and needs no backend
        // endpoint of our own. macOS opens the same page in the browser.
        .sheet(isPresented: $showDeletionWeb) {
            ClientWebBrowser(url: deletionURL ?? Self.defaultDeletionURL)
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            TransientToast(message: $model.syncNotice,
                           severity: model.isRateLimited
                               ? .warning
                               : (model.syncNoticeIsError ? .danger : .success),
                           onDismiss: { model.dismissSyncNotice() })
                .padding(Theme.Space.l)
        }
        .task {
            if model.account == nil { await model.load() }
            #if os(macOS)
            await loadForgeConnection()
            #endif
        }
    }

    private var signedOut: some View {
        Card(
            title: L10n.text("apple.accountview.not_signed_in.491fc91c"),
            subtitle: L10n.text("apple.accountview.everything_works_without_an_account_signin.77323e45"),
            mark: "mark_account"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.accountview.an_account_lets_you_publish_a_profile_page.d28d80da"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)

                Button(L10n.text("apple.accountview.sign_in_to_tokenstat_ai.6276dc4d"), .signIn) {
                    model.signIn()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func signedIn(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            identity(account)
            RelayUsageCard(usage: account.relayUsage) { await model.load() }
            syncCard(account)
            machinesCard(account)
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .account:
            accountPane
        case .planLimits:
            planLimitsPane
        case .thisMac:
            thisMacPane
        }
    }

    /// Who you are, who can reach you, and the legal end of the account.
    @ViewBuilder
    private var accountPane: some View {
        if model.pendingLogin == nil {
            if model.signedIn, let account = model.account {
                signedIn(account)
            } else if model.account != nil {
                signedOut
            } else {
                BusySpinner()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.l)
            }
        }
        forgeCard
        privacyNote
        licensesCard
        deleteAccountCard
    }

    @ViewBuilder
    private var planLimitsPane: some View {
        if model.signedIn {
            planLimitsCard
        } else if model.account != nil {
            Card(
                title: L10n.text("apple.accountview.plan_limits.925788cd"),
                subtitle: L10n.text("apple.accountview.sign_in_to_see_how_much_of_each_tool_s_sub.13fb7823"),
                mark: "mark_plan"
            ) {
                Button(L10n.text("apple.accountview.sign_in_to_tokenstat_ai.6276dc4d"), .signIn) {
                    model.signIn()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            BusySpinner()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
        }
    }

    /// Settings that live on this computer, signed in or not.
    @ViewBuilder
    private var thisMacPane: some View {
        hostCard
        LocalTrafficCard(traffic: model.remoteStatus?.traffic) {
            await model.loadTraffic()
        }
        notificationsCard
        LaunchSettings()
        ChatCacheSettings()
        #if os(macOS)
        ChatBrowserSettings()
        #endif
        SavedWorkSettings()
        terminalCard
        localModelsCard
    }
    #endif

    /// Who you are, at the size a profile deserves.
    ///
    /// This screen used to open with three `Stat` columns reading "Handle",
    /// "Plan", "Last sync", which is a report about an account rather than an
    /// account. The picture, the name and the tier belong together and belong
    /// first.
    private func identity(_ account: Account) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Avatar(url: account.avatar, name: account.title, handle: account.handle, size: 64)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(account.title ?? L10n.text("apple.accountview.signed_in.ca566c89"))
                        .font(Theme.font(22, weight: .semibold))
                    if let tier = account.tier, !tier.isEmpty {
                        TierMark(tier: tier, size: 17)
                    }
                }
                if let handle = account.handle {
                    Text("@\(handle)")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(account.host)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let handle = account.handle, let url = URL(string: "\(account.host)/\(handle)") {
                // The profile is a public page and this is the only place in
                // the app that knows its address.
                Link(destination: url) {
                    ActionIcon.external.label(L10n.text("apple.accountview.view_profile.d4788f25"))
                }
                .buttonStyle(.plain)
                .font(Theme.callout)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func syncCard(_ account: Account) -> some View {
        // **Sync is a desktop act.** It uploads this machine's archive. A phone
        // has no archive: it only reads what other devices published. Offering
        // Sync now there is a button whose honest outcome is a refusal.
        Card(
            title: L10n.text("apple.accountview.sync.8d261a37"),
            subtitle: L10n.text("apple.accountview.only_aggregate_counters_are_eligible.141802f7"),
            mark: "mark_sync"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(L10n.text("apple.accountview.last_sync.71967fca"))
                            .foregroundStyle(.secondary)
                        Text(formatRelativeDate(account.lastSyncAt) ?? L10n.text("common.never"))
                            .monospacedDigit()
                    }
                    .font(Theme.callout)
                    .help(formatServerDate(account.lastSyncAt) ?? L10n.text("apple.accountview.this_account_has_never_synced.cbcf0a75"))

                    #if os(macOS)
                    Button(model.isSyncing ? L10n.text("apple.accountview.syncing.8a046cc9") : L10n.text("common.sync_now"), .refresh) {
                        Task { await model.sync() }
                    }
                    .disabled(model.isSyncing || model.syncCooldownUntil != nil)
                    #endif
                }

                #if os(macOS)
                if model.syncCooldownUntil != nil {
                    Text(L10n.text("apple.accountview.syncing_again_is_available_shortly.9c4ed55f"))
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    confirmSignOut = true
                } label: {
                    if model.isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionIcon.signOut.label(L10n.text("common.sign_out"))
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isSyncing || model.isSigningOut)
                .sheet(isPresented: $confirmSignOut) { WorkSignOutReview(model: model) }
                #else
                // Phone account UI lives in `ClientAccountSheet`. Keep a
                // non-system control here if this view is ever shown on iOS.
                Button {
                    Task { await model.signOut() }
                } label: {
                    if model.isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionIcon.signOut.label(L10n.text("common.sign_out"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isSyncing || model.isSigningOut)
                #endif
            }
        }
    }

    private func machinesCard(_ account: Account) -> some View {
        let used = account.machines.count
        let limit = account.machineLimit
        let subtitle: String = {
            if account.machines.isEmpty {
                return L10n.text("apple.accountview.every_device_that_has_synced_to_this_accou.cdc060e6")
            }
            if let limit {
                return L10n.text("apple.accountview.0_of_1_devices_2.6a9bb1c9", "\(used)", "\(limit)", "\((account.canRemote == false ? L10n.text("apple.accountview.no_remote_control_on_this_plan.278f9ff0") : ""))")
            }
            return L10n.text("apple.accountview.0_linked.6897cc07", "\(account.machines.count)")
        }()
        return Card(title: L10n.text("common.devices"), subtitle: subtitle, mark: "mark_device") {
            if account.machines.isEmpty {
                #if os(macOS)
                EmptyState(
                    symbol: "laptopcomputer.and.iphone",
                    title: L10n.text("apple.accountview.nothing_linked_yet.2e60783b"),
                    message: L10n.text("apple.accountview.free_includes_two_devices_sync_now_to_put.9752d041")
                )
                #else
                EmptyState(
                    symbol: "laptopcomputer.and.iphone",
                    title: L10n.text("apple.accountview.no_devices_yet.a149f2bd"),
                    message: L10n.text("apple.accountview.install_tokenstat_on_a_computer_and_sign_i.5852db8a")
                )
                #endif
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(account.machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 {
                            ThemeRule().padding(.vertical, Theme.Space.xs)
                        }
                        machineRow(machine, isThisMachine: machine.machineID == account.thisMachineID)
                    }
                }
            }
        }
    }

    /// One machine. The one you are sitting at is marked.
    ///
    /// Without the mark the list is a set of opaque ids, and the only machine
    /// anyone can actually act on is the one they cannot pick out.
    private func machineRow(_ machine: Machine, isThisMachine: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: machineIcon(machine, isThisMachine: isThisMachine))
                .foregroundStyle(isThisMachine ? Theme.accent : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    // A machine the user has never named shows its id. The id
                    // is a public machine key, so it is shown plain and
                    // selectable rather than blurred.
                    if let label = machine.label, !label.isEmpty {
                        Text(label)
                            .font(Theme.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let id = machine.machineID {
                        Text(id)
                            .font(Theme.mono(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text(machine.displayName)
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                    }
                    if isThisMachine {
                        Text(L10n.text("apple.accountview.this_mac.41bc3866"))
                            .font(Theme.font(9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                }
                // Only when the machine has a name, so the id is not printed
                // twice on a row that is already showing it as its title.
                if let subtitle = machine.subtitle {
                    Text(subtitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            if machine.reportsArchiveSync {
                Text(formatRelativeDate(machine.lastSyncAt) ?? L10n.text("apple.accountview.never_synced.ee394cab"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .help(formatServerDate(machine.lastSyncAt) ?? L10n.text("apple.accountview.never_synced.ee394cab"))
            } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                Text(L10n.text("apple.accountview.last_used_0.acf5f8f5", "\(seen)"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// The claim, stated where someone is deciding whether to connect an
    /// account. This is the moment it matters, not the marketing page.
    private var privacyNote: some View {
        Card(title: L10n.text("apple.accountview.what_syncing_sends.6540deb3"), subtitle: nil, mark: "mark_sync") {
            Text(L10n.text("apple.accountview.aggregate_counts_per_day_tool_and_model_an.4f196b00"))
            .font(Theme.caption)
            .foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
    /// Opt-in posting of vendor quota windows, one switch per reading we have.
    ///
    /// The master switch is still the privacy gate (off by default). Each
    /// row is a source the user can leave on this Mac, for an expired
    /// subscription or a tool they do not want on the phone.
    private var planLimitsCard: some View {
        Card(
            title: L10n.text("apple.accountview.plan_limits.925788cd"),
            subtitle: L10n.text("apple.accountview.how_much_of_each_tool_s_subscription_is_le.6ff3d4cb"),
            mark: "mark_plan"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                toggleRow(
                    L10n.text("apple.accountview.share_with_my_devices.44aa4fc8"),
                    detail: L10n.text("apple.accountview.shows_how_much_of_each_tool_s_subscription.0a16d097"),
                    isOn: Binding(
                        get: { model.limitsSyncEnabled },
                        set: { on in Task { await model.setLimitsSync(on) } }
                    )
                )
                if model.limitsProviders.isEmpty {
                    Text(model.isLoadingLimits
                         ? L10n.text("apple.accountview.looking_for_vendor_readings.09bcadbb")
                         : L10n.text("apple.accountview.no_readings_yet_open_home_or_wait_for_the.6d2835f0"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.limitsProviders.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 {
                                ThemeRule().padding(.vertical, Theme.Space.xs)
                            }
                            planLimitRow(provider)
                        }
                    }
                }
            }
        }
        .task { await model.loadLimitsIfNeeded() }
    }

    private func planLimitRow(_ provider: ProviderLimits) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            HarnessMark(id: provider.source, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(harnessName(provider.source))
                    .font(Theme.callout)
                Text(planLimitDetail(provider))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: Binding(
                get: { model.sharesLimits(of: provider.source) },
                set: { on in Task { await model.setLimitsSourceShared(provider.source, shared: on) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(L10n.text("apple.accountview.track_0.7cd9419b", "\(harnessName(provider.source))"))
            .fixedSize()
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func planLimitDetail(_ provider: ProviderLimits) -> String {
        var parts: [String] = []
        if let plan = provider.plan, !plan.isEmpty {
            parts.append(plan)
        }
        if provider.hasWindows {
            let windows = provider.windows
                .map { "\($0.label) \(Int($0.percent.rounded()))%" }
                .joined(separator: ", ")
            parts.append(windows)
        } else if let note = provider.note, !note.isEmpty {
            parts.append(note)
        }
        if provider.isStale {
            parts.append(L10n.text("apple.accountview.last_reading_is_old.d86fcd39"))
        }
        if parts.isEmpty {
            return L10n.text("apple.accountview.no_windows_reported.6e652c80")
        }
        return parts.joined(separator: " · ")
    }

    private var hostCard: some View {
        Card(
            title: L10n.text("apple.accountview.this_mac.79a4aefc"),
            subtitle: L10n.text("apple.accountview.whether_the_host_helper_stays_up_after_you.dd1619f2"),
            mark: "mark_host"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let policy = model.hostPolicy {
                    toggleRow(
                        L10n.text("apple.accountview.always_on_host.f7990642"),
                        detail: alwaysOnDetail(policy),
                        isOn: Binding(
                            get: { policy.alwaysOn },
                            set: { on in Task { await model.setAlwaysOnHost(on) } }
                        )
                    )
                    .disabled(model.isSavingHostPolicy)
                    if policy.alwaysOn && policy.hasInternalBattery {
                        Text(L10n.text("apple.accountview.uses_more_power.a24adb34"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !policy.alwaysOn {
                        Text(L10n.text("apple.accountview.automations_run_only_while_tokenstat_is_op.72980d54"))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text("apple.accountview.the_host_helper_has_not_answered_yet.ed11e9fb"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func alwaysOnDetail(_ policy: HostPolicy) -> String {
        if policy.alwaysOn {
            return L10n.text("apple.accountview.the_host_helper_keeps_running_after_you_qu.8da69cf5")
        }
        return L10n.text("apple.accountview.the_host_helper_stops_when_you_quit_tokens.3285420e")
    }
    #endif

    private var terminalCard: some View {
        Card(
            title: L10n.text("apple.accountview.terminal.e0926fda"),
            subtitle: L10n.text("apple.accountview.how_terminal_sessions_behave.66c55446"),
            mark: "mark_terminal"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // These describe terminals, and a client has none.
                #if os(macOS)
                toggleRow(
                    L10n.text("apple.accountview.expose_terminal_output_to_voiceover.a2c1bd2f"),
                    detail: L10n.text("apple.accountview.lets_voiceover_read_the_terminal_as_a_text.626da51c"),
                    isOn: Binding(
                        get: { TerminalPreferences.exposesToVoiceOver },
                        set: { TerminalPreferences.exposesToVoiceOver = $0 }
                    )
                )
                ThemeRule()
                toggleRow(
                    L10n.text("apple.accountview.disable_colours.856a1e98"),
                    detail: L10n.text("apple.accountview.new_terminals_start_with_no_color_for_apps.6b8caec0"),
                    isOn: Binding(
                        get: { TerminalPreferences.disablesColor },
                        set: { TerminalPreferences.disablesColor = $0 }
                    )
                )
                #endif
            }
        }
    }

    #if os(macOS)
    private var localModelsCard: some View {
        Card(
            title: L10n.text("apple.accountview.local_models.8e4bf436"),
            subtitle: L10n.text("apple.accountview.lm_studio_on_port_1234_ollama_on_port_1143.9fad3f80"),
            mark: "mark_local"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text(L10n.text("apple.accountview.nothing_is_sent_to_tokenstat_these_checks.0b0d8242"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await localModels.load() }
                    } label: {
                        if localModels.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("apple.accountview.check_lm_studio_and_ollama_again.abfeb0ad"))
                    .disabled(localModels.isLoading)
                }

                Text(L10n.text("common.local_provider_settings_help"))
                    .font(Theme.caption).foregroundStyle(.secondary)

                if let error = localModels.errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                } else if localModels.providers.isEmpty && !localModels.isLoading {
                    Text(L10n.text("apple.accountview.lm_studio_port_1234_and_ollama_port_11434.a765442f"))
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localModels.providers) { provider in
                        localProviderRow(provider)
                    }
                }
            }
        }
        .task {
            await localModels.load()
        }
    }

    private var forgeCard: some View {
        Card(
            title: L10n.text("apple.accountview.github_pull_requests.0973f247"),
            subtitle: L10n.text("apple.accountview.checked_only_when_you_open_pull_requests_o.6c9f4103"),
            mark: "mark_account"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let forgeError {
                    Text(FriendlyError.from(forgeError).message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning)
                }
                if let forgeConnection {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        ActionSeat(icon: .account, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(forgeConnection.login.map { "@\($0)" } ?? L10n.text("apple.accountview.not_connected.0303e182"))
                                .font(Theme.callout.weight(.semibold))
                            Text(forgeConnectionDetail(forgeConnection))
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text(forgeConnectionMessage(forgeConnection))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if forgeConnection.source != "tokenstat" {
                        Button {
                            Task { await beginForgeLogin() }
                        } label: {
                            ActionIcon.connect.label(
                                forgeConnecting ? L10n.text("apple.accountview.opening_github.efb4ce38") : L10n.text("apple.accountview.connect_tokenstat_github_app.f936ff5f")
                            )
                        }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(forgeConnecting || forgeBusy)
                    }
                    HStack(spacing: Theme.Space.s) {
                        if forgeConnection.source == "tokenstat" {
                            Button(L10n.text("apple.accountview.choose_repositories.df6de593"), .external) {
                                openURL(Self.githubInstallationURL)
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        Button(L10n.text("common.refresh"), .refresh) { Task { await loadForgeConnection() } }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                            .disabled(forgeBusy)
                        if canSignOutForge(forgeConnection) {
                            Button(L10n.text("common.sign_out"), .signOut) { confirmingForgeSignOut = true }
                                .buttonStyle(SecondaryButtonStyle(small: true))
                                .disabled(forgeBusy)
                        }
                    }
                } else if forgeError == nil {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("apple.accountview.checking_the_github_connection.4258cc8b"))
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.text("apple.accountview.sign_out_of_github_pull_requests.9aed016d"),
            isPresented: $confirmingForgeSignOut,
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.sign_out"), role: .destructive) { Task { await signOutForge() } }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.accountview.the_github_token_saved_by_tokenstat_will_b.182fb193"))
        }
    }

    private func loadForgeConnection() async {
        guard !forgeBusy else { return }
        forgeBusy = true
        forgeError = nil
        defer { forgeBusy = false }
        do {
            forgeConnection = try await Bridge.pullConnection()
        } catch {
            forgeError = error.localizedDescription
        }
    }

    private func signOutForge() async {
        guard let connection = forgeConnection else { return }
        forgeBusy = true
        forgeError = nil
        defer { forgeBusy = false }
        do {
            try await Bridge.signOutPulls(host: connection.host)
            forgeConnection = try await Bridge.pullConnection(host: connection.host)
        } catch {
            forgeError = error.localizedDescription
        }
    }

    private var forgeLoginPresented: Binding<Bool> {
        Binding(
            get: { forgeLogin != nil },
            set: { presented in
                if !presented { Task { await cancelForgeLogin() } }
            }
        )
    }

    @ViewBuilder
    private var forgeLoginSheet: some View {
        if let login = forgeLogin {
            ThemedSheet(
                title: L10n.text("apple.accountview.connect_tokenstat_github_app.f936ff5f"),
                subtitle: L10n.text("apple.accountview.enter_this_one_time_code_in_the_github_pag.2babe0df"),
                icon: .connect,
                onClose: { Task { await cancelForgeLogin() } }
            ) {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    Text(login.userCode)
                        .font(Theme.monoText(30, weight: .semibold, relativeTo: .title))
                        .tracking(2)
                        .foregroundStyle(Theme.accent)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.l)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cardRadius)
                                .strokeBorder(Theme.accent.opacity(0.3))
                        )
                    HStack(spacing: Theme.Space.s) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.accent)
                        Text(L10n.text("apple.accountview.waiting_for_github.d3f403f4"))
                            .font(Theme.callout)
                            .foregroundStyle(Theme.controlGlyph)
                    }
                    if let forgeLoginError {
                        Text(FriendlyError.from(forgeLoginError).message)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                Button(L10n.text("common.cancel"), .dismiss) { Task { await cancelForgeLogin() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .modalFrame(width: 540, height: 440)
            .task(id: login.userCode) { await pollForgeLogin() }
        }
    }

    private func beginForgeLogin() async {
        guard !forgeConnecting else { return }
        forgeConnecting = true
        forgeError = nil
        forgeLoginError = nil
        defer { forgeConnecting = false }
        do {
            let login = try await Bridge.startPullLogin()
            forgeLogin = login
            if let url = URL(string: login.openUrl) { openURL(url) }
        } catch {
            forgeError = error.localizedDescription
        }
    }

    private func pollForgeLogin() async {
        while let login = forgeLogin, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Double(max(login.interval, 1))))
                let result = try await Bridge.pollPullLogin()
                if result.state == "confirmed" {
                    forgeLogin = nil
                    forgeConnection = try await Bridge.pullConnection(host: login.host)
                    return
                }
                if let interval = result.interval {
                    forgeLogin?.interval = interval
                }
            } catch is CancellationError {
                return
            } catch {
                forgeLoginError = error.localizedDescription
                return
            }
        }
    }

    private func cancelForgeLogin() async {
        forgeLogin = nil
        forgeLoginError = nil
        await Bridge.cancelPullLogin()
    }

    private func canSignOutForge(_ connection: PullForgeConnection) -> Bool {
        connection.source == "tokenstat" || connection.source == "pasted"
    }

    private func forgeConnectionDetail(_ connection: PullForgeConnection) -> String {
        let source = switch connection.source {
        case "gitCredential": L10n.text("apple.accountview.using_the_credential_git_already_has.b61df8b4")
        case "environment": L10n.text("apple.accountview.using_gh_token_or_github_token_from_your_l.419f60ee")
        case "pasted": L10n.text("apple.accountview.using_a_token_saved_by_tokenstat.88f552ef")
        case "tokenstat": L10n.text("apple.accountview.connected_through_tokenstat.04f82237")
        default: L10n.text("apple.accountview.no_github_credential_found.cb62e9ec")
        }
        return "\(connection.host) · \(source)"
    }

    private func forgeConnectionMessage(_ connection: PullForgeConnection) -> String {
        switch connection.source {
        case "tokenstat":
            return L10n.text("apple.accountview.connected_with_the_tokenstat_github_app_pu.408c2b35")
        case "gitCredential", "environment":
            return L10n.text("apple.accountview.pull_requests_work_through_a_credential_ow.304f9738")
        case "pasted":
            return L10n.text("apple.accountview.a_token_saved_by_tokenstat_is_active_you_c.574bdb58")
        default:
            return L10n.text("apple.accountview.connect_the_tokenstat_github_app_then_choo.0a205707")
        }
    }

    private static let githubInstallationURL = URL(
        string: "https://github.com/apps/tokenstat/installations/new"
    )!

    private func localProviderRow(_ provider: LocalProvider) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(provider.available && localModels.isEnabled(provider.id) ? Theme.accent : Theme.border)
                    .frame(width: 8, height: 8)
                Text(provider.name)
                    .font(Theme.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { localModels.isEnabled(provider.id) },
                    set: { localModels.setEnabled($0, for: provider.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            LocalProviderPortEditor(provider: provider) { port in
                try await localModels.setPort(port, for: provider.id)
            }
            .disabled(localModels.isLoading)
            if !localModels.isEnabled(provider.id) {
                Text(L10n.text("apple.accountview.disabled_for_local_model_selection.8bd93638"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else if provider.available {
                if provider.models.isEmpty {
                    Text(provider.id == "lmstudio"
                         ? L10n.text("apple.accountview.server_is_up_load_a_model_in_lm_studio_to.45657b3c")
                         : L10n.text("apple.accountview.server_is_up_pull_or_run_a_model_in_ollama.d3666ac5"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(provider.models) { model in
                        HStack(spacing: Theme.Space.s) {
                            Text(model.name)
                                .font(Theme.mono(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let size = model.sizeDescription {
                                Text(size)
                                    .font(Theme.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Text(localProviderHint(provider))
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func localProviderHint(_ provider: LocalProvider) -> String {
        let raw = provider.error ?? L10n.text("apple.accountview.not_running.415ed734")
        if raw == "not running" || raw.hasPrefix("not running") {
            return provider.id == "lmstudio"
                ? L10n.text("apple.accountview.not_running_open_lm_studio_and_turn_on_the.d9dc45d4")
                : L10n.text("apple.accountview.not_running_start_ollama_port_11434.2f65e946")
        }
        return raw
    }
    #endif

    /// Show phones as phones, tablets as tablets, on both the desktop account
    /// card and the client. A host is a computer, with the current one using
    /// the laptop variant when the name does not already say what it is.
    private func machineIcon(_ machine: Machine, isThisMachine: Bool) -> String {
        if isThisMachine, machine.isHost {
            let guessed = ClientDeviceIcon.symbol(for: machine)
            if guessed == "desktopcomputer" { return "laptopcomputer" }
            return guessed
        }
        return ClientDeviceIcon.symbol(for: machine)
    }

    /// Being told when a run or chat needs attention.
    ///
    /// Two different mechanisms behind one switch, because they are one
    /// feature to the person using them. The Mac watches its own run list and
    /// posts the notification itself, with no account and no network. A phone
    /// with the app closed cannot watch anything, so it asks the account to
    /// have Apple wake it, which is why that side needs signing in and this
    /// one does not.
    private var notificationsCard: some View {
        Card(
            title: L10n.text("apple.accountview.notifications.78801183"),
            subtitle: L10n.text("apple.accountview.when_an_agent_run_or_a_chat_finishes_or_st.cc37c85b"),
            mark: "mark_device"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                #if os(macOS)
                toggleRow(
                    L10n.text("apple.accountview.tell_me_when_work_needs_attention.016eb3de"),
                    detail: L10n.text("apple.accountview.chats_automations_and_workflows_on_this_ma.a29d8d24"),
                    isOn: Binding(
                        get: { RunNotifications.shared.isOn },
                        set: { RunNotifications.shared.isOn = $0 }
                    )
                )
                if let note = RunNotifications.shared.authorizationNote {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning)
                }
                if RunNotifications.shared.isOn {
                    HStack {
                        Spacer()
                        Button(L10n.text("apple.accountview.send_a_test.edc01436"), .preview) { RunNotifications.shared.sendTest() }
                            .buttonStyle(AccentButtonStyle(small: true))
                    }
                }
                #else
                toggleRow(
                    L10n.text("apple.accountview.notify_this_device.961006a8"),
                    detail: L10n.text("apple.accountview.sent_through_apple_so_it_arrives_with_the.a5aaf308"),
                    isOn: Binding(
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
                    )
                )
                if let message = PushRegistrar.shared.errorMessage {
                    Text(message)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning)
                }
                if PushRegistrar.shared.isOn {
                    HStack {
                        Spacer()
                        Button(L10n.text("apple.accountview.send_a_test.edc01436"), .preview) {
                            Task { await PushRegistrar.shared.sendTest() }
                        }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(PushRegistrar.shared.isWorking)
                    }
                }
                #endif
            }
        }
        #if os(macOS)
        .task { await RunNotifications.shared.refreshAuthorization() }
        #endif
    }

    private var licensesCard: some View {
        Card(
            title: L10n.text("apple.accountview.open_source_licenses.1a1b83db"),
            subtitle: L10n.text("apple.accountview.third_party_notices_for_the_bundled_depend.d7c3ebf2"),
            mark: "mark_license"
        ) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(L10n.text("apple.accountview.tokenstat_links_open_source_libraries_each.3b43a49c"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("apple.accountview.view.dcc839a4"), .preview) { showLicenses = true }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help(L10n.text("apple.accountview.show_the_licence_and_notice_for_every_bund.0a70437c"))
            }
        }
    }

    /// Delete the account, from the website.
    ///
    /// The app deliberately has no delete of its own: deletion is immediate
    /// and permanent on the server, and the website's data settings is the
    /// only place that is confirmed. The button sends the user there, logged
    /// in or to log in first.
    private var deleteAccountCard: some View {
        Card(
            title: L10n.text("apple.accountview.delete_this_account.5e78b966"),
            subtitle: L10n.text("apple.accountview.permanent_confirmed_on_the_website_s_data.68431d9f"),
            mark: "mark_delete",
            markTint: Theme.danger
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.accountview.deleting_is_immediate_and_permanent_the_ac.1d0bba5c"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)

                Button {
                    openAccountDeletion()
                } label: {
                    ActionIcon.delete.label(L10n.text("apple.accountview.delete_on_website.22e9668a"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .help(L10n.text("apple.accountview.opens_the_data_settings_where_deletion_is.9e4c16d5"))
            }
        }
    }

    /// Where deletion happens: `{host}/settings/data#delete` on the website.
    /// The fragment jumps to the delete section once the page loads, so the
    /// button lands on the section instead of the top of the page.
    private static var defaultDeletionURL: URL {
        URL(string: "https://tokenstat.ai/settings/data#delete")!
    }

    private func openAccountDeletion() {
        let host = model.account?.host ?? "https://tokenstat.ai"
        #if os(macOS)
        guard let url = URL(string: "\(host)/settings/data#delete") else { return }
        openURL(url)
        #else
        // Same deep link as the phone account sheet, so both iOS entry points
        // land on the delete section with the site's focus hint.
        deletionURL = ClientWebPages.accountDeletion(host: host)
        showDeletionWeb = true
        #endif
    }

    /// Label on the left, the switch pinned to the row's trailing edge, so
    /// every switch in the list sits in the same column whatever the label
    /// length. The switch is the state; no redundant word beside it.
    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.callout)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
                .fixedSize()
        }
    }
}

/// The third-party notices sheet: every bundled dependency and its licence
/// text, in a monospaced reading pane that sizes lines lazily.
///
/// A single SwiftUI `Text` of this file freezes layout (half a megabyte). The
/// Mac path uses `NSTextView`; the iOS path is the phone-native sheet in
/// `ClientAccountSheet` and should not open this one.
private struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text: String?
    @State private var loadFailed = false

    var body: some View {
        ThemedSheet(
            title: L10n.text("apple.accountview.third_party_notices.8fadbc8d"),
            subtitle: L10n.text("apple.accountview.licences_for_the_software_bundled_with_tok.09bbae43"),
            icon: .docs,
            onClose: { dismiss() }
        ) {
            Group {
                if let text {
                    #if os(macOS)
                    NoticesTextPane(text: text)
                    #else
                    Text(L10n.text("apple.accountview.open_licenses_from_the_account_sheet.6396b141"))
                        .font(Theme.callout)
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                } else if loadFailed {
                    // A development build that ran without the generating
                    // build phase, or a bundle that lost the file.
                    Text(L10n.text("apple.accountview.the_third_party_notices_are_generated_at_b.4594fa7d"))
                        .font(Theme.callout)
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Theme.Space.s)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modalFrame(width: 640, height: 560)
        .task {
            text = await Self.loadNotices()
            loadFailed = text == nil
        }
    }

    /// Read the generated notices file away from the main thread. The read
    /// itself is small, but the file is assembled by a build phase and this
    /// keeps the first open instant regardless of its size.
    private static func loadNotices() async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        }.value
    }
}

#if os(macOS)
/// The notices sheet's text surface.
///
/// A single SwiftUI `Text` measuring 578 KB of notices on the main thread is
/// what froze the app on the first open: `Text` lays out the entire string
/// up front, so the sheet appeared seconds later and stayed blank while the
/// layout pass ground on. `NSTextView` sizes its lines lazily inside the
/// scroll view, so the same file appears immediately and scrolls smoothly.
private struct NoticesTextPane: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // A 565 KB document is searched, not reread.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = AppFonts.terminal(size: DisplayFit.dp(11))
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}
#endif

/// The device code, shown while waiting for the browser half of sign-in.
private struct SignInCode: View {
    var device: DeviceLogin
    var onCancel: () -> Void

    var body: some View {
        Card(
            title: L10n.text("apple.accountview.confirm_in_your_browser.d3ed543d"),
            subtitle: L10n.text("apple.accountview.a_page_should_have_opened_at_0.8fba8da9", "\(device.verificationURI)"),
            mark: "mark_account"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(device.userCode)
                    .font(Theme.monoText(30, weight: .semibold))
                    .textSelection(.enabled)
                    .padding(.vertical, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.m)
                    .background(
                        .quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: Theme.Space.s)
                    )

                Text(L10n.text("apple.accountview.check_that_the_page_shows_this_code_then_a.758f4c22"))
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("apple.accountview.waiting_for_confirmation.a6fb491f"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("common.cancel"), .dismiss, action: onCancel)
                }
            }
        }
    }
}
