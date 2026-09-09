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
/// Six short pages explain the work first, then the machine that holds it,
/// the numbers, and the privacy boundary. Sign-in stays a deliberate next step.
///
/// Shown once. `hasOnboarded` is `@AppStorage`, so the second launch goes
/// straight to the sign-in card, and a signed-in phone never sees this at all.
struct ClientOnboarding: View {
    @AppStorage("client.hasOnboarded") private var hasOnboarded = false

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            art: .intro,
            topic: "Welcome",
            title: "Your coding agents,\nwithin reach.",
            body: "Run coding agents on your computer or a server. Pick up the "
                + "conversation, work on your projects, and see your AI usage "
                + "from your iPhone or iPad."
        ),
        OnboardingPage(
            art: .agents,
            topic: "Agents",
            title: "Keep the conversation going",
            body: "Give an agent a task, follow its progress, and reply when it "
                + "needs you. Return to the same chat later, or open a live "
                + "terminal when you want to work directly."
        ),
        OnboardingPage(
            art: .workspaces,
            topic: "Projects",
            title: "Go from the chat\nto the code",
            body: "Open a folder or clone a repository. Read and edit files, "
                + "review changes, and keep tasks beside the code. Your "
                + "projects stay on the machine that runs them."
        ),
        OnboardingPage(
            art: .onTheGo,
            topic: "Machines",
            title: "Choose where the work runs",
            body: "Use a computer you own or a cloud server. Connect it from "
                + "this device, with guided setup for a server. That machine "
                + "needs to be awake while you work; your iPhone or iPad is "
                + "how you reach it."
        ),
        OnboardingPage(
            art: .heatmap,
            topic: "Usage",
            title: "Know where the tokens go",
            body: "See activity and estimated cost by tool, model, and project, "
                + "plus supported plans’ usage and reset times. Synced numbers "
                + "stay available with every computer asleep. Plan usage is "
                + "shown separately from cost."
        ),
        OnboardingPage(
            art: .privacy,
            topic: "Privacy",
            title: "Your machines.\nYour say.",
            body: "Remote work travels over an end-to-end encrypted connection. "
                + "You choose which devices can open your work and which usage "
                + "totals to sync. Your account stays private unless you turn "
                + "on a public profile."
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

    /// Named steps and a finite rail make the length clear before the first swipe.
    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(Self.pages[page].topic)
                    .font(ClientType.label.weight(.semibold))
                Spacer()
                Text("\(page + 1) of \(Self.pages.count)")
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
        .accessibilityLabel("\(Self.pages[page].topic), page \(page + 1) of \(Self.pages.count)")
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.m) {
            if page == Self.pages.count - 1 {
                Text("Next, sign in. You can connect a machine whenever you are ready.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Theme.Space.s))
                : AnyLayout(HStackLayout(spacing: Theme.Space.m))
            layout {
                if page > 0 {
                    Button("Back", .back) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page -= 1 }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("intro.back")
                }
                Button {
                    if page == Self.pages.count - 1 {
                        finish()
                    } else {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page += 1 }
                    }
                } label: {
                    ActionIcon.next.label(page == Self.pages.count - 1 ? "Get started" : "Continue")
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
