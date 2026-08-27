// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// The first thing Home shows on a machine that has never scanned.
///
/// What was there instead was one grey sentence pointing at the name of
/// another screen, which is the worst version of an empty state: it knows what
/// to do and makes you go and find it.
///
/// Three steps, and **the first one arrives done**. Installing is behind you:
/// you are looking at the app. A rail that opens a third finished reads as
/// progress rather than as a list of chores, and it is also simply true.
///
/// Scanning is step two because it is the one that puts something on this
/// screen. Signing in is step three and it is not a wall: the Mac reads the
/// local archive with no account at all, so the card says what an account buys
/// (these numbers on your phone, and a second computer) rather than implying
/// nothing works until you have one.
struct GettingStartedCard: View {
    /// Whether the account is connected. Not a gate on anything, just which
    /// step of the rail is live.
    let signedIn: Bool
    /// True while the first scan is running, so the step it belongs to says so
    /// rather than offering to start a second one.
    let isScanning: Bool
    /// True while `InsightsModel` is inside its post-scan cooldown, where
    /// `scan()` returns immediately. The button has to go with it: a scan that
    /// found nothing leaves this card on screen, and pressing a live button
    /// that silently does nothing is worse than having no button for ten
    /// seconds.
    let isCoolingDown: Bool
    let onSignIn: () -> Void
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            GettingStartedRail(steps: steps)
            waiting
        }
        .padding(Theme.Space.l)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
        }
    }

    /// Whether pressing Scan now would actually start one.
    private var canScan: Bool { !isScanning && !isCoolingDown }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                FeatureMark(name: "mark_activity", tint: Theme.accent, size: 26)
                Text("Get tokenstat counting")
                    .font(Theme.title3.weight(.semibold))
            }
            Text("It reads the logs the tools you already use leave on this Mac, and turns them into a year you can read.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: [GettingStartedStep] {
        [
            GettingStartedStep(
                number: 1,
                title: "Installed",
                body: "You are looking at it. Nothing else to put on this Mac.",
                state: .done
            ),
            // Scanning before signing in, because scanning is the step that
            // puts something on this screen and an account is not required for
            // it. A rail that asks for a sign-in first would be telling a
            // small lie about what the app needs.
            GettingStartedStep(
                number: 2,
                title: isScanning ? "Scanning" : "Run the first scan",
                body: isScanning
                    ? "Reading what is already on disk. The grid below fills in as it goes."
                    : isCoolingDown
                        ? "That scan found nothing new. Give it a moment before trying again."
                        : "It reads what is already on disk, so the first grid covers the work you have done, not the work you do next.",
                state: .now,
                actionTitle: canScan ? "Scan now" : nil,
                actionIcon: .refresh,
                action: canScan ? onScan : nil
            ),
            GettingStartedStep(
                number: 3,
                title: signedIn ? "Connected to your account" : "Add your phone, if you want it",
                body: signedIn
                    ? "Your devices share one account, so the phone shows these numbers with the lid shut."
                    : "Optional, and this Mac counts either way. An account is what puts these numbers on your phone and lets a second computer join. Free includes two devices.",
                state: signedIn ? .done : .next,
                actionTitle: signedIn ? nil : "Sign in",
                actionIcon: .signIn,
                action: signedIn ? nil : onSignIn
            ),
        ]
    }

    /// The shape of the answer, where the answer will be.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Divider().overlay(Theme.border)
            Text("Then the year fills in")
                .font(Theme.headline)
            GettingStartedGhostGrid(weeks: 30)
        }
        .padding(.top, Theme.Space.xs)
    }
}
