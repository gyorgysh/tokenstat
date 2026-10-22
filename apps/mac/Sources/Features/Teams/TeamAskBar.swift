// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Ask the publishing computer's agent about a shared chat. The host reviews
/// the chat first and starts the agent only for that reviewed state. While it
/// runs, the reader refreshes and anyone allowed can stop it.
struct TeamAskBar: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let target: [String: JSONValue]
    let computer: String
    let refresh: () -> Void
    @State private var text = ""
    @State private var fence: JSONValue?
    @State private var busy = false
    @State private var stopping = false
    @State private var error: String?
    @State private var watcher: Task<Void, Never>?
    // Keep the exact reviewed request until its reply is known. A fresh
    // review or id after a lost reply could pay for the same work twice.
    @State private var attempt: [String: JSONValue]?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let error { TeamNotice(message: error, warning: true) }
            if fence != nil {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(stopping ? L10n.text("common.teams.agent_stopping") : L10n.text("common.teams.agent_working", computer))
                        .font(Theme.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("common.teams.stop_agent"), .stop) { Task { await stop() } }
                        .buttonStyle(TeamButtonStyle()).disabled(stopping).accessibilityIdentifier("team.ask.stop")
                }
            } else {
                Text(L10n.text("common.teams.ask_agent")).font(Theme.callout.weight(.semibold))
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    TextField(L10n.text("common.teams.ask_placeholder"), text: $text, axis: .vertical)
                        .font(Theme.body).textFieldStyle(.plain).lineLimit(1...4)
                        .padding(Theme.Space.m).background(Theme.controlSeat, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .disabled(busy || attempt != nil).accessibilityIdentifier("team.ask.text")
                    Button(L10n.text("common.teams.ask"), .run) { Task { await ask() } }
                        .buttonStyle(TeamButtonStyle(primary: true))
                        .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 8192)
                        .accessibilityIdentifier("team.ask.send")
                }
                Text(L10n.text("common.teams.ask_detail", computer)).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { watcher?.cancel() }
    }

    private func call<T: Decodable & Sendable>(_ method: String, _ params: [String: JSONValue], as: T.Type = T.self) async throws -> T {
        var fields = target
        fields["method"] = .string(method); fields["params"] = .object(params)
        return try await store.read(.ask, fields: fields, context: context)
    }

    private func ask() async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if attempt == nil {
                let review: TeamAskReview = try await call("team.chat.ask.review", [:])
                if !review.agentRuns { error = L10n.text("common.teams.agent_runs_off", computer); return }
                attempt = [
                    "text": .string(question), "review": .string(review.review),
                    "clientMessageId": .string(UUID().uuidString.lowercased()),
                    "clientMessageCreatedAtMs": .int(Int64(Date().timeIntervalSince1970 * 1000)),
                ]
            }
            guard let attempt else { return }
            let sent: TeamAskStarted = try await call("team.chat.ask", attempt)
            self.attempt = nil
            text = ""
            refresh()
            if sent.state == "running", let running = sent.fence { fence = running; watch(running) }
        } catch is CancellationError {} catch {
            if let failure = error as? TeamRequestFailure, ["team_run_review_changed", "invalid_ask"].contains(failure.code) { attempt = nil }
            self.error = error.localizedDescription
        }
    }

    private func watch(_ running: JSONValue) {
        watcher?.cancel()
        watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                refresh()
                let status: TeamAskStatus? = try? await call("team.chat.ask.status", ["fence": running])
                if status?.running == false { break }
            }
            guard !Task.isCancelled else { return }
            fence = nil; stopping = false
            refresh()
        }
    }

    private func stop() async {
        guard let fence, !stopping else { return }
        stopping = true; error = nil
        do { let _: TeamAskStopped = try await call("team.chat.ask.stop", ["fence": fence]) }
        catch is CancellationError {} catch { self.error = error.localizedDescription; stopping = false }
    }
}

struct TeamAskReview: Decodable, Sendable { let review: String; let agentRuns: Bool }
struct TeamAskStarted: Decodable, Sendable { let state: String?; let fence: JSONValue? }
struct TeamAskStatus: Decodable, Sendable { let running: Bool }
struct TeamAskStopped: Decodable, Sendable { let stopping: Bool }
