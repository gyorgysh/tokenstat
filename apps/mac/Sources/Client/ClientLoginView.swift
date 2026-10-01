// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The door. Nothing in the client is reachable until this is answered.
///
/// Every screen behind it answers a question about an account, so a signed-out
/// phone with tabs is four empty screens carrying the same sign-in card. One
/// door is both simpler and more honest about what the app is.
///
/// There is no separate "create account" button, and that is not an omission.
/// The website has no registration: an account is created the first time
/// somebody signs in with a provider they already have. A second button leading
/// to the identical flow would be a fake choice, so the line under the button
/// says what actually happens instead.
#if !os(macOS)
struct ClientLoginView: View {
    @Environment(ConnectivityModel.self) private var connectivity: ConnectivityModel?
    @Environment(AccountModel.self) private var account
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false
    @State private var webURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Mark, name, sentence. No "Sign in" heading: the button at the
            // bottom of the same screen says it, and saying it twice made the
            // product's own name look like a subtitle to the word above it.
            VStack(spacing: Theme.Space.m) {
                LogoMark(size: 52)
                Wordmark(size: 28, fills: false, showsMark: false)
                Text(L10n.text("apple.clientloginview.your_coding_agents_projects_and_ai_usage_t.6cfcf32f"))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()

            VStack(spacing: Theme.Space.m) {
                if let pending = account.pendingLogin {
                    waiting(pending)
                } else {
                    if account.deletionConfirmed {
                        Label {
                            Text(L10n.text("apple.clientloginview.your_account_was_deleted_this_device_is_si.8720581b"))
                        } icon: {
                            Image(systemName: "trash")
                        }
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: 340)
                        .padding(Theme.Space.m)
                        .background(Theme.accentSoft, in: .rect(cornerRadius: 12))
                        .multilineTextAlignment(.center)
                    }
                    // The frame goes on the label, not on the button. A
                    // prominent button keeps its intrinsic capsule width, so
                    // stretching the button only stretched the space around it.
                    Button {
                        account.signIn()
                    } label: {
                        ActionIcon.signIn.label(L10n.text("common.sign_in"))
                            .labelStyle(ActionLabelStyle())
                            .frame(maxWidth: .infinity)
                    }
                    .clientProminentStyle()
                    .controlSize(.large)
                    Text(L10n.text("apple.clientloginview.no_password_to_make_signing_in_with_github.06825264"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let message = account.errorMessage {
                    // Signing in is the one screen where "could not reach the
                    // account" is not a partial failure: nothing happened at
                    // all, and saying which is what stops somebody trying a
                    // password they never typed.
                    Text(connectivity?.isOffline == true
                        ? L10n.text("apple.clientloginview.this_device_is_offline_sign_in_once_it_is.cd1bb1f0")
                        : message)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }

                // A way back to the intro, for anyone who skipped it and then
                // wondered what this is. Cheap, and it means Skip is not a
                // one-way door.
                Button(L10n.text("apple.clientloginview.what_is_tokenstat.b2e003ed"), .help) { hasOnboarded = false }
                    .font(ClientType.label)
                    .padding(.top, Theme.Space.xs)

                // Signing in creates the account, so the two documents that
                // govern it belong on this screen and not only in Settings.
                HStack(spacing: 4) {
                    Text(L10n.text("apple.clientloginview.by_signing_in_you_accept_the.ba0bbbf2"))
                    legal(L10n.text("apple.clientloginview.terms.ede54899"), url: ClientWebPages.terms())
                    Text(L10n.text("apple.clientloginview.and.6201111b"))
                    legal(L10n.text("apple.clientloginview.privacy_policy.ba445cff"), url: ClientWebPages.privacy())
                }
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Space.xs)
            }
            .tint(Theme.accent)
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.xl)
            .animation(.easeInOut(duration: 0.2), value: account.pendingLogin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: Binding(
            get: { webURL != nil },
            set: { if !$0 { webURL = nil } }
        )) {
            if let webURL {
                ClientWebBrowser(url: webURL)
            }
        }
    }

    @ViewBuilder
    private func legal(_ title: String, url: URL) -> some View {
        Button(title) {
            webURL = url
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }

    /// The approval is happening in the browser sheet.
    ///
    /// Shown for the same reason `ClientSignInCard` shows it: the sheet can be
    /// dismissed while the sign-in is alive underneath, and without this the
    /// screen would look exactly as it did before the tap.
    private func waiting(_ pending: DeviceLogin) -> some View {
        VStack(spacing: Theme.Space.s) {
            ProgressView()
            Text(L10n.text("apple.clientloginview.waiting_for_approval.10c5739b"))
                .font(ClientType.screenTitle)
            // The network notice replaces the instruction rather than stacking
            // under it: while there is no connection, "approve on the website"
            // is advice that cannot be followed.
            Text(account.signInNotice ?? L10n.text("apple.clientloginview.approve_this_device_on_tokenstat_ai_this_s.bad8690a"))
                .font(ClientType.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(pending.userCode)
                .font(Theme.monoText(20, relativeTo: .title3).weight(.semibold))
                .tracking(2)
                .padding(.vertical, Theme.Space.s)
                .padding(.horizontal, Theme.Space.m)
                .background(Theme.accentSoft, in: .rect(cornerRadius: 10))
                .accessibilityLabel(L10n.text("apple.clientloginview.code_0.e5813712", "\(pending.userCode.map(String.init).joined(separator: " "))"))
            HStack(spacing: Theme.Space.s) {
                Button(L10n.text("apple.clientloginview.open_the_page.911fa06e"), .external) { account.presentSignInPage() }
                    .clientGlassStyle()
                Button(L10n.text("common.cancel"), .dismiss) { account.cancelSignIn() }
                    .clientGlassStyle()
            }
            .padding(.top, 2)
        }
    }
}
#endif
