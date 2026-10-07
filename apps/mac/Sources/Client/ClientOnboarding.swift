// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// The first thing a new install shows.
///
/// A signed-out phone has nothing to draw, and the first version drew exactly
/// that: one card on an empty screen, asking for a sign-in before saying what
/// the app was for. Nobody signs into a product they have not been told about.
///
/// Three short pages explain the work, its computer and its projects. Sign-in stays a deliberate next step.
///
/// Shown once. `hasOnboarded` is `@AppStorage`, so the second launch goes
/// straight to the sign-in card, and a signed-in phone never sees this at all.
struct ClientOnboarding: View {
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    @Bindable var flow: ClientIntroProgress
    private var page: Int { flow.page }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            art: .intro,
            topic: L10n.text("apple.clientonboarding.welcome.0e2226b5"),
            title: L10n.text("apple.clientonboarding.your_coding_agents_within_reach.e0c0e724"),
            body: L10n.text("apple.clientonboarding.run_coding_agents_on_your_computer_or_a_se.e496252a")
        ),
        OnboardingPage(
            art: .onTheGo,
            topic: L10n.text("apple.clientonboarding.machines.c061da19"),
            title: L10n.text("apple.clientonboarding.choose_where_the_work_runs.0e0fe3ac"),
            body: L10n.text("apple.clientonboarding.use_a_computer_you_own_or_a_cloud_server_c.d1c3ffac")
        ),
        OnboardingPage(
            art: .workspaces,
            topic: L10n.text("common.projects"),
            title: L10n.text("apple.clientonboarding.go_from_the_chat_to_the_code.612842a3"),
            body: L10n.text("apple.clientonboarding.open_a_folder_or_clone_a_repository_read_a.1ff55f95")
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
            TabView(selection: $flow.page) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack {
            Wordmark()
            Spacer()
            // A way past the pitch for anyone who does not want it. On the last
            // page it would duplicate the button below, so it goes.
            if page < Self.pages.count - 1 {
                Button(L10n.text("common.skip")) { finish() }
                    .font(ClientType.label)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("intro.skip")
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
    }

    /// Named steps and a finite rail make the length clear before the first swipe.
    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(Self.pages[page].topic)
                    .font(ClientType.label.weight(.semibold))
                Spacer()
                Text(L10n.text("apple.clientonboarding.0_of_1.9fea8201", "\(page + 1)", "\(Self.pages.count)"))
                    .font(ClientType.caption.monospacedDigit())
            }
            .foregroundStyle(Theme.accent)
            HStack(spacing: Theme.Space.xs) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= page ? Theme.accent : Theme.accentSoft)
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("apple.clientonboarding.0_page_1_of_2.065b6e28", "\(Self.pages[page].topic)", "\(page + 1)", "\(Self.pages.count)"))
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.m) {
            if page == Self.pages.count - 1 {
                Text(L10n.text("apple.clientonboarding.next_sign_in_you_can_connect_a_machine_whe.71155587"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Theme.Space.s))
                : AnyLayout(HStackLayout(spacing: Theme.Space.m))
            layout {
                if page > 0 {
                    Button(L10n.text("common.back"), .back) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { flow.back() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("intro.back")
                }
                Button {
                    if page == Self.pages.count - 1 {
                        finish()
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { _ = flow.advance() }
                    }
                } label: {
                    ActionIcon.next.label(page == Self.pages.count - 1 ? L10n.text("apple.clientonboarding.get_started.61e8d44a") : L10n.text("apple.clientonboarding.continue.31fbef16"))
                        .labelStyle(ActionLabelStyle())
                        .frame(maxWidth: .infinity)
                }
                .clientProminentStyle()
                .accessibilityIdentifier("intro.continue")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.l)
    }

    private func finish() {
        hasOnboarded = true
    }
}

private struct OnboardingPage {
    let art: OnboardingArtKind
    let topic: String
    let title: String
    let body: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                ClientOnboardingArt(kind: page.art, reduceMotion: reduceMotion)
                    .padding(.top, Theme.Space.s)
                Text(page.title)
                    .font(Theme.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.l)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .combine)
    }
}

#endif
