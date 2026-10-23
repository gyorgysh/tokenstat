// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Ask the publishing computer's agent about a shared chat. The host reviews
/// the chat first and starts the agent only for that reviewed state. While it
/// runs, the reader refreshes and anyone allowed can stop it.
struct TeamAskBar: View {
    @State private var model: TeamAskModel
    let computer: String
    let allowsAgentRuns: Bool
    let refresh: () -> Void

    init(store: TeamStore, context: TeamMutationContext, target: TeamCommentTarget, computer: String, allowsAgentRuns: Bool,
         storage: TeamAskRecoveryStore, location: TeamCommentLocation, refresh: @escaping () -> Void) {
        self.computer = computer; self.allowsAgentRuns = allowsAgentRuns; self.refresh = refresh
        _model = State(initialValue: TeamAskModel(target: target, storage: storage, location: location,
            current: { store.mutationContext == context && store.phase == .ready && store.capabilities?.actorId == target.person },
            call: { method, params in
                do { return try await store.read(.ask, fields: ["target": target.fields, "method": .string(method), "params": .object(params)], context: context) }
                catch let failure as TeamRequestFailure where method == "team.chat.ask" && ["team_run_review_changed", "invalid_ask"].contains(failure.code) {
                    throw TeamAskNotAccepted(message: failure.localizedDescription)
                }
            }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let error = model.error { TeamNotice(message: error, warning: true) }
            if model.fence == nil, model.error != nil {
                Button(L10n.text("common.teams.load_saved_ask"), .refresh) { Task { await model.restore(force: true) } }.buttonStyle(TeamButtonStyle()).disabled(model.busy)
            }
            if model.fence != nil {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(model.stopping ? L10n.text("common.teams.agent_stopping") : L10n.text("common.teams.agent_working", computer))
                        .font(Theme.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("common.teams.stop_agent"), .stop) { Task { await model.stop() } }
                        .buttonStyle(TeamButtonStyle()).disabled(model.stopping).accessibilityIdentifier("team.ask.stop")
                }
            } else if allowsAgentRuns || model.pending {
                Text(L10n.text("common.teams.ask_agent")).font(Theme.callout.weight(.semibold))
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    TextField(L10n.text("common.teams.ask_placeholder"), text: $model.text, axis: .vertical)
                        .font(Theme.body).textFieldStyle(.plain).lineLimit(1...4)
                        .padding(Theme.Space.m).background(Theme.controlSeat, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .disabled(!model.loaded || model.busy || model.pending).accessibilityIdentifier("team.ask.text")
                    Button(model.pending ? L10n.text("common.teams.retry_same_ask") : L10n.text("common.teams.ask"), .run) { Task { await model.ask(computer: computer); refresh() } }
                        .buttonStyle(TeamButtonStyle(primary: true))
                        .disabled(!model.canAsk)
                        .accessibilityIdentifier("team.ask.send")
                }
                Text(L10n.text("common.teams.ask_detail", computer)).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
