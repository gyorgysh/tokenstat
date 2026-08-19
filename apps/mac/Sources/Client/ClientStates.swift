// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// What a screen shows when it has no content, and why the three cases are
/// three cases.
///
/// **Empty, unreachable and refused are not the same thing**, and rendering
/// them the same is the mistake `limits.rs` already argues against for quota
/// readings: "no data" and "we could not look" must never read alike. A quiet
/// day is an answer. A host that is down is a problem. An account that does not
/// include this is a decision somebody can act on, and it is the only one of
/// the three that gets a button.
enum ClientEmptyKind {
    /// The answer arrived and it was nothing.
    case nothingYet
    /// We could not get an answer.
    case unreachable
    /// The answer is no, and signing in or upgrading is the fix.
    case needsAccount

    var symbol: String {
        switch self {
        case .nothingYet: return "tray"
        case .unreachable: return "antenna.radiowaves.left.and.right.slash"
        case .needsAccount: return "person.crop.circle.badge.plus"
        }
    }

    var mark: String {
        switch self {
        case .nothingYet: return "mark_activity"
        case .unreachable: return "mark_sync"
        case .needsAccount: return "mark_account"
        }
    }
}

/// One card for all three cases above. One component so they cannot drift into
/// three different tones of voice.
struct ClientEmptyState: View {
    let kind: ClientEmptyKind
    let title: String
    /// One sentence. If it needs two, the screen is explaining something that
    /// belongs elsewhere.
    var message: String?
    /// Shown only when there is something the person can actually do.
    var actionTitle: String?
    /// The glyph on that action. Callers that retry or open plans must pass
    /// `.refresh` or `.plans`. The default is only for forward navigation.
    var actionIcon: ActionIcon = .next
    var action: (() -> Void)?
    /// Override the kind's default mark when the empty state is about a
    /// specific surface (devices, workspaces) rather than activity.
    var mark: String?
    /// A drawn scene instead of the mark, for the screens where "nothing here"
    /// is worth a picture of the thing that is missing. See `ClientEmptyArt`.
    var art: EmptyArtKind?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let art {
                ClientEmptyArt(kind: art)
                    .padding(.bottom, 2)
            } else {
                FeatureMark(
                    name: mark ?? kind.mark,
                    tint: kind == .unreachable ? Color.secondary : Theme.accent,
                    size: 30
                )
            }
            Text(title)
                .font(ClientType.screenTitle)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                // The glyph is spelled out, like every other prominent button
                // in the client. Left to the system's own label style inside
                // a glass button it disappeared, and the empty state was the
                // one screen offering a bare capsule with no mark on it.
                Button(actionTitle, actionIcon, action: action)
                    .labelStyle(ActionLabelStyle())
                    .clientProminentStyle()
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
        .padding(.horizontal, Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A failure, drawn like part of the app rather than like a crash log.
///
/// One component for every error surface in the client, so a device that is
/// asleep, a plan that does not include something and a helper that is not
/// running are told apart by their icon and their sentence rather than by
/// three shades of the same red paragraph. The machine's own words stay one
/// tap away: they are useless to most people and the only useful thing to
/// somebody reporting a bug.
struct ClientErrorCard: View {
    let message: String
    /// Shown as the card's action when the caller has something to retry.
    var retry: (() -> Void)?
    @State private var showingDetail = false

    /// Optional on purpose. Every screen inside the client has this, and a
    /// card drawn somewhere that does not simply keeps the sentence it was
    /// given rather than crashing over a missing model.
    @Environment(ConnectivityModel.self) private var connectivity: ConnectivityModel?

    private var friendly: FriendlyError { FriendlyError.from(message) }

    /// Offline rewrites the card, whatever the call happened to say.
    ///
    /// A device with no internet produces a different sentence per subsystem:
    /// a timeout here, a refused socket there, a tunnel that cannot pair. All
    /// of them have one cause and one answer, and a Retry that cannot work is
    /// worse than no button. This is also what keeps a screen from
    /// contradicting the chip in the top bar.
    private var isOffline: Bool { connectivity?.isOffline ?? false }

    private var offlineError: FriendlyError {
        FriendlyError(
            title: "You are offline",
            message: "This device cannot reach the internet. It retries every "
                + "\(Int(ConnectivityModel.retryInterval.components.seconds)) seconds, and "
                + "everything comes back on its own.",
            symbol: "wifi.slash",
            actionTitle: nil,
            raw: message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var body: some View {
        let error = isOffline ? offlineError : friendly
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: error.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(ClientType.label.weight(.semibold))
                    Text(error.message)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.m) {
                if error.opensPlans {
                    Button(error.actionTitle ?? "See plans", .plans) {
                        NotificationCenter.default.post(name: .tokenstatOpenPaywall, object: nil)
                    }
                    .font(ClientType.caption.weight(.semibold))
                    .tint(Theme.accent)
                } else if let retry, let actionTitle = error.actionTitle {
                    Button(actionTitle, error.actionIcon, action: retry)
                        .font(ClientType.caption.weight(.semibold))
                        .tint(Theme.accent)
                }
                if error.raw != error.message, !error.raw.isEmpty {
                    Button(showingDetail ? "Hide details" : "Details") {
                        showingDetail.toggle()
                    }
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if showingDetail {
                Text(error.raw)
                    .font(ClientType.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(error.title). \(error.message)")
    }
}

/// A wireframe shaped like the content that is coming.
///
/// Shaped, not generic: a placeholder whose layout matches the real thing means
/// nothing moves when the data lands. The pulse is `Skeleton.Bar`'s, which is
/// the Mac's, deterministic rather than random and still under Reduce Motion,
/// so somebody using both apps does not meet two of them.
enum ClientWireframe {
    /// The two totals at the top of Home.
    struct Totals: View {
        var body: some View {
            HStack(spacing: Theme.Space.s) {
                tile(phase: 0)
                tile(phase: 0.12)
            }
            .accessibilityHidden(true)
        }

        private func tile(phase: Double) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Skeleton.Bar(width: 54, height: 11, phase: phase)
                Skeleton.Bar(width: 96, height: 26, phase: phase + 0.06)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
            .cardSurface()
        }
    }

    /// The year of squares, at the height the real grid will occupy, so the
    /// card does not resize under the reader when it arrives.
    struct Heatmap: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Skeleton.Bar(width: 84, height: 13)
                Skeleton.Bar(width: nil, height: 122)
            }
            .padding(Theme.Space.m)
            .cardSurface()
            .accessibilityHidden(true)
        }
    }

    /// A list of rows: a mark, two lines of text, a figure.
    struct Rows: View {
        var count = 3

        var body: some View {
            VStack(spacing: Theme.Space.s) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(spacing: Theme.Space.s) {
                        Skeleton.Bar(width: 26, height: 26, phase: Double(index) * 0.1)
                        VStack(alignment: .leading, spacing: 5) {
                            Skeleton.Bar(width: 130, height: 11, phase: Double(index) * 0.1)
                            Skeleton.Bar(width: 76, height: 9, phase: Double(index) * 0.1 + 0.05)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Skeleton.Bar(width: 48, height: 11, phase: Double(index) * 0.1)
                    }
                    .padding(Theme.Space.s)
                    .cardSurface()
                }
            }
            .accessibilityHidden(true)
        }
    }
}

#endif
