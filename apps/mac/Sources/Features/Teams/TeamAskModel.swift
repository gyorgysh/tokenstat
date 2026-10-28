// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

@MainActor @Observable final class TeamAskModel {
    var text = ""
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var stopping = false
    private(set) var error: String?
    /// The sharing computer is holding this request until its owner answers.
    /// The same request is sent again until it starts, is declined, or the
    /// owner's window to answer has passed.
    private(set) var awaitingApproval = false
    private var approvalSince: Date?
    private var statusUnconfirmed = false
    private(set) var fence: JSONValue?
    private(set) var saved: TeamAskRecoveryStore.Snapshot?
    private let target: TeamCommentTarget
    private let storage: TeamAskRecoveryStore
    private let location: TeamCommentLocation?
    private let current: () -> Bool
    private let call: (String, [String: JSONValue]) async throws -> JSONValue
    var pending: Bool { saved != nil && fence == nil }
    var canAsk: Bool { loaded && current() && !busy && fence == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 8192 }

    init(target: TeamCommentTarget, storage: TeamAskRecoveryStore, location: TeamCommentLocation? = nil,
         current: @escaping () -> Bool, call: @escaping (String, [String: JSONValue]) async throws -> JSONValue) {
        self.target = target; self.storage = storage; self.location = location; self.current = current; self.call = call
    }
    func restore(force: Bool = false) async {
        guard (!loaded || force), fence == nil, !busy, current() else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await storage.load(target)
            guard current() else { return }
            saved = value; fence = value?.record.fence; text = value?.record.text ?? ""
            loaded = true; statusUnconfirmed = false; error = pending ? L10n.text("common.teams.ask_unconfirmed") : nil
        } catch { loaded = false; self.error = L10n.text("common.teams.ask_save_failed") }
    }
    func ask(computer: String) async {
        guard canAsk else { return }
        busy = true; error = nil; statusUnconfirmed = false; defer { busy = false }
        defer { if !awaitingApproval { approvalSince = nil } }
        awaitingApproval = false
        do {
            if saved == nil {
                let response = try await call("team.chat.ask.review", [:])
                guard current() else { return }
                guard case let .object(review) = response, review["agentRuns"] == .bool(true) else {
                    error = L10n.text("common.teams.agent_runs_off", computer); return
                }
                let record = try TeamAskRecord(input: ["text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "review": review["review"] ?? .null, "clientMessageId": .string(UUID().uuidString.lowercased()),
                    "clientMessageCreatedAtMs": .int(Int64(Date().timeIntervalSince1970 * 1000))])
                // No network mutation is allowed until this exact request is durable.
                saved = try await storage.replace(target, record: record, expected: nil, location: location)
                text = record.text
            }
            guard current(), let original = saved else { return }
            let response = try await call("team.chat.ask", original.record.input)
            if case let .object(body) = response, body["state"] == .string("running"), let running = body["fence"], TeamAskRecord.validFence(running) {
                // Keep Stop even if persisting the running reply fails. The
                // original durable request can recover this fence on reopening.
                fence = running
                saved = try await storage.replace(target, record: TeamAskRecord(input: original.record.input, fence: running), expected: original)
                text = ""
            } else if original.record.terminal(response, share: target.share) {
                saved = try await storage.replace(target, record: nil, expected: original)
                text = ""
            } else { throw TeamAskRecoveryFailure.unconfirmed }
        } catch is TeamAskAwaitingApproval {
            let since = approvalSince ?? Date()
            approvalSince = since
            guard Date().timeIntervalSince(since) < 15 * 60 else {
                awaitingApproval = false; approvalSince = nil
                error = L10n.text("common.teams.agent_approval_expired", computer); return
            }
            awaitingApproval = true
            error = L10n.text("common.teams.agent_waiting_approval", computer)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.awaitingApproval, self.current() else { return }
                await self.ask(computer: computer)
            }
            return
        } catch let refusal as TeamAskNotAccepted {
            // The host settles an existing immutable receipt before checking
            // a fresh review. Only its explicit validation refusal permits a
            // new review; transport and authority errors retain the attempt.
            do { saved = try await storage.replace(target, record: nil, expected: saved); error = refusal.localizedDescription }
            catch { self.error = L10n.text("common.teams.ask_save_failed") }
        } catch is CancellationError {} catch {
            // An error never proves that an earlier delivery was rejected.
            // Keep its ID and reviewed text until a bound receipt or fence does.
            self.error = error is TeamCommentDraftFailure ? L10n.text("common.teams.ask_save_failed") : error.localizedDescription
        }
    }
    func check() async {
        guard let running = fence, current(), !busy else { return }
        do {
            let status = try await call("team.chat.ask.status", ["fence": running])
            guard current(), fence == running else { return }
            guard case let .object(fields) = status, case let .bool(active)? = fields["running"] else { throw TeamAskRecoveryFailure.unconfirmed }
            if !active {
                // A stale window cannot remove a newer saved Ask.
                saved = try await storage.replace(target, record: nil, expected: saved)
                fence = nil; stopping = false; text = ""; error = nil
            } else if statusUnconfirmed { error = nil }
            statusUnconfirmed = false
        } catch is CancellationError {} catch { statusUnconfirmed = true; self.error = L10n.text("common.teams.run_status_unconfirmed") }
    }
    func stop() async {
        guard let running = fence, current(), !stopping else { return }
        stopping = true; error = nil; statusUnconfirmed = false
        do {
            let reply = try await call("team.chat.ask.stop", ["fence": running])
            guard case let .object(body) = reply, case .bool? = body["stopping"] else { throw TeamAskRecoveryFailure.unconfirmed }
            // Stopping is an acknowledgement, not completion. Only status
            // with running:false may remove the saved run.
        } catch { self.error = error.localizedDescription; stopping = false }
    }
}
