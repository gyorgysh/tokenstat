// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Context, tools and activity share the chat's visible inspection reader.
/// Its run-scoped owner and foreground lease also govern MCP live status.
struct ChatContextCard: View {
    @Bindable var model: ChatModel
    @State private var contextOpen = false
    @State private var serversOpen = false
    @State private var otherServersOpen = false
    @State private var promptOpen = false
    @State private var historyOpen = false
    @State private var conversationOpen = false
    private var owner: ChatActivityOwner { model.activityOwner }
    private var currentInspection: ChatInspection? { model.currentActivityRead?.inspection }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            context
            servers
        }
        .onChange(of: owner) { _, _ in
            contextOpen = false
            serversOpen = false
            otherServersOpen = false
            promptOpen = false
            historyOpen = false
            conversationOpen = false
        }
    }

    private var context: some View {
        card(L10n.text("common.chat.stats.context"), symbol: "chart.pie", expanded: $contextOpen, showsStatus: true) {
            if let inspection = currentInspection {
                if let used = inspection.contextUsed {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text("common.chat.stats.in_context", used.formatted(.number.notation(.compactName))))
                            .font(Theme.callout.weight(.medium)).monospacedDigit()
                            .help(used.formatted())
                        Spacer(minLength: 8)
                        if let fraction = inspection.fraction {
                            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                .font(Theme.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(fraction > 0.9 ? Theme.warning : Theme.accent)
                                .fixedSize()
                        }
                    }
                    if inspection.contextWindow != nil { ChatContextSplitBar(inspection: inspection) }
                    if let window = inspection.contextWindow {
                        HStack {
                            Text(L10n.text("common.chat.stats.capacity", used.formatted(), window.formatted()))
                            Spacer(minLength: 4)
                        }.font(Theme.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        note(L10n.text("common.chat.stats.window_unknown"))
                    }
                } else {
                    note(L10n.text("apple.chatcontext.context_unknown"))
                    if let window = inspection.contextWindow {
                        Text(L10n.text("apple.chatcontext.window_tokens", window.formatted()))
                            .font(Theme.callout).monospacedDigit()
                    }
                }
                if contextOpen {
                    ThemeRule()
                    if let breakdown = inspection.contextBreakdown, let used = inspection.contextUsed {
                        VStack(spacing: 5) {
                            let denominator = max(used, inspection.contextWindow ?? used)
                            contextLegend(L10n.text("common.chat.stats.input"), value: breakdown.input, total: denominator, color: Theme.accent)
                            contextLegend(L10n.text("common.chat.stats.cache_read"), value: breakdown.cacheRead, total: denominator, color: Theme.accent.opacity(0.55))
                            contextLegend(L10n.text("common.chat.stats.cache_write"), value: breakdown.cacheWrite, total: denominator, color: Theme.warning)
                            if let window = inspection.contextWindow {
                                contextLegend(L10n.text("common.chat.stats.remaining_context"), value: window > used ? window - used : 0, total: denominator, color: Theme.accentSoft)
                            }
                        }
                    }
                    if let tools = inspection.tools { toolList(tools, title: L10n.text("common.chat.stats.available_tools", tools.count.formatted())) }
                    if !inspection.usedTools.isEmpty { toolList(inspection.usedTools, title: L10n.text("apple.chatcontext.used_tools", inspection.usedTools.count.formatted())) }
                    if let history = inspection.contextHistory, history.count > 1 {
                        ChatDisclosureRow(title: L10n.text("common.chat.stats.history"), expanded: $historyOpen)
                        if historyOpen { ChatContextHistory(points: history) }
                    }
                    ChatDisclosureRow(title: L10n.text("common.chat.stats.details"), expanded: $promptOpen)
                    if promptOpen {
                        note(L10n.text("apple.chatcontext.last_prompt"))
                        if inspection.windowSource == "catalog" { note(L10n.text("common.chat.stats.catalog_window")) }
                        if inspection.windowSource == "previousAgent" { note(L10n.text("common.chat.stats.last_window")) }
                        if let stamp = inspection.observedAtMs {
                            Text(L10n.text("apple.chatcontext.reported_at", Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)))
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                unavailable
            }
            if contextOpen {
                if currentInspection == nil { ThemeRule() }
                // Verified event-page totals predate chat.inspection. Keep
                // them available when an older host cannot report context.
                ChatDisclosureRow(title: L10n.text("common.chat.stats.conversation"), expanded: $conversationOpen)
                if conversationOpen { ChatCostMeter(totals: model.turnUsage) }
            }
        }
    }

    private var servers: some View {
        card(L10n.text("apple.chatcontext.mcp_servers"), symbol: "puzzlepiece.extension", expanded: $serversOpen) {
            if let inspection = currentInspection {
                if inspection.mcpServers.isEmpty {
                    if inspection.mcpReported && inspection.inventoryPartial == true {
                        note(L10n.text("apple.chatcontext.no_listed_servers"))
                    } else {
                        note(inspection.mcpReported ? L10n.text("apple.chatcontext.no_reported_servers") : L10n.text("apple.chatcontext.no_configured_servers"))
                    }
                } else {
                    let connected = inspection.mcpServers.filter { $0.source == "agent" && $0.status == "connected" }
                    let others = inspection.mcpServers.filter { $0.source != "agent" || $0.status != "connected" }
                    if !connected.isEmpty {
                        if serversOpen {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(connected) { server in serverRow(server) }
                            }
                        }
                    }
                    if !serversOpen {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(model.inspectionIsLive
                                 ? L10n.text("common.chat.stats.connected_count", connected.count.formatted())
                                 : L10n.text("common.chat.stats.connected_servers", connected.count.formatted()))
                            Spacer(minLength: 8)
                            if !others.isEmpty { Text(L10n.text("common.chat.stats.other_count", others.count.formatted())) }
                        }.font(Theme.caption).foregroundStyle(.secondary)
                    }
                    if serversOpen && !others.isEmpty {
                        ChatDisclosureRow(title: L10n.text("common.chat.stats.other_servers", others.count.formatted()), expanded: $otherServersOpen)
                        if otherServersOpen {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(others) { server in serverRow(server) }
                            }
                        }
                    }
                }
                if serversOpen {
                    if inspection.inventoryPartial == true { note(L10n.text("apple.chatcontext.inventory_partial")) }
                    if inspection.mcpServers.contains(where: { $0.source == "configuration" }) {
                        note(L10n.text("apple.chatcontext.configuration_note"))
                    } else if inspection.mcpReported {
                        note(L10n.text("apple.chatcontext.connection_note"))
                    }
                }
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder private var unavailable: some View {
        if model.currentActivityRead?.loaded == false {
            ProgressView().controlSize(.small)
        } else {
            note(owner.saved ? L10n.text("apple.chatcontext.saved_unavailable") : L10n.text("apple.chatcontext.host_unavailable"))
        }
    }

    private func status(_ server: ChatInspection.Server) -> String {
        switch server.status {
        case "connected":
            return currentInspection?.hasLiveConnection(server, running: model.inspectionIsLive) == true
                ? L10n.text("apple.chatcontext.connected") : L10n.text("apple.chatcontext.reported_connected")
        case "configured": return L10n.text("apple.chatcontext.configured")
        case "disabled": return L10n.text("apple.chatcontext.disabled")
        case "starting": return L10n.text("apple.chatcontext.starting")
        case "authenticationRequired": return L10n.text("apple.chatcontext.needs_auth")
        case "failed": return L10n.text("apple.chatcontext.failed")
        case "cancelled": return L10n.text("apple.chatcontext.cancelled")
        case "notStarted": return L10n.text("apple.chatcontext.not_started")
        default: return L10n.text("apple.chatcontext.status_unknown")
        }
    }

    private func contextLegend(_ title: String, value: UInt64, total: UInt64, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.formatted()).monospacedDigit()
            Text((total > 0 ? Double(value) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
        }.font(Theme.caption)
    }

    private func serverRow(_ server: ChatInspection.Server) -> some View {
        let name = server.name.replacingOccurrences(of: "plugin:", with: "").replacingOccurrences(of: ":", with: " · ")
        let connected = server.source == "agent" && server.status == "connected"
        let live = currentInspection?.hasLiveConnection(server, running: model.inspectionIsLive) == true
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(live ? Theme.accent : connected ? Theme.accent.opacity(0.45) : Color.secondary)
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                Text(name).font(Theme.caption.weight(.medium)).lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 0)
                Text(status(server)).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(minHeight: 28).accessibilityElement(children: .ignore)
                .accessibilityLabel(name).accessibilityValue(status(server))
            if let tools = server.tools, !tools.isEmpty {
                toolList(tools, title: L10n.text("apple.chatcontext.server_tools", tools.count.formatted()))
            }
        }
        .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolList(_ tools: [String], title: String) -> some View {
        ChatToolBrowser(tools: tools, title: title).id(owner)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(_ title: String, symbol: String, expanded: Binding<Bool>, showsStatus: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: symbol).font(Theme.callout.weight(.semibold))
                        if showsStatus, let name = currentInspection?.model {
                            Text(name).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if showsStatus {
                        Text(model.selected?.running == true ? L10n.text("common.running") : L10n.text("common.idle"))
                            .font(Theme.caption.weight(.medium)).fixedSize()
                            .foregroundStyle(model.selected?.running == true ? Theme.accent : Color.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule())
                    }
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down").font(Theme.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: chatDisclosureHeight, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? L10n.text("common.collapse") : L10n.text("common.expand"))
            content()
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

private var chatDisclosureHeight: CGFloat {
    #if os(macOS)
    28
    #else
    44
    #endif
}

/// Prompt categories occupy their real share of the reported context window.
/// The unfilled track is available capacity, not a fabricated token category.
private struct ChatContextSplitBar: View {
    let inspection: ChatInspection
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.accentSoft).overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(inspection.contextSegments.enumerated()), id: \.offset) { index, fraction in
                        Rectangle().fill(index == 0 ? Theme.accent : index == 1 ? Theme.accent.opacity(0.55) : Theme.warning)
                            .frame(width: geometry.size.width * fraction)
                    }
                }.clipShape(Capsule())
            }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

/// A full-width, keyboard-accessible target; the chevron is only an indicator.
struct ChatDisclosureRow: View {
    let title: String
    @Binding var expanded: Bool
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack {
                Text(title).font(Theme.callout.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(Theme.caption)
            }
            .frame(maxWidth: .infinity, minHeight: chatDisclosureHeight, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? L10n.text("common.collapse") : L10n.text("common.expand"))
    }
}

private struct ChatToolBrowser: View {
    let tools: [String]
    let title: String
    @State private var expanded = false
    @State private var query = ""
    @State private var selectedGroup: String?
    private func group(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return L10n.text("common.chat.stats.agent_tools") }
        return tool.dropFirst(5).components(separatedBy: "__").first ?? tool
    }
    private var groups: [String] { Array(Set(tools.map(group))).sorted() }
    private var filtered: [String] {
        tools.filter { (selectedGroup == nil || group($0) == selectedGroup) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ChatDisclosureRow(title: title, expanded: $expanded)
            if expanded {
                ForEach(groups, id: \.self) { name in
                    Button { selectedGroup = selectedGroup == name ? nil : name } label: {
                        HStack {
                            Text(name).lineLimit(1)
                            Spacer()
                            Text(tools.filter { group($0) == name }.count.formatted()).monospacedDigit()
                            if selectedGroup == name { Image(systemName: "checkmark") }
                        }.font(Theme.caption).padding(8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                TextField(L10n.text("common.chat.stats.search_tools"), text: $query).textFieldStyle(.themedSmall)
                if selectedGroup != nil || !query.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(filtered, id: \.self) { Text($0).font(Theme.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
            }
        }
    }
}

private struct ChatContextHistory: View {
    let points: [ChatInspection.ContextPoint]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let peak = max(1, Double(points.map(\.tokens).max() ?? 1))
                Path { path in
                    for (index, point) in points.enumerated() {
                        let position = CGPoint(x: geometry.size.width * Double(index) / Double(max(1, points.count - 1)),
                                               y: geometry.size.height * (1 - Double(point.tokens) / peak))
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }.frame(height: 36).padding(.vertical, 4).accessibilityHidden(true)
            HStack {
                Text((points.first?.tokens ?? 0).formatted())
                Spacer()
                Text((points.last?.tokens ?? 0).formatted())
            }.font(Theme.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
