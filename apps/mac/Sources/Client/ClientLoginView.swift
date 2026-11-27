// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)
import UIKit

struct ClientLoginView: View {
    @Environment(ConnectivityModel.self) private var connectivity: ConnectivityModel?
    @Environment(AccountModel.self) private var account
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false
    @State private var webURL: URL?
    @State private var developerUnlock = ReviewBuild.LoginLogoUnlock()
    @State private var developerNotice: String?
    @State private var pointer = ChatStartPointer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: Theme.Space.m) {
                Button {
                    if let enabled = developerUnlock.tap() {
                        let notice = enabled
                            ? L10n.text("apple.clientloginview.developer_mode_enabled")
                            : L10n.text("apple.clientloginview.developer_mode_disabled")
                        developerNotice = notice
                        UIAccessibility.post(notification: .announcement, argument: notice)
                    }
                } label: {
                    LogoMark(size: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("apple.marks.tokenstat.63d30539"))
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
                    Text(connectivity?.isOffline == true
                        ? L10n.text("apple.clientloginview.this_device_is_offline_sign_in_once_it_is.cd1bb1f0")
                        : message)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                }

                Button(L10n.text("apple.clientloginview.what_is_tokenstat.b2e003ed"), .help) { hasOnboarded = false }
                    .font(ClientType.label)
                    .padding(.top, Theme.Space.xs)

                VStack(spacing: Theme.Space.xs) {
                    Text(L10n.text("apple.clientloginview.demo_login_instructions"))
                    HStack(spacing: 4) {
                        Text(L10n.text("apple.clientloginview.by_signing_in_you_accept_the.ba0bbbf2"))
                        legal(L10n.text("apple.clientloginview.terms.ede54899"), url: ClientWebPages.terms())
                        Text(L10n.text("apple.clientloginview.and.6201111b"))
                        legal(L10n.text("apple.clientloginview.privacy_policy.ba445cff"), url: ClientWebPages.privacy())
                    }
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
        .background {
            ChatStartBackdrop(active: scenePhase == .active, lift: account.pendingLogin != nil,
                              pointer: pointer, focus: UnitPoint(x: 0.5, y: 0.34))
        }
        .overlay(alignment: .bottom) {
            TransientToast(message: $developerNotice)
                .padding(Theme.Space.m)
        }
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

    private func waiting(_ pending: DeviceLogin) -> some View {
        VStack(spacing: Theme.Space.s) {
            ProgressView()
            Text(L10n.text("apple.clientloginview.waiting_for_approval.10c5739b"))
                .font(ClientType.screenTitle)
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
