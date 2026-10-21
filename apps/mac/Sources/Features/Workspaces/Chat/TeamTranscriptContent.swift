// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Reuses the chat renderer while leaving personal models, file transfers and
/// approval callbacks out of this read-only Team history surface.
struct TeamTranscriptContent: View {
    let history: TeamChatHistory
    @State private var rows: [ChatDisplayItem] = []
    @State private var error: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error { TeamNotice(message: error, warning: true) }
            ForEach(rows) { row in
                if case .user = row.kind {
                    Label(L10n.text("common.teams.local_before_teams"), systemImage: "person.crop.circle")
                        .font(Theme.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if case let .attachment(file) = row.kind {
                    Label(file.name, systemImage: "paperclip").font(Theme.callout).foregroundStyle(.secondary)
                } else {
                    ChatEventRow(item: row, defaultAgentName: label(history.backend), agentLabel: label, attachmentData: nil,
                                 isPending: false, resolve: { _, _ in }, canAnswerQuestions: false)
                }
            }
        }
        // A link in someone else's checkout must not become an action on a
        // personal checkout, simulator or workbench on this device.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .task(id: history.renderId) {
            let events = history.events, backend = history.backend
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let decoded = try JSONDecoder().decode([ChatTimelineEvent].self, from: JSONEncoder().encode(events))
                    try Task.checkCancellation()
                    return ChatDisplayItem.coalesce(decoded, defaultBackend: backend, running: false)
                }.value
                try Task.checkCancellation()
                rows = result; error = nil
            } catch is CancellationError {} catch {
                rows = []; self.error = L10n.text("common.teams.history_cannot_display")
            }
        }
    }
    private func label(_ backend: String) -> String {
        switch backend {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "muse": "Muse"
        default: backend
        }
    }
    @MainActor static func render(_ history: TeamChatHistory) -> AnyView { AnyView(TeamTranscriptContent(history: history)) }
}
