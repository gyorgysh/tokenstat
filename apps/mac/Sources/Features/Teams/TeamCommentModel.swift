// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation
import Observation

@MainActor @Observable final class TeamCommentModel {
    private(set) var text = ""
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var status: String?
    private(set) var draft: TeamCommentDraft?
    private(set) var hasUnsavedWriting = false
    private(set) var recoveredText: String?
    private(set) var acceptedRevision: UInt64 = 0
    let target: TeamCommentTarget
    private let store: TeamStore
    private let context: TeamMutationContext
    private let storage: TeamCommentDraftStore
    private let location: TeamCommentLocation?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, Error>?

    init(target: TeamCommentTarget, store: TeamStore, context: TeamMutationContext, storage: TeamCommentDraftStore = .shared, location: TeamCommentLocation? = nil) {
        self.target = target; self.store = store; self.context = context; self.storage = storage
        self.location = location
    }
    var current: Bool { store.mutationContext == context && store.phase == .ready && store.capabilities?.actorId == target.person && context.owner.scope.origin == target.origin && context.organizationId == target.organization }
    var pending: Bool { draft?.attempt != nil }
    var tooLong: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !TeamCommentDraft(revision: UUID(), text: text, attempt: draft?.attempt).canSend }
    var copyText: String { recoveredText ?? text }
    var canSend: Bool { loaded && current && !busy && recoveredText == nil && TeamCommentDraft(revision: UUID(), text: text, attempt: draft?.attempt).canSend }

    func restore() async {
        guard !loaded, current else { return }
        do {
            let saved = try await storage.load(target)
            let recovery = await storage.unsavedWriting(target)
            guard current else { return }
            draft = saved
            if let recovery, recovery.expected != saved {
                text = saved?.text ?? ""; recoveredText = recovery.text
            } else { text = recovery?.text ?? saved?.text ?? "" }
            hasUnsavedWriting = recovery != nil
            loaded = true
            if recovery != nil { error = (recoveredText == nil ? L10n.text("common.teams.comment_save_failed") : L10n.text("common.teams.comment_draft_changed")) }
            if pending { status = L10n.text("common.teams.comment_unconfirmed") }
        } catch { self.error = L10n.text("common.teams.comment_save_failed") }
    }
    func edit(_ value: String) {
        guard loaded, current, !busy, !pending, recoveredText == nil else { return }
        text = value; status = nil
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); try await self?.flush() }
            catch is CancellationError {} catch { self?.failedSave(error) }
        }
    }
    func flush() async throws {
        guard loaded, !pending else { return }
        guard recoveredText == nil else { throw TeamCommentDraftFailure.changed }
        if let saving { try await saving.value; return }
        let operation = Task { @MainActor [self] in
            while draft?.text != text && !(draft == nil && text.isEmpty) {
                let words = text, expected = draft
                draft = try await storage.save(target, text: words, expected: expected, location: location)
                hasUnsavedWriting = false
            }
        }
        saving = operation
        defer { saving = nil }
        try await operation.value
    }
    func saveOnLeave() {
        autosave?.cancel()
        Task { do { try await flush() } catch { failedSave(error) } }
    }
    private func message(_ failure: Error) -> String {
        if let failure = failure as? TeamRequestFailure { return failure.message }
        if let failure = failure as? TeamCommentDraftFailure { return failure.localizedDescription }
        return L10n.text("common.teams.comment_save_failed")
    }
    private func failedSave(_ failure: Error) { hasUnsavedWriting = true; error = message(failure) }

    func send() async {
        guard canSend else { return }
        busy = true; error = nil; status = nil; autosave?.cancel()
        defer { busy = false }
        do {
            try await flush()
            guard current, let saved = draft, saved.text == text else { throw CancellationError() }
            let reserved = try await storage.reserve(target, expected: saved)
            draft = reserved
            guard current, let input = reserved.input else { throw CancellationError() }
            let result: TeamCommentResult = try await store.perform(.commentSend, fields: ["target":target.fields, "input":input], context: context)
            try await accept(result.receipt, expected: reserved)
        } catch is CancellationError {
            if pending { status = L10n.text("common.teams.comment_unconfirmed") }
        } catch {
            self.error = message(error)
            if pending {
                if let failure = error as? TeamRequestFailure, ["delivery_unknown", "team_connection_unavailable", "teams_unreachable"].contains(failure.code) { self.error = nil }
                status = L10n.text("common.teams.comment_unconfirmed")
            }
            else { hasUnsavedWriting = true }
        }
    }
    func checkDelivery() async {
        guard loaded, current, !busy, let draft, let attempt = draft.attempt else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result: TeamCommentResult = try await store.read(.connectionCall, fields: ["target":target.fields, "method":.string("team.chat.receipt"), "params":.object(["clientMessageId":.string(attempt.id)])], context: context)
            try await accept(result.receipt, expected: draft)
        } catch is CancellationError {} catch { self.error = message(error) }
    }
    private func accept(_ receipt: TeamCommentReceipt, expected: TeamCommentDraft) async throws {
        guard current, let attempt = expected.attempt, receipt.matches(share: target.share, message: attempt.id) else { throw TeamRequestFailure(code: "invalid_response", message: L10n.text("common.teams.comment_unconfirmed")) }
        let next = try await storage.resolve(target, expected: expected, state: receipt.state)
        guard current else { throw CancellationError() }
        draft = next; text = next?.text ?? ""; hasUnsavedWriting = recoveredText != nil
        switch receipt.state {
        case .accepted: acceptedRevision &+= 1; status = L10n.text("common.teams.comment_posted")
        case .notAccepted: status = L10n.text("common.teams.comment_not_accepted")
        case .pending, .unknown: status = L10n.text("common.teams.comment_unconfirmed")
        }
    }
    /// An explicit reload follows the visible copy action when another window
    /// changed the saved draft. It never retargets an uncertain attempt.
    func reloadSavedDraft() async {
        guard !busy, !pending, current else { return }
        do {
            let saved = try await storage.load(target)
            await storage.forgetUnsavedWriting(target)
            draft = saved; text = saved?.text ?? ""; recoveredText = nil; hasUnsavedWriting = false; error = nil
        } catch { failedSave(error) }
    }
}
