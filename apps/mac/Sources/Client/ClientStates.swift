// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)
import UIKit

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
    var secondaryActionTitle: String?
    var secondaryActionIcon: ActionIcon = .preview
    var secondaryAction: (() -> Void)?

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
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, secondaryActionIcon, action: secondaryAction)
                    .labelStyle(ActionLabelStyle())
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
        .padding(.horizontal, Theme.Space.m)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// The first connection to another Mac needs a diagnosis, not a retry loop.
/// iOS and iPadOS cannot change the Mac's Remote Reach setting, so the two
/// Mac-side actions are visible and ordered here.
struct RemoteReachRecoveryCard: View {
    let name: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            // This is a setup state, not an alarm. Giving the animation its
            // own quiet stage makes the direction of the connection legible
            // before somebody has to read the instructions.
            ClientEmptyArt(kind: .remoteReach)
                .frame(width: 128, height: 84)
                .background(Theme.accentSoft.opacity(0.58), in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 5) {
                Text("Connect this Mac")
                    .font(ClientType.screenTitle)
                Text("\(name) is not ready for remote access yet.")
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Complete these steps on the Mac, then check again here.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                recoveryStep(
                    symbol: "laptopcomputer",
                    title: "Wake the Mac and open tokenstat",
                    detail: "The Mac must be awake while tokenstat is running."
                )
                recoveryStep(
                    symbol: "switch.2",
                    title: "Turn on Remote Reach on the Mac",
                    detail: "In tokenstat, open Devices and switch on “Reach devices from anywhere.”"
                )
            }

            Button("Check connection", .refresh, action: retry)
                .labelStyle(ActionLabelStyle())
                .clientProminentStyle()
                .controlSize(.large)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect \(name). On the Mac, wake it, open tokenstat, then turn on Reach devices from anywhere in Devices.")
    }

    private func recoveryStep(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ClientType.label.weight(.semibold))
                Text(detail)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The same state, on a machine nobody can walk over to.
///
/// `RemoteReachRecoveryCard` tells somebody to wake a Mac and flip a switch on
/// it. Neither instruction exists on a server: there is no window, the host is
/// a service, and the person can genuinely go and look. So this names the two
/// commands that answer it and offers the shell rather than a switch.
struct HeadlessReachRecoveryCard: View {
    let name: String
    let retry: () -> Void
    /// Opens an SSH session on that machine, when one can be opened from here.
    var openShell: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ClientEmptyArt(kind: .noMachine)
                .frame(width: 128, height: 84)
                .background(Theme.accentSoft.opacity(0.58), in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 5) {
                Text("\(name) is not answering")
                    .font(ClientType.screenTitle)
                    .multilineTextAlignment(.center)
                Text("Check that the server is running and connected to the internet, then check its tokenstat service.")
                    .font(ClientType.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                headlessStep(
                    symbol: "terminal",
                    title: "Ask the machine how it is",
                    detail: "`tokenstat host` says whether the service is running, which "
                        + "account it is on, and what the tunnel is doing."
                )
                headlessStep(
                    symbol: "text.alignleft",
                    title: "Read its log",
                    detail: "`tokenstat host logs` is the rest of the answer when the status "
                        + "line is not enough."
                )
            }

            VStack(spacing: Theme.Space.s) {
                Button("Check connection", .refresh, action: retry)
                    .labelStyle(ActionLabelStyle())
                    .clientProminentStyle()
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                if let openShell {
                    Button("Open a shell there", .connect, action: openShell)
                        .font(ClientType.label)
                        .tint(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(name) is not answering. On the machine, run tokenstat host for its status, "
            + "and tokenstat host logs to read its log."
        )
    }

    private func headlessStep(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ClientType.label.weight(.semibold))
                Text(detail)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
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
                    .font(Theme.font(18, weight: .regular))
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
/// nothing moves when the data lands. All bars start together on mobile: the
/// old per-row delays made one placeholder look like several animation layers.
/// The pulse remains `Skeleton.Bar`'s and still honours Reduce Motion.
enum ClientWireframe {
    /// The two totals at the top of Home.
    struct Totals: View {
        var body: some View {
            HStack(spacing: Theme.Space.s) {
                tile
                tile
            }
            .accessibilityHidden(true)
        }

        private var tile: some View {
            VStack(alignment: .leading, spacing: 6) {
                Skeleton.Bar(width: 54, height: 11)
                Skeleton.Bar(width: 96, height: 26)
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
                ForEach(0..<count, id: \.self) { _ in
                    HStack(spacing: Theme.Space.s) {
                        Skeleton.Bar(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 5) {
                            Skeleton.Bar(width: 130, height: 11)
                            Skeleton.Bar(width: 76, height: 9)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Skeleton.Bar(width: 48, height: 11)
                    }
                    .padding(Theme.Space.s)
                    .cardSurface()
                }
            }
            .accessibilityHidden(true)
        }
    }
}


/// This device has asked another computer to let it in, and is waiting.
///
/// Its own card rather than a line of caption, because it is the one state on
/// this screen where nothing at all will change until a person walks to
/// another machine. It says which machine, it says what to do there, and it
/// keeps a picture moving so it reads as pending rather than as failed.
struct ClientAwaitingAccessCard: View {
    let hostName: String
    var isHeadless: Bool = false
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ClientEmptyArt(kind: .workspaceAccess)
            Text("Waiting for \(hostName)")
                .font(ClientType.sectionTitle)
                .multilineTextAlignment(.center)
            Text("Open tokenstat on that computer and approve this device. The request is waiting in the sidebar and in Devices. This screen connects on its own once it is answered.")
                .font(ClientType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isHeadless {
                Text("No screen on that machine? Approve over SSH instead.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("How to approve", .help) {
                showHelp = true
            }
            .font(ClientType.label.weight(.semibold))
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.l)
        .cardSurface()
        .sheet(isPresented: $showHelp) {
            ClientAccessApprovalSheet(hostName: hostName, peerKey: "", isHeadless: isHeadless)
        }
    }
}

/// The numbered steps shared by the waiting card and the approval sheet.
///
/// One place so the card's inline help and the sheet cannot drift into two
/// different answers. Headless hosts get SSH commands; Macs with a screen get
/// the GUI path first and SSH as the fallback.
struct ClientAccessApprovalSteps: View {
    let hostName: String
    var isHeadless: Bool
    @State private var copied: String?

    private var approveCommand: String { "tokenstat host access approve" }
    private var inviteCommand: String { "tokenstat host access invite" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("How to approve")
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            if isHeadless {
                approvalStep(
                    symbol: "terminal",
                    step: "Step 1",
                    title: "SSH into \(hostName)",
                    detail: "Any shell on that machine works. The request is already waiting there."
                )
                commandRow(command: approveCommand, id: "approve")
                approvalStep(
                    symbol: "checkmark.seal",
                    step: "Step 2",
                    title: "Pick this device from the list",
                    detail: "The command numbers every pending request, so there is no key to paste."
                )
                approvalStep(
                    symbol: "link",
                    step: "Step 3",
                    title: "Come back here",
                    detail: "This screen connects on its own once the request is answered."
                )
                fallbackCard(
                    symbol: "key",
                    title: "No SSH either?",
                    detail: "Run the invite command on that machine, then enter the code via “I have a code”.",
                    command: inviteCommand,
                    commandId: "invite"
                )
            } else {
                approvalStep(
                    symbol: "laptopcomputer",
                    step: "Step 1",
                    title: "Open tokenstat on \(hostName)",
                    detail: "The request is waiting in the sidebar and in Devices."
                )
                approvalStep(
                    symbol: "checkmark.seal",
                    step: "Step 2",
                    title: "Approve this device",
                    detail: "This screen connects on its own once it is answered."
                )
                fallbackCard(
                    symbol: "terminal",
                    title: "Remote machine?",
                    detail: "SSH in and run the approve command, then pick this device.",
                    command: approveCommand,
                    commandId: "approve"
                )
            }
        }
    }

    private func approvalStep(symbol: String, step: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.accentSoft)
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(Theme.font(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.uppercased())
                    .font(ClientType.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(title).font(ClientType.label.weight(.semibold))
                Text(detail)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step). \(title). \(detail)")
    }

    private func commandRow(command: String, id: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(command)
                .font(Theme.monoText(13))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy", copied == id ? .done : .copy) {
                UIPasteboard.general.string = command
                copied = id
            }
            .font(ClientType.caption.weight(.semibold))
            .tint(Theme.accent)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run \(command) on \(hostName)")
    }

    /// The secondary path as its own card, so it never reads as small print
    /// under the real answer. Headless hosts offer the invite code; GUI hosts
    /// offer SSH as the fallback.
    private func fallbackCard(symbol: String, title: String, detail: String, command: String, commandId: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.font(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ClientType.label.weight(.semibold))
                    Text(detail)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.s) {
                Text(command)
                    .font(Theme.monoText(13))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copied == commandId ? "Copied" : "Copy", copied == commandId ? .done : .copy) {
                    UIPasteboard.general.string = command
                    copied = commandId
                }
                .font(ClientType.caption.weight(.semibold))
                .tint(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}

/// Request access, explained as a sheet rather than as small print.
///
/// The button used to fire the request and leave two captions underneath it,
/// which is why nobody could tell the SSH path from the code path. This asks
/// first, then shows where the request went and exactly what answers it on
/// the other machine, with copy buttons so no command is retyped.
struct ClientAccessApprovalSheet: View {
    let hostName: String
    /// Empty when the caller only wants the steps (the Workspaces waiting
    /// card already asked on connect). Non-empty enables Request again and
    /// the code-entry link.
    let peerKey: String
    var isHeadless: Bool
    var requestNotice: String?
    var isRequesting = false
    var onRequestAgain: (() -> Void)?
    var onGranted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var justAsked = false

    private var approveCommand: String { "tokenstat host access approve" }
    private var isRateLimited: Bool {
        (requestNotice ?? "").lowercased().contains("several times")
            || (requestNotice ?? "").lowercased().contains("wait an hour")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(spacing: Theme.Space.s) {
                        ClientEmptyArt(kind: .workspaceAccess)
                            .frame(maxWidth: .infinity)
                        Text("Waiting for approval")
                            .font(ClientType.screenTitle)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Text("Request sent to \(hostName). Approve it there and this screen will connect on its own.")
                            .font(ClientType.label)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 6) {
                            if isRequesting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: isRateLimited ? "hourglass" : "paperplane")
                                    .foregroundStyle(Theme.accent)
                            }
                            Text(isRequesting ? "Asking…" : (isRateLimited ? "Asked. Waiting out the limit" : "Request is waiting on that computer"))
                                .font(ClientType.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.accentSoft.opacity(0.6), in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    if let requestNotice, !requestNotice.isEmpty {
                        Text(requestNotice)
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if justAsked {
                        Text("Asked. Approve this device on \(hostName).")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ClientAccessApprovalSteps(hostName: hostName, isHeadless: isHeadless)
                    if !peerKey.isEmpty {
                        NavigationLink {
                            ClientAddThisDevice(peer: peerKey, hostName: hostName) {
                                onGranted?()
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: Theme.Space.m) {
                                ActionSeat(icon: .pair, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("I have a code")
                                        .font(ClientType.label.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Enter an invite code from that machine instead.")
                                        .font(ClientType.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(Theme.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(Theme.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Space.m)
            }
            .background(Theme.background)
            .navigationTitle("Approve this device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", .dismiss) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Theme.Space.s) {
                    Button(copied ? "Copied" : "Copy approve command", copied ? .done : .copy) {
                        UIPasteboard.general.string = approveCommand
                        copied = true
                    }
                    .labelStyle(ActionLabelStyle())
                    .clientProminentStyle()
                    .controlSize(.large)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    if onRequestAgain != nil {
                        Button(isRequesting ? "Asking…" : "Request again", .refresh) {
                            justAsked = true
                            onRequestAgain?()
                        }
                        .font(ClientType.label)
                        .tint(Theme.accent)
                        .disabled(isRequesting)
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.background)
            }
        }
    }
}

#endif
