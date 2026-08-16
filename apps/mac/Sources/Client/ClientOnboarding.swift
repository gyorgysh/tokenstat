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
/// Ten pages, swipeable, then Get started. Usage, plan windows, workspaces,
/// live sessions, the phone-to-Mac link, and the privacy switches. Signing in
/// is not this screen's job: that is the next door, and it waits for a
/// deliberate tap.
///
/// Shown once. `hasOnboarded` is `@AppStorage`, so the second launch goes
/// straight to the sign-in card, and a signed-in phone never sees this at all.
struct ClientOnboarding: View {
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    @State private var page = 0

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            art: .intro,
            title: "What tokenstat is",
            body: "One place for the AI coding tools you already use. Usage, "
                + "plan windows, workspaces, and live sessions, on the computers "
                + "you work on and on this phone."
        ),
        OnboardingPage(
            art: .heatmap,
            title: "Your AI Heatmap",
            body: "Every day, every model, every tool, as one year you can "
                + "read. Counts stay on the devices that made them unless "
                + "you opt to sync totals."
        ),
        OnboardingPage(
            art: .devices,
            title: "All your devices",
            body: "Laptops and phones share one account. Open the phone while "
                + "every computer is asleep, and the numbers are still there."
        ),
        OnboardingPage(
            art: .spend,
            title: "Where it went",
            body: "Split by tool, model, and project. See what actually used "
                + "the tokens, not a single total that hides the expensive day."
        ),
        OnboardingPage(
            art: .remaining,
            title: "What is left",
            body: "How much of each plan window you have used, and when it "
                + "resets. Plan usage is not a bill. A number with no date "
                + "is not shown."
        ),
        OnboardingPage(
            art: .workspaces,
            title: "Workspaces",
            body: "The folders you registered on the Mac. Browse the tree, "
                + "read a file, save an edit. Nothing happens that you did "
                + "not ask for."
        ),
        OnboardingPage(
            art: .sessions,
            title: "Sessions",
            body: "Live terminals on the host, from the desktop or from this "
                + "phone. Spawn an agent, watch it work, type when you need to."
        ),
        OnboardingPage(
            art: .onTheGo,
            title: "On the go",
            body: "This phone is a client of a Mac that is on. Folders and "
                + "sessions travel over an encrypted tunnel. Usage is already "
                + "on the account, so the heatmap does not need the laptop open."
        ),
        OnboardingPage(
            art: .privacy,
            title: "We never see your files",
            body: "The tunnel is end to end encrypted. We cannot read the "
                + "files you open or the terminals you type in. Counting "
                + "happens on your machine. Only aggregate totals you opt to "
                + "sync are eligible for the account."
        ),
        OnboardingPage(
            art: .control,
            title: "You are in control",
            body: "The account is private until you turn a profile on. Sync "
                + "is opt in. Remote reach is a switch you flip. Most of this "
                + "stays off until you ask."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
            TabView(selection: $page) {
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
                Button("Skip") { finish() }
                    .font(ClientType.label)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
    }

    /// How far through, as a bar. A bar scales to ten pages. Dots do not.
    private var progress: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent.opacity(0.16))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(page + 1) / CGFloat(Self.pages.count))
            }
        }
        .frame(height: 4)
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.s)
        .animation(.easeInOut(duration: 0.28), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            if page < Self.pages.count - 1 {
                Button("Continue") {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                }
                .clientProminentStyle()
            } else {
                // Get started only marks the intro done. Sign-in is a separate
                // choice on the next screen: opening the browser from here made
                // finishing the welcome feel like an auto-login.
                Button("Get started") { finish() }
                    .clientProminentStyle()
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
    let art: OnboardingArtKind
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
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Spacer(minLength: Theme.Space.l)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .combine)
    }
}

#endif
