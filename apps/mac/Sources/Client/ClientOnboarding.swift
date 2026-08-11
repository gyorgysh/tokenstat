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
/// So: three pages, swipeable, then a button. Deliberately three. It is enough
/// to say what this is, what it costs you, and what to do next, and it is few
/// enough that people reach the end.
///
/// Shown once. `hasOnboarded` is `@AppStorage`, so the second launch goes
/// straight to the sign-in card, and a signed-in phone never sees this at all.
struct ClientOnboarding: View {
    @Environment(AccountModel.self) private var account
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    @State private var page = 0

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "square.grid.3x3.fill",
            title: "Every device, one number",
            body: "What your agents cost, across every laptop on your account, "
                + "with all of them asleep."
        ),
        OnboardingPage(
            symbol: "gauge.with.dots.needle.33percent",
            title: "Know what is left",
            body: "How much of each plan you have used, and when the window "
                + "resets. Always with the date it was read."
        ),
        OnboardingPage(
            symbol: "lock.fill",
            title: "It stays yours",
            body: "Counting happens on your own devices. Only totals are "
                + "eligible to sync, never prompts, code or file names."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            // The system's own dots are drawn for a dark scheme, so on this
            // background they were three grey marks nobody could see. Ours are
            // the accent, which also makes the position obvious at a glance.
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots
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
                Button("Skip") { finish() }
                    .font(ClientType.label)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
    }

    /// Where you are, and how much is left. Three dots is also the honest
    /// promise that this ends soon.
    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<Self.pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.accent : Theme.accent.opacity(0.22))
                    // The current one is a short bar rather than a bigger dot:
                    // size alone is hard to judge at seven points across.
                    .frame(width: index == page ? 20 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
            }
        }
        .padding(.bottom, Theme.Space.l)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            if page < Self.pages.count - 1 {
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                }
                .buttonStyle(.glassProminent)
            } else {
                Button("Sign in") {
                    finish()
                    account.signIn()
                }
                .buttonStyle(.glassProminent)
                Button("Not now") { finish() }
                    .font(ClientType.label)
            }
        }
        .tint(Theme.accent)
        .controlSize(.large)
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.xl)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private func finish() {
        hasOnboarded = true
    }
}

private struct OnboardingPage {
    let symbol: String
    let title: String
    let body: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: page.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.accent, Theme.secondary],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // One small arrival, once per page. Off under Reduce Motion,
                // where it becomes a plain appearance.
                .scaleEffect(reduceMotion || shown ? 1 : 0.86)
                .opacity(reduceMotion || shown ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: shown)
            Text(page.title)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .multilineTextAlignment(.center)
            Text(page.body)
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            // One Spacer above and one below, weighted so the block sits a
            // little above centre. Two below pushed everything into the top
            // third and left the bottom of the screen empty.
            Spacer()
            Spacer().frame(height: 40)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity)
        .onAppear { shown = true }
        .accessibilityElement(children: .combine)
    }
}

#endif
