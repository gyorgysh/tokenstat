// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import SwiftUI

/// A failure, said in a way somebody can act on.
///
/// Errors arrive here as sentences written for a log: "connection refused (os
/// error 61)", "the relay rejected this machine's tunnel credential". Those are
/// the right words in `hostd.err.log` and the wrong words on a screen, and the
/// screen is where people meet them.
///
/// One table, shared by the Mac and the client, so the same failure cannot be
/// explained two ways in one product. The raw text is kept: a person who wants
/// the original can still see it, and a support conversation is impossible
/// without it. What changes is what leads.
struct FriendlyError {
    /// Four words at most. What went wrong, not what the code was doing.
    var title: String
    /// One or two sentences: what this means, and what fixes it.
    var message: String
    /// SF Symbol for the state. Chosen per cause, because a wall of identical
    /// warning triangles teaches people to stop reading them.
    var symbol: String
    /// What the button says, when pressing something can help.
    var actionTitle: String?
    /// The original text, for the detail line.
    var raw: String
    /// The button should open plans, not retry. iOS uses the in-app paywall.
    var opensPlans: Bool = false

    /// The glyph on that button, from the shared action vocabulary: a crown
    /// when it leads to plans, the retry arrow when it retries.
    var actionIcon: ActionIcon { opensPlans ? .plans : .refresh }

    /// Whether this is something the user can fix now, as opposed to something
    /// that has to be waited out.
    var isActionable: Bool { actionTitle != nil }

    // Matching is on substrings of the message rather than typed errors on
    // purpose: these strings cross a JSON boundary from Rust, where they are
    // deliberately human sentences and not a code enum. A new phrasing that
    // falls through lands in the default, which is honest, rather than being
    // mapped to the wrong advice.
    static func from(_ text: String) -> FriendlyError {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        if lower.contains("not approved") || lower.contains("waiting for someone to allow") {
            return FriendlyError(
                title: "Waiting for approval",
                message: "The other device has to say yes to this one. Open Devices there and "
                    + "approve it, then try again.",
                symbol: "hand.raised",
                actionTitle: "Try again",
                raw: raw
            )
        }
        if lower.contains("paid-plan") || lower.contains("not_on_this_plan")
            || lower.contains("no longer includes remote")
        {
            return FriendlyError(
                title: "Not on this plan",
                message: "Reaching your devices from anywhere is part of a paid plan. Everything "
                    + "else keeps working exactly as it does now.",
                symbol: "star.circle",
                actionTitle: "See plans",
                raw: raw,
                opensPlans: true
            )
        }
        // Before the sign-in case, and deliberately: a refused tunnel
        // credential repairs itself, and its sentence used to contain the
        // words "sign in again", which sent people to fix something that was
        // already being fixed.
        let wantsSignIn = lower.contains("sign in") || lower.contains("signed out")
            || lower.contains("not logged in")
            || (lower.contains("token") && lower.contains("revoked"))
        if wantsSignIn
            && (lower.contains("could not be minted")
                || lower.contains("paid-plan")
                || lower.contains("device limit"))
        {
            return FriendlyError(
                title: "Sign in again",
                message: "This device's login is no longer valid. Signing in again puts it back, "
                    + "and nothing local is lost.",
                symbol: "person.crop.circle.badge.exclamationmark",
                actionTitle: "Sign in",
                raw: raw
            )
        }
        if lower.contains("credential") || lower.contains("tunnel token")
            || lower.contains("key does not match")
        {
            return FriendlyError(
                title: "Reconnecting",
                message: "The connection credential was refused, so this device is getting a new "
                    + "one. It usually comes back on its own within a minute.",
                symbol: "arrow.triangle.2.circlepath",
                actionTitle: "Retry now",
                raw: raw
            )
        }
        if lower.contains("sign in") || lower.contains("signed out")
            || lower.contains("not logged in") || lower.contains("token") && lower.contains("revoked")
        {
            return FriendlyError(
                title: "Sign in again",
                message: "This device's login is no longer valid. Signing in again puts it back, "
                    + "and nothing local is lost.",
                symbol: "person.crop.circle.badge.exclamationmark",
                actionTitle: "Sign in",
                raw: raw
            )
        }
        if lower.contains("already on the tunnel") || lower.contains("key_already_live") {
            return FriendlyError(
                title: "Connected somewhere else",
                message: "Another copy of tokenstat is on the tunnel with this device's key. "
                    + "Quit it, or wait a moment for it to drop.",
                symbol: "person.2.slash",
                raw: raw
            )
        }
        if lower.contains("offline") || lower.contains("no internet")
            || lower.contains("network is unreachable") || lower.contains("dns")
            || lower.contains("could not resolve")
        {
            return FriendlyError(
                title: "No connection",
                message: "This device cannot reach the network right now. It retries by itself as "
                    + "soon as it can.",
                symbol: "wifi.slash",
                actionTitle: "Try again",
                raw: raw
            )
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return FriendlyError(
                title: "It did not answer",
                message: "The other side took too long. It is usually asleep rather than broken.",
                symbol: "clock.badge.exclamationmark",
                actionTitle: "Try again",
                raw: raw
            )
        }
        if lower.contains("this mac is asleep") || lower.contains("host_asleep") {
            return FriendlyError(
                title: "This Mac is asleep",
                message: "That Mac has its lid closed, or tokenstat is not open. Open the app, "
                    + "open the lid, or turn on Always-on host in Account to keep it reachable.",
                symbol: "moon.zzz",
                actionTitle: "Try again",
                raw: raw
            )
        }
        if lower.contains("connection refused") || lower.contains("os error 61")
            || lower.contains("no such file or directory") && lower.contains("sock")
            || lower.contains("host daemon") || lower.contains("hostd")
        {
            return FriendlyError(
                title: "The helper is not running",
                message: "tokenstat's background helper handles your archive and your devices. "
                    + "Open the app to start it, or turn on Always-on host to keep it running "
                    + "after you quit or close the lid.",
                symbol: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                actionTitle: "Start it",
                raw: raw
            )
        }
        if lower.contains("broken pipe") || lower.contains("connection reset")
            || lower.contains("disconnected")
        {
            return FriendlyError(
                title: "Connection dropped",
                message: "The link to the other device closed. It reconnects on its own.",
                symbol: "bolt.horizontal.circle",
                actionTitle: "Try again",
                raw: raw
            )
        }
        if lower.contains("too many requests") || lower.contains("rate limit")
            || lower.contains("429")
        {
            return FriendlyError(
                title: "Asked too often",
                message: "The account is answering fewer requests for a moment. What is on screen "
                    + "is still good, and the next refresh will go through.",
                symbol: "hourglass",
                raw: raw
            )
        }
        if lower.contains("device limit") || lower.contains("machine_limit") {
            return FriendlyError(
                title: "Device limit reached",
                message: "This account is using all the devices its plan allows. Remove one you no "
                    + "longer have, or move up a plan.",
                symbol: "laptopcomputer.slash",
                actionTitle: "Manage devices",
                raw: raw
            )
        }

        // Nothing matched. Say that something failed and show the words the
        // machine used, rather than inventing a cause.
        return FriendlyError(
            title: "That did not work",
            message: raw.isEmpty ? "Something went wrong and nothing said what." : raw,
            symbol: "exclamationmark.triangle",
            actionTitle: "Try again",
            raw: raw
        )
    }
}

/// A failure at the top of a screen, in the app's own voice.
///
/// `Banner` says one line in one colour, which is right for "your plan
/// changed" and wrong for everything that went wrong: the sentence it was
/// given was usually a transport error. This keeps the banner's shape and
/// gives the cause a name, a symbol of its own, the fix, and the raw text
/// behind a disclosure for whoever needs it.
struct ErrorBanner: View {
    var message: String
    /// Offered as the banner's button when the caller has something to retry.
    var retry: (() -> Void)?
    @State private var showingDetail = false

    var body: some View {
        let error = FriendlyError.from(message)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: error.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.callout.weight(.semibold))
                    Text(error.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                if let retry, let actionTitle = error.actionTitle {
                    Button(actionTitle, error.actionIcon, action: retry)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            if error.raw != error.message, !error.raw.isEmpty {
                DisclosureGroup(isExpanded: $showingDetail) {
                    Text(error.raw)
                        .font(Theme.mono(11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius)
        )
    }
}
