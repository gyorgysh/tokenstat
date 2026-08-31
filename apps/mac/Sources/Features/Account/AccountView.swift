// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

struct AccountView: View {
    @Bindable var model: AccountModel
    @Environment(\.openURL) private var openURL
    /// Whether the third-party notices sheet is open.
    @State private var confirmSignOut = false
    @State private var showLicenses = false
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
                        help: "Sync now",
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
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message)
                    }
                    if let device = model.pendingLogin {
                        SignInCode(device: device) { model.cancelSignIn() }
                    } else if model.signedIn, let account = model.account {
                        signedIn(account)
                    } else if model.account != nil {
                        signedOut
                    } else {
                        // Neither state is known yet. Showing "sign in" here would
                        // flash the wrong answer on every launch.
                        ProgressView().frame(maxWidth: .infinity)
                    }

                    #if os(macOS)
                    forgeCard
                    hostCard
                    terminalCard
                    localModelsCard
                    #endif
                    notificationsCard
                    licensesCard
                    deleteAccountCard
                    privacyNote
                }
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.background)
        .navigationTitle("Account")
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
                               : (model.syncNoticeIsError ? .danger : .success))
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
            title: "Not signed in",
            subtitle: "Everything works without an account. Signing in only adds the option to publish.",
            mark: "mark_account"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("""
                An account lets you publish a profile page and see usage from \
                all your machines in one place. Only aggregate counters are \
                eligible to be sent.
                """)
                .font(Theme.callout)
                .foregroundStyle(.secondary)

                Button("Sign in to tokenstat.ai", .signIn) {
                    model.signIn()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func signedIn(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            identity(account)
            syncCard(account)
            #if os(macOS)
            planLimitsCard
            #endif
            machinesCard(account)
        }
    }

    /// Who you are, at the size a profile deserves.
    ///
    /// This screen used to open with three `Stat` columns reading "Handle",
    /// "Plan", "Last sync", which is a report about an account rather than an
    /// account. The picture, the name and the tier belong together and belong
    /// first.
    private func identity(_ account: Account) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Avatar(url: account.avatar, handle: account.handle, size: 64)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(account.title ?? "Signed in")
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
                    ActionIcon.external.label("View profile")
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
            title: "Sync",
            subtitle: "Only aggregate counters are eligible",
            mark: "mark_sync"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LAST SYNC")
                            .font(Theme.sectionHeader)
                            .foregroundStyle(.tertiary)
                        // Relative, with the exact time on hover. "12 minutes ago"
                        // is the answer to the question; a date and a clock time
                        // makes you work it out.
                        Text(formatRelativeDate(account.lastSyncAt) ?? "Never")
                            .font(Theme.font(17, weight: .medium))
                            .help(formatServerDate(account.lastSyncAt) ?? "This account has never synced")
                    }

                    Spacer()

                    #if os(macOS)
                    Button {
                        Task { await model.sync() }
                    } label: {
                        if model.isSyncing {
                            HStack(spacing: Theme.Space.xs) {
                                ProgressView().controlSize(.small)
                                Text("Syncing…")
                            }
                        } else {
                            ActionIcon.refresh.label("Sync now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSyncing || model.syncCooldownUntil != nil)
                    #endif
                }

                #if os(macOS)
                if model.syncCooldownUntil != nil {
                    Text("Syncing again is available shortly.")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    confirmSignOut = true
                } label: {
                    if model.isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionIcon.signOut.label("Sign out")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isSyncing || model.isSigningOut)
                .confirmationDialog(
                    "Sign out of this device?",
                    isPresented: $confirmSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Usage on this account stays. You will need to approve the device again.")
                }
                #else
                // Phone account UI lives in `ClientAccountSheet`. Keep a
                // non-system control here if this view is ever shown on iOS.
                Button {
                    Task { await model.signOut() }
                } label: {
                    if model.isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        ActionIcon.signOut.label("Sign out")
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
                return "Every device that has synced to this account"
            }
            if let limit {
                return "\(used) of \(limit) devices"
                    + (account.canRemote == false ? ". No remote control on this plan." : "")
            }
            return "\(account.machines.count) linked"
        }()
        return Card(title: "Devices", subtitle: subtitle, mark: "mark_device") {
            if account.machines.isEmpty {
                #if os(macOS)
                EmptyState(
                    symbol: "laptopcomputer.and.iphone",
                    title: "Nothing linked yet",
                    message: "Free includes two devices. Sync now to put this Mac on the account."
                )
                #else
                EmptyState(
                    symbol: "laptopcomputer.and.iphone",
                    title: "No devices yet",
                    message: "Install tokenstat on a computer and sign in there. This phone uses one of the two Free slots."
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
                        Text("THIS MAC")
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
                Text(formatRelativeDate(machine.lastSyncAt) ?? "never synced")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .help(formatServerDate(machine.lastSyncAt) ?? "never synced")
            } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                Text("last used \(seen)")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// The claim, stated where someone is deciding whether to connect an
    /// account. This is the moment it matters, not the marketing page.
    private var privacyNote: some View {
        Card(title: "What syncing sends", subtitle: nil, mark: "mark_sync") {
            Text("""
            Aggregate counts per day, tool and model, and project names replaced \
            by salted hashes. Prompts, replies, file contents, file paths and \
            session ids are never eligible.
            """)
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
            title: "Plan limits",
            subtitle: "Track vendor quota windows. Off means this Mac does not read that vendor and does not show it on Home.",
            mark: "mark_plan"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                toggleRow(
                    "Share with my devices",
                    detail: "Posts how full each window is, so a phone can show what is left while this Mac is asleep. Percentages and reset times only, never a credential. Turning a vendor off below also stops tracking it on this Mac.",
                    isOn: Binding(
                        get: { model.limitsSyncEnabled },
                        set: { on in Task { await model.setLimitsSync(on) } }
                    )
                )
                if model.limitsProviders.isEmpty {
                    Text(model.isLoadingLimits
                         ? "Looking for vendor readings…"
                         : "No readings yet. Open Home, or wait for the hourly pass, then come back.")
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
            .accessibilityLabel("Track \(harnessName(provider.source))")
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
            parts.append("last reading is old")
        }
        if parts.isEmpty {
            return "No windows reported"
        }
        return parts.joined(separator: " · ")
    }

    private var hostCard: some View {
        Card(
            title: "This Mac",
            subtitle: "Whether the host helper stays up after you quit",
            mark: "mark_host"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let policy = model.hostPolicy {
                    toggleRow(
                        "Always-on host",
                        detail: alwaysOnDetail(policy),
                        isOn: Binding(
                            get: { policy.alwaysOn },
                            set: { on in Task { await model.setAlwaysOnHost(on) } }
                        )
                    )
                    .disabled(model.isSavingHostPolicy)
                    if policy.alwaysOn && policy.hasInternalBattery {
                        Text("Uses more power.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !policy.alwaysOn {
                        Text("Automations run only while tokenstat is open.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("The host helper has not answered yet.")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func alwaysOnDetail(_ policy: HostPolicy) -> String {
        if policy.alwaysOn {
            return "The host helper keeps running after you quit tokenstat, so other devices can reach this Mac. This Mac will not idle-sleep. A laptop still sleeps when you close the lid."
        }
        return "The host helper stops when you quit tokenstat, so this Mac can sleep. Other devices cannot open folders or terminals here until you open the app again."
    }
    #endif

    private var terminalCard: some View {
        Card(
            title: "Terminal",
            subtitle: "How terminal sessions behave",
            mark: "mark_terminal"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                // These describe terminals, and a client has none.
                #if os(macOS)
                toggleRow(
                    "Expose terminal output to VoiceOver",
                    detail: "Lets VoiceOver read the terminal as a text area. Applies when a terminal appears.",
                    isOn: Binding(
                        get: { TerminalPreferences.exposesToVoiceOver },
                        set: { TerminalPreferences.exposesToVoiceOver = $0 }
                    )
                )
                ThemeRule()
                toggleRow(
                    "Disable colours",
                    detail: "New terminals start with NO_COLOR, for apps that switch to monochrome when it is set.",
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
            title: "Local models",
            subtitle: "LM Studio on port 1234, Ollama on port 11434",
            mark: "mark_local"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text("Nothing is sent to tokenstat. These checks use loopback only. Start the app, load a model, then refresh.")
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
                    .help("Check LM Studio and Ollama again")
                    .disabled(localModels.isLoading)
                }

                if let error = localModels.errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                } else if localModels.providers.isEmpty && !localModels.isLoading {
                    Text("LM Studio (port 1234) and Ollama (port 11434) could not be checked. Start one and tap refresh.")
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
            title: "GitHub pull requests",
            subtitle: "Checked only when you open pull requests or this Account screen",
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
                            Text(forgeConnection.login.map { "@\($0)" } ?? "Not connected")
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
                                forgeConnecting ? "Opening GitHub…" : "Connect tokenstat GitHub App"
                            )
                        }
                        .buttonStyle(AccentButtonStyle(small: true))
                        .disabled(forgeConnecting || forgeBusy)
                    }
                    HStack(spacing: Theme.Space.s) {
                        if forgeConnection.source == "tokenstat" {
                            Button("Choose repositories", .external) {
                                openURL(Self.githubInstallationURL)
                            }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                        }
                        Button("Refresh", .refresh) { Task { await loadForgeConnection() } }
                            .buttonStyle(SecondaryButtonStyle(small: true))
                            .disabled(forgeBusy)
                        if canSignOutForge(forgeConnection) {
                            Button("Sign out", .signOut) { confirmingForgeSignOut = true }
                                .buttonStyle(SecondaryButtonStyle(small: true))
                                .disabled(forgeBusy)
                        }
                    }
                } else if forgeError == nil {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Checking the GitHub connection…")
                            .font(Theme.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .confirmationDialog(
            "Sign out of GitHub pull requests?",
            isPresented: $confirmingForgeSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { Task { await signOutForge() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The GitHub token saved by tokenstat will be removed. A credential already managed by git or your login environment may still be used.")
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
                title: "Connect tokenstat GitHub App",
                subtitle: "Enter this one-time code in the GitHub page that just opened.",
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
                        Text("Waiting for GitHub…")
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
                Button("Cancel", .dismiss) { Task { await cancelForgeLogin() } }
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
        case "gitCredential": "Using the credential git already has"
        case "environment": "Using GH_TOKEN or GITHUB_TOKEN from your login environment"
        case "pasted": "Using a token saved by tokenstat"
        case "tokenstat": "Connected through tokenstat"
        default: "No GitHub credential found"
        }
        return "\(connection.host) · \(source)"
    }

    private func forgeConnectionMessage(_ connection: PullForgeConnection) -> String {
        switch connection.source {
        case "tokenstat":
            return "Connected with the tokenstat GitHub App. Pull requests are limited to repositories you choose on GitHub."
        case "gitCredential", "environment":
            return "Pull requests work through a credential owned by another tool. Connect the tokenstat GitHub App to choose exactly which repositories tokenstat may access."
        case "pasted":
            return "A token saved by tokenstat is active. You can replace it with the tokenstat GitHub App and selected-repository access."
        default:
            return "Connect the tokenstat GitHub App, then choose the repositories tokenstat may open."
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
            if !localModels.isEnabled(provider.id) {
                Text("Disabled for local model selection")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            } else if provider.available {
                if provider.models.isEmpty {
                    Text(provider.id == "lmstudio"
                         ? "Server is up. Load a model in LM Studio to use it here."
                         : "Server is up. Pull or run a model in Ollama to use it here.")
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
        let raw = provider.error ?? "not running"
        if raw == "not running" || raw.hasPrefix("not running") {
            return provider.id == "lmstudio"
                ? "Not running. Open LM Studio and turn on the local server (port 1234)."
                : "Not running. Start Ollama (port 11434)."
        }
        return raw
    }
    #endif

    /// Show phones as phones on both the desktop account card and the client.
    /// A host is a computer, with the current one using the laptop variant.
    private func machineIcon(_ machine: Machine, isThisMachine: Bool) -> String {
        if !machine.isHost { return "iphone" }
        return isThisMachine ? "laptopcomputer" : "desktopcomputer"
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
            title: "Notifications",
            subtitle: "When an agent run or a chat finishes, or stops for a question.",
            mark: "mark_device"
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                #if os(macOS)
                toggleRow(
                    "Tell me when work needs attention",
                    detail: "Chats, automations, and workflows on this Mac. Nothing leaves the machine: this Mac watches its own work.",
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
                        Button("Send a test", .preview) { RunNotifications.shared.sendTest() }
                            .buttonStyle(AccentButtonStyle(small: true))
                    }
                }
                #else
                toggleRow(
                    "Notify this device",
                    detail: "Sent through Apple, so it arrives with the app closed. The notification says which machine and that a run or a chat ended, and carries nothing about the work.",
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
                        Button("Send a test", .preview) {
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
            title: "Open source licenses",
            subtitle: "Third-party notices for the bundled dependencies.",
            mark: "mark_license"
        ) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("tokenstat links open source libraries, each under its own licence. The notices are generated from the resolved dependency graph at build time.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View", .preview) { showLicenses = true }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .help("Show the licence and notice for every bundled dependency")
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
            title: "Delete this account",
            subtitle: "Permanent. Confirmed on the website's data settings.",
            mark: "mark_delete",
            markTint: Theme.danger
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("""
                Deleting is immediate and permanent: the account, its linked \
                providers, its sessions, and any usage data are removed \
                outright, not flagged as gone. There is no undo.
                """)
                .font(Theme.callout)
                .foregroundStyle(.secondary)

                Button {
                    openAccountDeletion()
                } label: {
                    ActionIcon.delete.label("Delete on website…")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .help("Opens the data settings where deletion is confirmed")
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
            title: "Third-party notices",
            subtitle: "Licences for the software bundled with tokenstat.",
            icon: .docs,
            onClose: { dismiss() }
        ) {
            Group {
                if let text {
                    #if os(macOS)
                    NoticesTextPane(text: text)
                    #else
                    Text("Open licenses from the account sheet.")
                        .font(Theme.callout)
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                } else if loadFailed {
                    // A development build that ran without the generating
                    // build phase, or a bundle that lost the file.
                    Text("The third-party notices are generated at build time and were not found in this build.")
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
            title: "Confirm in your browser",
            subtitle: "A page should have opened at \(device.verificationURI)",
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

                Text("Check that the page shows this code, then approve it there.")
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation…")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", .dismiss, action: onCancel)
                }
            }
        }
    }
}
