// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct ChatSlashCommand: Identifiable {
    let id: String
    let detail: String
    static var all: [Self] { [
        .init(id: "/compact", detail: L10n.text("common.chat.command.compact")),
        .init(id: "/status", detail: L10n.text("common.chat.command.status")),
        .init(id: "/context", detail: L10n.text("common.chat.command.context")),
        .init(id: "/usage", detail: L10n.text("common.chat.command.usage")),
        .init(id: "/mcp", detail: L10n.text("common.chat.command.mcp")),
        .init(id: "/tools", detail: L10n.text("common.chat.command.tools")),
        .init(id: "/goal", detail: L10n.text("common.chat.activity.command_goal")),
        .init(id: "/plan", detail: L10n.text("common.chat.activity.command_plan")),
        .init(id: "/subagents", detail: L10n.text("common.chat.activity.command_subagents")),
        .init(id: "/help", detail: L10n.text("common.chat.command.help")),
        .init(id: "/stop", detail: L10n.text("common.chat.command.stop")),
    ] }
}

struct ChatSlashMenu: View {
    @Bindable var model: ChatModel
    private var matches: [ChatSlashCommand] {
        guard !model.chatCommandsDismissed else { return [] }
        let names = ChatCommandRules.matches(model.draft)
        return ChatSlashCommand.all.filter { names.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !matches.isEmpty {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            Button { model.draft = command.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.id).font(Theme.callout.weight(.medium))
                                        Text(command.detail).font(Theme.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(command.id)
                            .background(index == model.chatCommandSelection ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(height: min(CGFloat(matches.count) * 56, 220))
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(L10n.text("common.chat.commands"))
                .onChange(of: model.chatCommandSelection) { _, next in
                    if matches.indices.contains(next) { proxy.scrollTo(matches[next].id, anchor: .center) }
                }
                }
            }
        }
        .onChange(of: model.draft) { _, _ in model.chatCommandSelection = 0; model.chatCommandsDismissed = false }
        .onChange(of: model.currentReference) { _, _ in model.chatCommandSelection = 0; model.chatCommandsDismissed = false; model.showingCommandStats = false }
        .sheet(isPresented: $model.showingCommandStats) {
            ThemedSheet(title: L10n.text("common.chat.stats.overview"), subtitle: "", scrolls: true, fills: true, onClose: { model.showingCommandStats = false }) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ChatContextCard(model: model)
                    Text(L10n.text("common.chat.commands")).font(Theme.callout.weight(.semibold))
                    ForEach(ChatSlashCommand.all) { command in
                        Text("\(command.id) · \(command.detail)").font(Theme.caption)
                    }
                    Text(L10n.text("common.chat.command.unsupported")).font(Theme.caption).foregroundStyle(.secondary)
                }
            } actions: { EmptyView() }
            .modalFrame(width: 560, height: 700)
        }
    }
}
