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
                    hostCard
                    terminalCard
                    localModelsCard
                    #endif
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
        .task { if model.account == nil { await model.load() } }
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
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    model.signIn()
                } label: {
                    Label("Sign in to tokenstat.ai", systemImage: "person.crop.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
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
                        .font(.system(size: 22, weight: .semibold))
                    if let tier = account.tier, !tier.isEmpty {
                        TierMark(tier: tier, size: 17)
                    }
                }
                if let handle = account.handle {
                    Text("@\(handle)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(account.host)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let handle = account.handle, let url = URL(string: "\(account.host)/\(handle)") {
                // The profile is a public page and this is the only place in
                // the app that knows its address.
                Link(destination: url) {
                    Label("View profile", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .font(.callout)
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
                            .font(.system(size: 17, weight: .medium))
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
                    .tint(Theme.accent)
                    .disabled(model.isSyncing || model.syncCooldownUntil != nil)
                    #endif
                }

                #if os(macOS)
                if model.syncCooldownUntil != nil {
                    Text("Syncing again is available shortly.")
                        .font(.caption)
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
                            Divider().padding(.vertical, Theme.Space.xs)
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
                            .font(.callout)
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if isThisMachine {
                        Text("THIS MAC")
                            .font(.system(size: 9, weight: .bold))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(formatServerDate(machine.lastSyncAt) ?? "never synced")
            } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                Text("last used \(seen)")
                    .font(.caption)
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
            .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.limitsProviders.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 {
                                Divider().padding(.vertical, Theme.Space.xs)
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
                    .font(.callout)
                Text(planLimitDetail(provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: Binding(
                get: { model.sharesLimits(of: provider.source) },
                set: { on in Task { await model.setLimitsSourceShared(provider.source, shared: on) } }
            ))
            .toggleStyle(.switch)
            .tint(Theme.accent)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !policy.alwaysOn {
                        Text("Automations run only while tokenstat is open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("The host helper has not answered yet.")
                        .font(.callout)
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
                Divider()
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
                        .font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                } else if localModels.providers.isEmpty && !localModels.isLoading {
                    Text("LM Studio (port 1234) and Ollama (port 11434) could not be checked. Start one and tap refresh.")
                        .font(.callout)
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

    private func localProviderRow(_ provider: LocalProvider) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(provider.available && localModels.isEnabled(provider.id) ? Theme.accent : Theme.border)
                    .frame(width: 8, height: 8)
                Text(provider.name)
                    .font(.callout.weight(.medium))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if provider.available {
                if provider.models.isEmpty {
                    Text(provider.id == "lmstudio"
                         ? "Server is up. Load a model in LM Studio to use it here."
                         : "Server is up. Pull or run a model in Ollama to use it here.")
                        .font(.caption)
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
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } else {
                Text(localProviderHint(provider))
                    .font(.caption)
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
                    .font(.caption)
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
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    openAccountDeletion()
                } label: {
                    Label("Delete on website…", systemImage: "trash")
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
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.m)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Theme.accent)
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open source licenses")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Third-party notices for bundled dependencies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.controlGlyph)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.controlSeat))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            Group {
                if let text {
                    #if os(macOS)
                    NoticesTextPane(text: text)
                    #else
                    Text("Open licenses from the account sheet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                } else if loadFailed {
                    // A development build that ran without the generating
                    // build phase, or a bundle that lost the file.
                    Text("The third-party notices are generated at build time and were not found in this build.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Theme.Space.s)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Theme.Space.m)
        #if os(macOS)
        .frame(width: 620, height: 520)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(Theme.panel)
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
        textView.font = .monospacedSystemFont(ofSize: DisplayFit.dp(11), weight: .regular)
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
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.m)
                    .background(
                        .quaternary.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: Theme.Space.s)
                    )

                Text("Check that the page shows this code, then approve it there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for confirmation…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", .dismiss, action: onCancel)
                }
            }
        }
    }
}
