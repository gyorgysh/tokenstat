// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

/// A feature a newer client can show only when the paired computer speaks the
/// host methods behind it.
///
/// Keep the version beside the feature rather than testing for an error after
/// loading it. `protocol` is present before either feature and gives a person a
/// useful update state instead of exposing an implementation error.
enum RemoteHostFeature: Hashable {
    case chat
    case pulls
    case modelRefresh
    case folderPicker
    case cloneRepository
    case provisioning
    case inviteCode
    case agentSignIn
    case confirmedSend
    case handoff
    case workSearch
    case hostUpdate
    case selectedCommit
    case reviewedPush
    case taskEditing
    case taskDeletion
    case taskCreation
    case taskExecution
    case automationReceipts
    case workflowEditing

    var title: String {
        switch self {
        case .chat: "Chat"
        case .pulls: "Pull requests"
        case .modelRefresh: "Model list refresh"
        case .folderPicker: "Choosing a folder"
        case .cloneRepository: "Cloning a repository"
        case .provisioning: "Setup"
        case .inviteCode: "Adding this device"
        case .agentSignIn: "Signing in to an agent"
        case .confirmedSend: "Confirming a sent message"
        case .handoff: "Handoff"
        case .workSearch: "Search work"
        case .hostUpdate: "Updating this computer"
        case .selectedCommit: "Committing selected files"
        case .reviewedPush: "Pushing a branch"
        case .taskEditing: "Editing tasks"
        case .taskDeletion: "Deleting tasks"
        case .taskCreation: "Creating tasks"
        case .taskExecution: "Running tasks"
        case .automationReceipts: "Saving automations"
        case .workflowEditing: "Saving workflows"
        }
    }

    /// Version 3 introduced the pull-request host methods. Version 4 added
    /// `chat.eventPage`, which the mobile transcript needs for older pages.
    /// Version 6 added the `refresh` parameter on `chat.backends`. Version 7
    /// added `fs.browse` and `fs.mkdir`, `host.provisionStatus` and
    /// `host.logs`, the invite half of workspace access, and `workspace.clone`.
    /// Version 9 added agent readiness on `launcher.catalog` and the
    /// `launcher.signIn` terminal handoff. Version 10 added `clientMessageId`
    /// on `chat.send` and `chat.receipt`, which is what makes repeating a send
    /// safe: an older machine ignores the id, so a message must never be sent
    /// to one twice.
    /// Version 11 adds explicitly shared continuation records with revision checks.
    /// Version 12 adds authorized live work search and durable transcript
    /// positions. Handoff needs those positions to survive history retention.
    /// Version 13 hardens receipts with recovery states, and version 14 adds
    /// the send revision: a host below 14 refuses an id without the revision
    /// the client only sends beside it, so confirmed send needs all of 14.
    /// Version 15 adds reviewed selected-file commits and outcome recovery.
    /// Version 16 adds reviewed current-branch Push and outcome recovery.
    /// Version 17 adds revision-checked task editing.
    /// Version 18 adds checked task deletion. Version 19 adds create-once tasks.
    /// Version 20 adds checked task runs, exact-run stops and launch receipts.
    /// Version 21 adds revision-checked automation edits and create/run receipts.
    /// Version 22 adds revision-checked workflow edits.
    var minimumProtocol: Int {
        switch self {
        case .chat: 4
        case .pulls: 3
        case .modelRefresh: 6
        case .folderPicker: 7
        case .cloneRepository: 7
        case .provisioning: 7
        case .inviteCode: 7
        case .agentSignIn: 9
        case .confirmedSend: 14
        case .handoff: 12
        case .workSearch: 12
        // Added inside 14, before any host spoke it. The released hosts are
        // on 6, so "says 14" and "has this" are the same statement and there
        // was nothing to bump.
        case .hostUpdate: 14
        case .selectedCommit: 15
        case .reviewedPush: 16
        case .taskEditing: 17
        case .taskDeletion: 18
        case .taskCreation: 19
        case .taskExecution: 20
        case .automationReceipts: 21
        case .workflowEditing: 22
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .pulls: "arrow.triangle.merge"
        case .modelRefresh: "arrow.clockwise"
        case .folderPicker: "folder.badge.plus"
        case .cloneRepository: "arrow.down.doc"
        case .provisioning: "sparkles"
        case .inviteCode: "key.horizontal.fill"
        case .agentSignIn: "person.badge.key.fill"
        case .confirmedSend: "checkmark.message.fill"
        case .handoff: "arrow.left.arrow.right"
        case .workSearch: "magnifyingglass"
        case .hostUpdate: "arrow.down.circle"
        case .selectedCommit: "checkmark.circle"
        case .reviewedPush: "arrow.up.circle"
        case .taskEditing: "pencil"
        case .taskDeletion: "trash"
        case .taskCreation: "plus"
        case .taskExecution: "play.fill"
        case .automationReceipts: "bolt.fill"
        case .workflowEditing: "square.and.arrow.down"
        }
    }

    /// Does this peer speak the feature? For a control that should simply not
    /// appear, instead of taking the whole screen over.
    ///
    /// `RemoteHostFeatureGate` is the other shape, for a whole surface that
    /// cannot work at all. A Refresh button is not that: the picker is fine
    /// without it, and an "update your Mac" panel in place of one button would
    /// be louder than the thing it is explaining.
    ///
    /// This computer is always current. `Bridge.connect` replaces a helper
    /// whose protocol does not match the app, so a local host cannot be behind
    /// the app asking.
    func isSupported(peer: String?) async -> Bool {
        guard let peer, !peer.isEmpty else { return true }
        guard let version = try? await Bridge.peerProtocolVersion(peer) else { return false }
        return version >= minimumProtocol
    }
}

/// Ask a paired computer whether it can serve one feature before that feature
/// begins loading. A transport error deliberately fails open, preserving the
/// screen's existing offline and retry behaviour. Only a definite older
/// protocol becomes the update state.
struct RemoteHostFeatureGate<Content: View>: View {
    let feature: RemoteHostFeature
    let peer: String?
    let hostName: String?
    @ViewBuilder let content: () -> Content

    @State private var probe = RemoteHostFeatureProbe()

    var body: some View {
        Group {
            if let peer, !peer.isEmpty {
                switch probe.state {
                case .available:
                    content()
                case .checking:
                    RemoteHostFeatureCheckingView(feature: feature)
                case let .needsUpdate(version):
                    RemoteHostFeatureUpdateView(
                        feature: feature,
                        hostName: hostName,
                        hostProtocol: version,
                        retry: { probe.retry += 1 }
                    )
                }
            } else {
                content()
            }
        }
        .task(id: "\(peer ?? "local")-\(feature)-\(probe.retry)") {
            guard let peer, !peer.isEmpty else {
                // A local host is always current, and it must not leave the
                // previous remote answer behind: remote needsUpdate, a local
                // interlude, then back to the same remote must re-check rather
                // than resume the local .available and hide the update prompt.
                probe.noteLocal()
                return
            }
            // Pushing another screen cancels this task and popping restarts it
            // for the same peer. Clearing to .checking then would unmount the
            // content and drop its state, so Back from workspace tools landed
            // on the chat list instead of the open thread. Only a new peer, a
            // new feature, or an explicit retry is a new question; the
            // `beginRun` gate keeps the old answer mounted for a restart. This
            // view can be retained while the person changes the selected
            // computer, and that still re-checks: a new peer is a new key.
            let key = RemoteHostFeatureProbeKey(peer: peer, feature: feature, retry: probe.retry)
            guard probe.beginRun(key: key) else { return }
            do {
                let version = try await Bridge.peerProtocolVersion(peer)
                guard !Task.isCancelled else { return }
                probe.didAnswer(key: key, state: version >= feature.minimumProtocol ? .available : .needsUpdate(version))
            } catch {
                guard !Task.isCancelled else { return }
                // Reachability has its own UI. Turning an asleep host into an
                // "update" instruction sends somebody in the wrong direction.
                probe.didAnswer(key: key, state: .available)
            }
        }
    }
}

/// The gate's check state, held across task restarts.
///
/// Internal for the standalone probe tests: pushing a screen cancels the
/// gate's task and popping restarts it, and the tests pin that a restart for
/// the same peer keeps the old answer instead of clearing it.
struct RemoteHostFeatureProbeKey: Equatable, Hashable {
    var peer: String
    var feature: RemoteHostFeature
    var retry: Int
}

@MainActor @Observable
final class RemoteHostFeatureProbe {
    enum State: Equatable {
        case checking
        case available
        case needsUpdate(Int)
    }

    var state: State = .checking
    var retry = 0
    /// What the last answered run asked. Set only when an answer lands: a run
    /// cancelled before answering leaves no key, so its restart asks again
    /// instead of resuming a check that never finished.
    var checkedKey: RemoteHostFeatureProbeKey?
    /// What the newest begun run asked. A peer switch while the old host is
    /// still answering must not let the late answer cover the new host, so an
    /// answer lands only while its key is still the newest one.
    var inflightKey: RemoteHostFeatureProbeKey?

    /// Open a run for this key. A restart for the already-answered key returns
    /// false and the caller asks nothing, leaving the old answer and its
    /// content mounted. Anything else returns true and clears to `.checking`.
    func beginRun(key: RemoteHostFeatureProbeKey) -> Bool {
        guard checkedKey != key else { return false }
        inflightKey = key
        state = .checking
        return true
    }

    /// Record the answer, so a later restart for the same key resumes it. A
    /// late answer for a superseded peer is dropped: only the newest begun key
    /// may land.
    func didAnswer(key: RemoteHostFeatureProbeKey, state: State) {
        guard key == inflightKey else { return }
        checkedKey = key
        self.state = state
    }

    /// A local host needs no check and must not leave a remote answer behind.
    func noteLocal() {
        state = .available
        checkedKey = nil
        inflightKey = nil
    }
}

private struct RemoteHostFeatureCheckingView: View {
    let feature: RemoteHostFeature

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ProgressView()
            Text("Checking \(feature.title) on this computer")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// The paired desktop has answered, but predates a feature on this client.
/// Reuse the app's living persona rather than a static warning mark: this is a
/// calm detour while the desktop update installs, not a broken connection.
struct RemoteHostFeatureUpdateView: View {
    let feature: RemoteHostFeature
    let hostName: String?
    let hostProtocol: Int
    let retry: () -> Void

    private var computer: String {
        guard let hostName, !hostName.isEmpty else { return "this computer" }
        return hostName
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 156, height: 156)
                Circle()
                    .stroke(Theme.accent.opacity(0.2), lineWidth: 1)
                    .frame(width: 118, height: 118)
                PersonaPastime(
                    seed: personaSeed(for: "\(computer)-\(feature.title)"),
                    size: 102,
                    doing: .thought
                )
                .frame(width: 132, height: 112)
                Image(systemName: feature.symbol)
                    .font(Theme.fixed(15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(9)
                    .background(Theme.panel, in: Circle())
                    .overlay(Circle().stroke(Theme.border))
                    .offset(x: 58, y: 46)
            }
            Text("Update \(computer) to use \(feature.title)")
                .font(Theme.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("This device is ready, but \(computer) runs an older version of tokenstat. Update the desktop app, then check again.")
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Check again", .refresh) { retry() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityHint("Checks whether the desktop update is ready")
            Text("Desktop protocol \(hostProtocol) needs \(feature.minimumProtocol) or later")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }
}
