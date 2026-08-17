// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

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
                .navigationTitle("Account")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
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

/// Phone-sized account settings: identity, plan, devices, sign out, legal.
private struct ClientAccountContent: View {
    @Environment(AccountModel.self) private var model

    @State private var showLicenses = false
    @State private var showPaywall = false
    @State private var showDeletionWeb = false
    @State private var deletionURL: URL?
    @State private var webURL: URL?
    @State private var confirmSignOut = false

    var body: some View {
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

                if model.signedIn, let account = model.account {
                    identity(account)
                    planCard(account)
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

                legalCard
                licensesCard
                deleteAccountCard
                privacyNote
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, Theme.Space.xl)
        }
        .background(Theme.background)
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
    }

    private func identity(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Avatar(url: account.avatar, handle: account.handle, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Text(account.title ?? "Signed in")
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
                        Text(tier.capitalized + " plan")
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
                    ActionIcon.external.label("View public profile")
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
                Text("Plan")
                    .font(ClientType.sectionTitle)
            }
            if let tier = account.tier, !tier.isEmpty {
                Text(tier.capitalized
                    + (account.billing?.periodEnd.map { " · until \(Self.shortDay($0))" } ?? ""))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
            }
            if account.isAppleBilled {
                Text("Bought on the App Store. See every plan here, then change or cancel in Apple ID subscriptions.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = account.billing?.scheduledTier, !next.isEmpty {
                    Text("Switches to \(next.capitalized) at the next renewal.")
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.accent)
                }
                Button {
                    showPaywall = true
                } label: {
                    ActionIcon.plans.label("See plans")
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
                Text("You subscribed on the website. Manage that plan there.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if account.isWebManagedPlan {
                Text("This plan is not an App Store purchase. Manage it on the web.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The app stays free. A yearly plan unlocks more devices, longer history, and remote management.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showPaywall = true
                } label: {
                    ActionIcon.plans.label("See plans")
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

    private func lastSync(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ClientSectionTitle(title: "Last sync", mark: "mark_sync")
            Text(formatRelativeDate(account.lastSyncAt) ?? "Never")
                .font(ClientType.figureSmall)
                .foregroundStyle(Theme.accent)
            Text("From any device on this account. This phone reads that data; it does not upload an archive of its own.")
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
            ClientSectionTitle(title: "Devices", mark: "mark_device")
            Text(
                account.machines.isEmpty
                    ? "None linked yet. Install tokenstat on a computer and sign in there."
                    : "\(account.machines.count) linked to this account"
            )
            .font(ClientType.body)
            .foregroundStyle(.secondary)

            if !account.machines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(account.machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 {
                            Divider().padding(.vertical, Theme.Space.s)
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
            Image(systemName: isThis ? "iphone" : "laptopcomputer")
                .font(.body)
                .foregroundStyle(isThis ? Theme.accent : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(deviceName(machine))
                        .font(ClientType.label.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isThis {
                        Text("this device")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if machine.reportsArchiveSync {
                    Text(formatRelativeDate(machine.lastSyncAt) ?? "never synced")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                } else if let seen = formatRelativeDate(machine.lastSeenAt) {
                    Text("last used \(seen)")
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
                    ActionIcon.signOut.label("Sign out")
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
        .accessibilityHint("Signs out of this device and ends the online session")
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
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ClientSectionTitle(title: "Not signed in", mark: "mark_account")
            Text("Signing in lets this phone read usage from every device on your account. Only aggregate counters leave a computer.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            Button {
                model.signIn()
            } label: {
                ActionIcon.signIn.label("Sign in")
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
            ClientSectionTitle(title: "Terms and privacy", mark: "mark_license")
            legalLink("Privacy policy", url: ClientWebPages.privacy())
            Divider()
            legalLink("Terms of service", url: ClientWebPages.terms())
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var licensesCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "Open source licenses", mark: "mark_license")
            Text("Third-party notices for the libraries bundled in this build.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            Button {
                showLicenses = true
            } label: {
                ActionIcon.docs.label("View licenses")
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
            ClientSectionTitle(title: "Delete this account", mark: "mark_delete", tint: Theme.danger)
            Text(
                model.account?.billing?.isApple == true
                    && model.account?.billing?.blocksOtherStore == true
                    ? "Cancel the App Store plan in Apple ID subscriptions first. Deleting the account cannot stop Apple from charging."
                    : "Permanent. Confirmed on the website's data settings. The account, linked providers, sessions and usage are removed outright."
            )
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openAccountDeletion()
            } label: {
                ActionIcon.delete.label("Delete on website…")
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: "What syncing sends", mark: "mark_sync")
            Text("""
            Aggregate counts per day, tool and model, and project names replaced \
            by salted hashes. Prompts, replies, file contents, file paths and \
            session ids are never eligible.
            """)
            .font(ClientType.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
                        "Notices missing",
                        systemImage: "doc.questionmark",
                        description: Text("The third-party notices are generated at build time and were not found in this build.")
                    )
                } else {
                    ProgressView("Loading licenses…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle("Open source licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        let base = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
    }
}

#endif
