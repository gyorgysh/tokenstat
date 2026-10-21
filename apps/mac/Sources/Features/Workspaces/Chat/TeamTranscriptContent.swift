// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Reuses the chat renderer while leaving personal models, file transfers and
/// approval callbacks out of this read-only Team history surface.
struct TeamTranscriptContent: View {
    let history: TeamChatHistory
    @State private var rows: [ChatDisplayItem] = []
    @State private var people: [String: TeamPerson] = [:]
    @State private var asks: Set<String> = []
    @State private var readyRenderId: UUID?
    @State private var error: String?
    @Environment(\.teamAvatarOwner) private var owner
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error { TeamNotice(message: error, warning: true) }
            ForEach(rows) { row in
                if case .user = row.kind {
                    if let person = people[row.id] {
                        HStack(spacing: Theme.Space.s) {
                            Avatar(url: teamAvatarURL(person.avatar, owner: owner)?.absoluteString, name: person.name, handle: person.handle, size: 24, tint: Avatar.tint(for: person.id)).accessibilityHidden(true)
                            Text(person.name).font(Theme.caption.weight(.semibold)).lineLimit(2)
                            Text(asks.contains(row.id) ? L10n.text("common.teams.ask") : L10n.text("common.teams.comment")).font(Theme.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .trailing).accessibilityElement(children: .combine)
                    } else {
                        Label(L10n.text("common.teams.local_before_teams"), systemImage: "person.crop.circle")
                            .font(Theme.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if case let .attachment(file) = row.kind {
                    Label(file.name, systemImage: "paperclip").font(Theme.callout).foregroundStyle(.secondary)
                } else {
                    ChatEventRow(item: row, defaultAgentName: label(history.backend), agentLabel: label, attachmentData: nil,
                                 isPending: false, resolve: { _, _ in }, canAnswerQuestions: false)
                }
            }
        }
        .preference(key: TeamTranscriptRenderedKey.self, value: readyRenderId)
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
                    return (ChatDisplayItem.coalesce(decoded, defaultBackend: backend, running: false), try TeamMessageAttribution.people(events), TeamMessageAttribution.asks(events))
                }.value
                try Task.checkCancellation()
                rows = result.0; people = result.1; asks = result.2; readyRenderId = history.renderId; error = nil
            } catch is CancellationError {} catch {
                rows = []; people = [:]; asks = []; readyRenderId = history.renderId; self.error = L10n.text("common.teams.history_cannot_display")
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
