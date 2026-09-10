// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Which release a machine is on, and the one button that moves it.
///
/// Peer set: that computer. `local` set: this one. A server has no application
/// to update and nobody sitting at it, so this is the only place its release
/// can be moved from, which is why it is a card on the machine rather than a
/// line in a settings screen.
///
/// One check, not a poll. The readings bar beside this samples every couple of
/// seconds because power and load change that fast; a published release does
/// not, and asking GitHub on a timer for a number that changes weekly would be
/// somebody else's bandwidth spent on nothing.
struct HostUpdateCard: View {
    var peer: String? = nil
    var local: Bool = false

    @State private var phase: Phase = .checking
    @State private var state: HostUpdateState?
    @State private var applied: HostUpdateResult?
    @State private var supported = true
    @State private var retry = 0

    /// What this card is doing, rather than several booleans that can disagree.
    private enum Phase: Equatable {
        case checking
        case ready
        case installing
        case done
        case failed(String)
    }

    private var target: String? {
        guard let peer, !peer.isEmpty else { return nil }
        return peer
    }

    var body: some View {
        Group {
            if supported, local || target != nil {
                card
            }
        }
        .task(id: "\(peer ?? "local")-\(local)-\(retry)") {
            await load()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            status(for: phase)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .machineCardSurface()
    }

    private var header: some View {
        Text("Software")
            .font(titleFont)
            .accessibilityAddTraits(.isHeader)
    }

    /// The platforms name their own type. `ClientType` is iOS only.
    private var titleFont: Font {
        #if os(macOS)
        return Theme.font(13, weight: .semibold)
        #else
        return ClientType.sectionTitle
        #endif
    }

    private var figureFont: Font {
        #if os(macOS)
        return Theme.numeric(12, weight: .semibold)
        #else
        return ClientType.rowFigure
        #endif
    }

    @ViewBuilder
    private func status(for phase: Phase) -> some View {
        switch phase {
        case .checking:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Looking for a newer release")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            readyBody
        case .installing:
            HStack(spacing: Theme.Space.s) {
                ProgressView().controlSize(.small)
                Text("Downloading, checking and installing. This takes a minute.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done:
            doneBody
        case let .failed(reason):
            Text(reason)
                .font(Theme.caption)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var readyBody: some View {
        if let state {
            VStack(alignment: .leading, spacing: 4) {
                versionLine(state)
                if state.restartPending {
                    // Installed but not in use. Saying "up to date" here would
                    // name a version the running process does not have.
                    note(pendingSentence(state), tone: .waiting)
                } else if state.newer {
                    note("Version \(state.latest) is available.", tone: .available)
                } else {
                    note("Up to date.", tone: .plain)
                }
                // Additive, not instead of the line above: an
                // application-managed helper that is current should still say
                // so, and one that is behind should say both things.
                if state.appManaged {
                    note(
                        local
                            ? "The tokenstat application owns this helper and replaces it when it updates itself."
                            : "The tokenstat application there owns its helper and replaces it when it updates itself.",
                        tone: .plain
                    )
                } else {
                    if state.newer, !state.canRestart {
                        note(
                            "It installs but cannot restart itself, so it keeps running the version it started with until it is restarted.",
                            tone: .waiting
                        )
                    }
                    if state.autoApply {
                        note("Checks daily on its own.", tone: .plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var doneBody: some View {
        if let applied {
            VStack(alignment: .leading, spacing: 4) {
                if let detail = applied.detail {
                    Text(detail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if applied.restarting == true {
                    note(
                        "Installed \(applied.to ?? "the new version"). Restarting on it now, so this may go quiet for a moment.",
                        tone: .available
                    )
                } else if let image = applied.appImage, !image.isEmpty, applied.appManaged == true {
                    note("The application's download is ready on that machine.", tone: .available)
                } else {
                    note(installedWaitingSentence(applied), tone: .waiting)
                }
            }
        }
    }

    /// Two versions on one line, because the pair is the fact.
    private func versionLine(_ state: HostUpdateState) -> some View {
        HStack(spacing: 6) {
            Text(state.restartPending ? "Running \(state.hostVersion)" : state.hostVersion)
                .font(figureFont)
                .monospacedDigit()
            if state.newer, !state.restartPending {
                Image(systemName: "arrow.right")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(state.latest)
                    .font(figureFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            state.newer
                ? "Version \(state.hostVersion), \(state.latest) available"
                : "Version \(state.hostVersion), up to date"
        )
    }

    @ViewBuilder
    private var actions: some View {
        if let state, phase != .installing, phase != .checking {
            HStack(spacing: Theme.Space.s) {
                // `state` is the answer from before an install, so after one it
                // still names a newer version. Offering Install again there
                // would be offering work that is already done.
                if phase == .done {
                    if applied?.restartPending == true, state.canRestart {
                        Button(restartTitle, .refresh) { Task { await apply(restartNow: true) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                } else if state.restartPending {
                    // The only thing left is the restart, and it ends whatever
                    // that machine is running, so it is never automatic here.
                    if state.canRestart {
                        Button(restartTitle, .refresh) { Task { await apply(restartNow: true) } }
                            .buttonStyle(AccentButtonStyle())
                    }
                } else if state.newer, !state.appManaged {
                    Button("Install \(state.latest)", .download) { Task { await apply(restartNow: false) } }
                        .buttonStyle(AccentButtonStyle())
                } else if state.appManaged, state.newer {
                    Button(fetchTitle, .download) { Task { await apply(restartNow: false) } }
                        .buttonStyle(AccentButtonStyle())
                }
                Button("Check again", .refresh) { retry &+= 1 }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var restartTitle: String {
        local ? "Restart the helper" : "Restart it there"
    }

    private var fetchTitle: String {
        local ? "Download it" : "Fetch it there"
    }

    /// Where a restart has to happen, in the words that fit the machine being
    /// looked at.
    private var restartElsewhere: String {
        local ? "Restart the helper to use it." : "Restart it there to use it."
    }

    /// How this card colours a sentence. Three tones, so a waiting state does
    /// not read as a failure and an available one does not read as done.
    private enum Tone {
        case plain
        case available
        case waiting
    }

    private func note(_ text: String, tone: Tone) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(colour(for: tone))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func colour(for tone: Tone) -> Color {
        switch tone {
        case .plain: return .secondary
        case .available: return Theme.accent
        case .waiting: return Theme.warning
        }
    }

    private func pendingSentence(_ state: HostUpdateState) -> String {
        let installed = "Version \(state.latest) is installed and waiting."
        guard state.canRestart else {
            return "\(installed) \(restartElsewhere)"
        }
        return state.liveWork > 0
            ? "\(installed) \(workPhrase(state.liveWork)) running, so it restarts when they finish."
            : "\(installed) It restarts on its own shortly."
    }

    private func installedWaitingSentence(_ applied: HostUpdateResult) -> String {
        let version = applied.to ?? "The new version"
        let live = applied.liveWork ?? 0
        if applied.canRestart == false {
            return "Installed \(version). \(restartElsewhere)"
        }
        return live > 0
            ? "Installed \(version). \(workPhrase(live)) running, so it restarts when they finish."
            : "Installed \(version). It restarts shortly."
    }

    /// Counted rather than "some work": a person deciding whether to end their
    /// own sessions wants the number.
    private func workPhrase(_ count: Int) -> String {
        count == 1 ? "One thing is" : "\(count) things are"
    }

    private func load() async {
        phase = .checking
        applied = nil
        // A host older than these methods must not be discovered by showing
        // somebody its `unknown method` error.
        if !local, let target {
            supported = await RemoteHostFeature.hostUpdate.isSupported(peer: target)
            guard supported else { return }
        }
        guard local || target != nil else { return }
        do {
            let answer = local || target == nil
                ? try await Bridge.hostUpdateCheck()
                : try await Bridge.hostUpdateCheck(peer: target ?? "")
            guard !Task.isCancelled else { return }
            state = answer
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(FriendlyError.from(error.localizedDescription).message)
        }
    }

    private func apply(restartNow: Bool) async {
        phase = .installing
        do {
            let result = local || target == nil
                ? try await Bridge.hostUpdateApply(restartNow: restartNow)
                : try await Bridge.hostUpdateApply(peer: target ?? "", restartNow: restartNow)
            guard !Task.isCancelled else { return }
            applied = result
            phase = .done
        } catch {
            guard !Task.isCancelled else { return }
            // A restart the caller asked for takes the connection with it, and
            // that is the update working. Saying it failed would be wrong, and
            // would invite a second attempt at something already done.
            if restartNow {
                applied = HostUpdateResult(restarting: true)
                phase = .done
                return
            }
            phase = .failed(FriendlyError.from(error.localizedDescription).message)
        }
    }
}
