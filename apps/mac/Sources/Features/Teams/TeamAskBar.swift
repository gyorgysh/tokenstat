// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Ask the publishing computer's agent about a shared chat. The host reviews
/// the chat first and starts the agent only for that reviewed state. While it
/// runs, the reader refreshes and anyone allowed can stop it.
struct TeamAskBar: View {
    @State private var model: TeamAskModel
    let computer: String
    let allowsAgentRuns: Bool
    /// False while the composer shows comments. A running agent still
    /// reports here, because stopping it should never be a tab away.
    let visible: Bool
    let refresh: () -> Void

    init(model: TeamAskModel, computer: String, refresh: @escaping () -> Void) {
        self.computer = computer; allowsAgentRuns = false; visible = true; self.refresh = refresh
        _model = State(initialValue: model)
    }

    init(store: TeamStore, context: TeamMutationContext, target: TeamCommentTarget, computer: String, allowsAgentRuns: Bool,
         storage: TeamAskRecoveryStore, location: TeamCommentLocation, visible: Bool = true, refresh: @escaping () -> Void) {
        self.computer = computer; self.allowsAgentRuns = allowsAgentRuns; self.visible = visible; self.refresh = refresh
        _model = State(initialValue: TeamAskModel(target: target, storage: storage, location: location,
            current: { store.mutationContext == context && store.phase == .ready && store.capabilities?.actorId == target.person },
            call: { method, params in
                do { return try await store.read(.ask, fields: ["target": target.fields, "method": .string(method), "params": .object(params)], context: context) }
                catch let failure as TeamRequestFailure where method == "team.chat.ask" && ["team_run_review_changed", "invalid_ask", "team_agent_request_denied", "team_agent_runs_off"].contains(failure.code) {
                    throw TeamAskNotAccepted(message: failure.localizedDescription)
                }
                catch let failure as TeamRequestFailure where method == "team.chat.ask" && failure.code == "team_agent_approval_pending" {
                    throw TeamAskAwaitingApproval()
                }
            }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if visible || model.fence != nil, let error = model.error { TeamNotice(message: error, warning: true) }
            if visible, model.fence == nil, model.error != nil {
                Button(L10n.text("common.teams.load_saved_ask"), .refresh) { Task { await model.restore(force: true) } }.buttonStyle(TeamSmallButtonStyle()).disabled(model.busy)
            }
            if model.fence != nil {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(model.stopping ? L10n.text("common.teams.agent_stopping") : L10n.text("common.teams.agent_working", computer))
                        .font(Theme.callout).foregroundStyle(TeamColors.action).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("common.teams.stop_agent"), .stop, role: .destructive) { Task { await model.stop() } }
                        .buttonStyle(TeamSmallButtonStyle()).disabled(model.stopping).accessibilityIdentifier("team.ask.stop")
                }
            } else if visible && (allowsAgentRuns || model.pending) {
                TeamComposerField(placeholder: L10n.text("common.teams.ask_placeholder"), text: $model.text)
                    .disabled(!model.loaded || model.busy || model.pending).accessibilityIdentifier("team.ask.text")
                HStack(spacing: Theme.Space.s) {
                    Label(L10n.text("common.teams.ask_runs_on", computer), systemImage: ActionIcon.device.symbol)
                        .font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(L10n.text("common.teams.ask_detail", computer))
                    Spacer(minLength: Theme.Space.m)
                    Button(model.pending ? L10n.text("common.teams.retry_same_ask") : L10n.text("common.teams.ask"), .run) { Task { await model.ask(computer: computer); refresh() } }
                        .buttonStyle(TeamSmallButtonStyle(primary: true))
                        .disabled(!model.canAsk)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("team.ask.send")
                }
            }
        }
        .task { await model.restore() }
        .task(id: model.fence) {
            guard model.fence != nil else { return }
            while !Task.isCancelled, model.fence != nil {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await model.check()
                refresh()
            }
        }
    }
}
