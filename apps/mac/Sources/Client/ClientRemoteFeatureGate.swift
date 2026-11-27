// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftUI

enum RemoteHostFeature: Hashable {
    case chat
    case pulls
    case pullListPages
    case pullAllState
    case pullCreation
    case chatQuestions
    case modelRefresh
    case folderPicker
    case cloneRepository
    case provisioning
    case inviteCode
    case agentSignIn
    case agentReinstall
    case agentProfiles
    case agentUpdates
    case confirmedSend
    case handoff
    case workSearch
    case hostUpdate
    case selectedCommit
    case worktrees
    case reviewedPush
    case reviewedPull
    case branchPulls
    case taskEditing
    case taskDeletion
    case taskCreation
    case taskExecution
    case automationReceipts
    case workflowEditing
    case steer
    case chatFork
    case chatContinue
    case chatRemoveAll
    case liveActivities
    case terminalLiveActivities
    case commitAvatars
    case chatRecovery
    case workOverview
    case teamChats
    case teamSessions
    case teamCheckouts
    case teamConnections
    case teamChatSharing
    case teamCheckoutUpdates
    case teamProjectSetup
    case teamChatSelection
    case generalFolder
    case routingDefaults

    var title: String {
        switch self {
        case .chat: L10n.text("apple.clientremotefeaturegate.chat.460b3a7d")
        case .pulls, .pullCreation, .pullListPages, .pullAllState: L10n.text("apple.clientremotefeaturegate.pull_requests.d9e3f260")
        case .chatQuestions, .chatRecovery: L10n.text("apple.clientremotefeaturegate.chat.460b3a7d")
        case .modelRefresh: L10n.text("apple.clientremotefeaturegate.model_list_refresh.7113bd00")
        case .folderPicker: L10n.text("apple.clientremotefeaturegate.choosing_a_folder.5e3303d0")
        case .cloneRepository: L10n.text("apple.clientremotefeaturegate.cloning_a_repository.6ad75b22")
        case .provisioning: L10n.text("apple.clientremotefeaturegate.setup.7013af4c")
        case .inviteCode: L10n.text("apple.clientremotefeaturegate.adding_this_device.4bb25dcd")
        case .agentSignIn: L10n.text("apple.clientremotefeaturegate.signing_in_to_an_agent.7a8b7e31")
        case .agentReinstall: L10n.text("apple.harnessconfigview.reinstall")
        case .agentProfiles: L10n.text("apple.profiles.title")
        case .agentUpdates: L10n.text("common.agent_updates.title")
        case .confirmedSend: L10n.text("apple.clientremotefeaturegate.confirming_a_sent_message.86a0a4b6")
        case .handoff: L10n.text("apple.clientremotefeaturegate.handoff.f89e2d72")
        case .workSearch: L10n.text("apple.clientremotefeaturegate.search_work.cc46cedc")
        case .hostUpdate: L10n.text("apple.clientremotefeaturegate.updating_this_computer.5b732088")
        case .selectedCommit: L10n.text("apple.clientremotefeaturegate.committing_selected_files.c40972a7")
        case .worktrees: L10n.text("apple.clientremotefeaturegate.project_worktrees.0c15733b")
        case .reviewedPush: L10n.text("apple.clientremotefeaturegate.pushing_a_branch.e4403991")
        case .reviewedPull: L10n.text("apple.clientremotefeaturegate.pulling_a_branch")
        case .branchPulls: L10n.text("apple.clientremotefeaturegate.pull_requests.d9e3f260")
        case .taskEditing: L10n.text("apple.clientremotefeaturegate.editing_tasks.1663f4eb")
        case .taskDeletion: L10n.text("apple.clientremotefeaturegate.deleting_tasks.faf65d2e")
        case .taskCreation: L10n.text("apple.clientremotefeaturegate.creating_tasks.ca462a92")
        case .taskExecution: L10n.text("apple.clientremotefeaturegate.running_tasks.99ad64f5")
        case .automationReceipts: L10n.text("apple.clientremotefeaturegate.saving_automations.1673f244")
        case .workflowEditing: L10n.text("apple.clientremotefeaturegate.saving_workflows.9ca663b4")
        case .chatFork: L10n.text("apple.clientremotefeaturegate.forking_chats.1181b97c")
        case .chatContinue: L10n.text("apple.clientremotefeaturegate.continuing_in_a_new_chat")
        case .chatRemoveAll: L10n.text("apple.clientremotefeaturegate.deleting_all_chats.978c2f5e")
        case .steer: L10n.text("apple.clientremotefeaturegate.notes_on_the_next_step.a272bf5a")
        case .liveActivities, .terminalLiveActivities, .workOverview: "Live Activities"
        case .commitAvatars: "Author pictures"
        case .teamChats, .teamSessions, .teamChatSharing: L10n.text("common.teams.chats")
        case .teamCheckouts, .teamConnections, .teamCheckoutUpdates, .teamProjectSetup, .teamChatSelection: L10n.text("common.teams.checkouts")
        case .generalFolder: L10n.text("common.new_chat.no_repository")
        case .routingDefaults: L10n.text("common.chat_routing")
        }
    }

    var minimumProtocol: Int {
        switch self {
        case .worktrees: 24
        case .chat: 4
        case .pulls: 3
        case .pullListPages: 52
        case .pullAllState: 53
        case .pullCreation: 28
        case .chatQuestions: 29
        case .modelRefresh: 6
        case .folderPicker: 7
        case .cloneRepository: 7
        case .provisioning: 7
        case .inviteCode: 7
        case .agentSignIn: 9
        case .agentReinstall: 37
        case .agentProfiles: 57
        case .agentUpdates: 55
        case .confirmedSend: 14
        case .handoff: 12
        case .workSearch: 12
        case .hostUpdate: 14
        case .selectedCommit: 15
        case .reviewedPush: 16
        case .reviewedPull: 30
        case .branchPulls: 30
        case .taskEditing: 17
        case .taskDeletion: 18
        case .taskCreation: 19
        case .taskExecution: 20
        case .automationReceipts: 21
        case .workflowEditing: 22
        case .chatFork: 26
        case .chatContinue: 54
        case .chatRemoveAll: 26
        case .steer: 25
        case .liveActivities: 31
        case .terminalLiveActivities: 32
        case .commitAvatars: 33
        case .chatRecovery: 34
        case .workOverview: 35
        case .teamChats: 38
        case .teamSessions: 39
        case .teamCheckouts: 40
        case .teamConnections: 41
        case .teamChatSharing: 42
        case .teamCheckoutUpdates: 49
        case .teamProjectSetup: 50
        case .teamChatSelection: 51
        case .generalFolder: 56
        case .routingDefaults: 58
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .pulls, .pullCreation, .pullListPages, .pullAllState: "arrow.triangle.merge"
        case .chatQuestions: "questionmark.bubble"
        case .modelRefresh: "arrow.clockwise"
        case .folderPicker: "folder.badge.plus"
        case .cloneRepository: "arrow.down.doc"
        case .provisioning: "sparkles"
        case .inviteCode: "key.horizontal.fill"
        case .agentSignIn: "person.badge.key.fill"
        case .agentReinstall: "arrow.clockwise"
        case .agentProfiles: "person.2"
        case .agentUpdates: "arrow.down.circle"
        case .confirmedSend: "checkmark.message.fill"
        case .handoff: "arrow.left.arrow.right"
        case .workSearch: "magnifyingglass"
        case .hostUpdate: "arrow.down.circle"
        case .selectedCommit: "checkmark.circle"
        case .worktrees: "arrow.triangle.branch"
        case .reviewedPush: "arrow.up.circle"
        case .reviewedPull: "arrow.down.circle"
        case .branchPulls: "arrow.triangle.pull"
        case .taskEditing: "pencil"
        case .taskDeletion: "trash"
        case .taskCreation: "plus"
        case .taskExecution: "play.fill"
        case .automationReceipts: "bolt.fill"
        case .workflowEditing: "square.and.arrow.down"
        case .chatFork: "doc.on.doc"
        case .chatContinue: "arrow.turn.down.right"
        case .chatRemoveAll: "trash"
        case .steer: "text.bubble"
        case .liveActivities, .terminalLiveActivities, .workOverview: "waveform"
        case .commitAvatars: "person.crop.circle"
        case .chatRecovery: "arrow.clockwise"
        case .teamChats, .teamSessions, .teamCheckouts, .teamConnections, .teamChatSharing, .teamCheckoutUpdates, .teamProjectSetup, .teamChatSelection: "person.2"
        case .generalFolder: "bubble.left.and.bubble.right"
        case .routingDefaults: "arrow.triangle.branch"
        }
    }

    func isSupported(peer: String?) async -> Bool {
        guard let peer, !peer.isEmpty else { return true }
        guard let version = try? await Bridge.peerProtocolVersion(peer) else { return false }
        return version >= minimumProtocol
    }
}

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
                probe.noteLocal()
                return
            }
            let key = RemoteHostFeatureProbeKey(peer: peer, feature: feature, retry: probe.retry)
            guard probe.beginRun(key: key) else { return }
            do {
                let version = try await Bridge.peerProtocolVersion(peer)
                guard !Task.isCancelled else { return }
                probe.didAnswer(key: key, state: version >= feature.minimumProtocol ? .available : .needsUpdate(version))
            } catch {
                guard !Task.isCancelled else { return }
                probe.didAnswer(key: key, state: .available)
            }
        }
    }
}

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
    var checkedKey: RemoteHostFeatureProbeKey?
    var inflightKey: RemoteHostFeatureProbeKey?

    func beginRun(key: RemoteHostFeatureProbeKey) -> Bool {
        guard checkedKey != key || inflightKey != key else { return false }
        inflightKey = key
        state = .checking
        return true
    }

    func didAnswer(key: RemoteHostFeatureProbeKey, state: State) {
        guard key == inflightKey else { return }
        checkedKey = key
        self.state = state
    }

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
            Text(L10n.text("apple.clientremotefeaturegate.checking_0_on_this_computer.19e3aa4b", "\(feature.title)"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct RemoteHostFeatureUpdateView: View {
    let feature: RemoteHostFeature
    let hostName: String?
    let hostProtocol: Int
    let retry: () -> Void

    private var computer: String {
        guard let hostName, !hostName.isEmpty else { return L10n.text("apple.clientremotefeaturegate.this_computer.058bf37c") }
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
            Text(L10n.text("apple.clientremotefeaturegate.update_0_to_use_1.3ca9b9e4", "\(computer)", "\(feature.title)"))
                .font(Theme.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(L10n.text("apple.clientremotefeaturegate.this_device_is_ready_but_0_runs_an_older_v.6c7d61dc", "\(computer)"))
                .font(Theme.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(L10n.text("apple.clientremotefeaturegate.check_again.fb7099ad"), .refresh) { retry() }
                .buttonStyle(AccentButtonStyle())
                .accessibilityHint(L10n.text("apple.clientremotefeaturegate.checks_whether_the_desktop_update_is_ready.1ca1f834"))
            Text(L10n.text("apple.clientremotefeaturegate.desktop_protocol_0_needs_1_or_later.addd22e9", "\(hostProtocol)", "\(feature.minimumProtocol)"))
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
        .background(Theme.background)
    }
}
