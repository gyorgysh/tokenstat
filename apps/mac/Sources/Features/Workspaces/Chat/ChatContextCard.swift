// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Reads only while visible. A result belongs to the chat, backend and model
/// that requested it; navigating or opening a saved copy cancels publication.
struct ChatContextCard: View {
    @Bindable var model: ChatModel
    @State private var inspection: ChatInspection?
    @State private var loaded = false
    @State private var otherServersOpen = false
    @State private var inspectedOwner: Owner?

    private struct Owner: Hashable {
        var reference: WorkReference?
        var backend: String?
        var model: String?
        var saved: Bool
    }
    private var owner: Owner {
        Owner(reference: model.currentReference, backend: model.selected?.backend,
              model: model.selected?.model, saved: model.savedCopy != nil)
    }

    private var currentInspection: ChatInspection? { inspectedOwner == owner ? inspection : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            context
            servers
        }
        .task(id: owner) {
            let requested = owner
            inspection = nil
            loaded = false
            inspectedOwner = requested
            otherServersOpen = false
            guard !requested.saved, let id = requested.reference?.itemID else { loaded = true; return }
            let peer = model.peer
            while !Task.isCancelled, owner == requested {
                do {
                    let next = try await Bridge.chatInspection(id: id, peer: peer)
                    guard !Task.isCancelled, owner == requested, next.backend == requested.backend else { return }
                    inspection = next
                    loaded = true
                } catch {
                    guard !Task.isCancelled, owner == requested else { return }
                    inspection = nil
                    loaded = true
                    // An older host can still run this chat. Do not keep
                    // sending an unsupported method every five seconds.
                    if case let BridgeError.core(code, _) = error, code == "unknown_method" { return }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private var context: some View {
        card(L10n.text("common.chat.stats"), symbol: "chart.pie", showsStatus: true) {
            if let inspection = currentInspection {
                if let resolved = inspection.model {
                    Text(resolved).font(Theme.callout.weight(.medium)).textSelection(.enabled)
                }
                if let used = inspection.contextUsed {
                    HStack(alignment: .firstTextBaseline) {
                        contextAmount(used, window: inspection.contextWindow)
                        Spacer(minLength: 8)
                        if let fraction = inspection.fraction {
                            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                                .font(Theme.caption.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(fraction > 0.9 ? Theme.warning : Theme.accent)
                                .fixedSize()
                        }
                    }
                    if let fraction = inspection.fraction {
                        ProgressView(value: fraction).tint(fraction > 0.9 ? Theme.warning : Theme.accent)
                            .accessibilityLabel(L10n.text("apple.chatcontext.context"))
                            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                    note(L10n.text("apple.chatcontext.last_prompt"))
                } else {
                    note(L10n.text("apple.chatcontext.context_unknown"))
                    if let window = inspection.contextWindow {
                        Text(L10n.text("apple.chatcontext.window_tokens", window.formatted()))
                            .font(Theme.callout).monospacedDigit()
                    }
                }
                if inspection.windowSource == "catalog" { note(L10n.text("apple.chatcontext.catalog_window")) }
                if let breakdown = inspection.contextBreakdown {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("common.chat.stats.last_prompt")).font(Theme.caption.weight(.medium))
                        promptRow(L10n.text("common.chat.stats.input"), value: breakdown.input)
                        promptRow(L10n.text("common.chat.stats.cache_read"), value: breakdown.cacheRead)
                        promptRow(L10n.text("common.chat.stats.cache_write"), value: breakdown.cacheWrite)
                        note(L10n.text("common.chat.stats.prompt_note"))
                    }
                }
                if let history = inspection.contextHistory, history.count > 1 {
                    ChatContextHistory(points: history)
                }
                if let tools = inspection.tools { toolList(tools, title: L10n.text("common.chat.stats.available_tools", tools.count.formatted())) }
                if !inspection.usedTools.isEmpty { toolList(inspection.usedTools, title: L10n.text("apple.chatcontext.used_tools", inspection.usedTools.count.formatted())) }
                if let stamp = inspection.observedAtMs {
                    Text(L10n.text("apple.chatcontext.reported_at", Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)))
                        .font(Theme.caption).foregroundStyle(.tertiary)
                }
            } else {
                unavailable
            }
            Divider().overlay(Theme.border)
            ChatCostMeter(totals: model.turnUsage)
        }
    }

    private var servers: some View {
        card(L10n.text("apple.chatcontext.mcp_servers"), symbol: "puzzlepiece.extension") {
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
                        Text(L10n.text("common.chat.stats.connected_servers", connected.count.formatted()))
                            .font(Theme.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(connected) { server in serverRow(server) }
                        }
                    }
                    if !others.isEmpty {
                        ChatDisclosureRow(title: L10n.text("common.chat.stats.other_servers", others.count.formatted()), expanded: $otherServersOpen)
                        if otherServersOpen {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(others) { server in serverRow(server) }
                            }
                        }
                    }
                }
                if inspection.inventoryPartial == true { note(L10n.text("apple.chatcontext.inventory_partial")) }
                if inspection.mcpServers.contains(where: { $0.source == "configuration" }) {
                    note(L10n.text("apple.chatcontext.configuration_note"))
                } else if inspection.mcpReported {
                    note(L10n.text("apple.chatcontext.connection_note"))
                }
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder private var unavailable: some View {
        if !loaded || inspectedOwner != owner {
            ProgressView().controlSize(.small)
        } else {
            note(owner.saved ? L10n.text("apple.chatcontext.saved_unavailable") : L10n.text("apple.chatcontext.host_unavailable"))
        }
    }

    private func status(_ server: ChatInspection.Server) -> String {
        switch server.status {
        case "connected":
            return currentInspection?.hasLiveConnection(server, running: model.selected?.running == true) == true
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

    private func promptRow(_ title: String, value: UInt64) -> some View {
        HStack { Text(title); Spacer(minLength: 8); Text(value.formatted()).monospacedDigit() }
            .font(Theme.caption).foregroundStyle(.secondary)
    }

    private func contextAmount(_ used: UInt64, window: UInt64?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(used.formatted()).font(Theme.title3.weight(.semibold)).monospacedDigit().fixedSize()
                if let window {
                    note(L10n.text("apple.chatcontext.of_tokens", window.formatted())).fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(used.formatted()).font(Theme.title3.weight(.semibold)).monospacedDigit()
                if let window { note(L10n.text("apple.chatcontext.of_tokens", window.formatted())) }
            }
        }
    }

    private func serverRow(_ server: ChatInspection.Server) -> some View {
        let reportedConnected = server.source == "agent" && server.status == "connected"
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(reportedConnected ? Theme.accent : Color.secondary)
                    .frame(width: 7, height: 7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name.replacingOccurrences(of: "plugin:", with: "").replacingOccurrences(of: ":", with: " · "))
                        .font(Theme.callout.weight(.medium)).textSelection(.enabled)
                        .accessibilityValue(status(server))
                    if !reportedConnected {
                        Text(status(server)).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 28)
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

    private func card<Content: View>(_ title: String, symbol: String, showsStatus: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(Theme.callout.weight(.semibold))
                if showsStatus {
                    Spacer(minLength: 8)
                    Text(model.selected?.running == true ? L10n.text("common.running") : L10n.text("common.idle"))
                        .font(Theme.caption.weight(.medium)).fixedSize()
                        .foregroundStyle(model.selected?.running == true ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
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
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
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
                TextField(L10n.text("common.chat.stats.search_tools"), text: $query).textFieldStyle(.roundedBorder)
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
            Text(L10n.text("common.chat.stats.history")).font(Theme.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let peak = max(1, Double(points.map(\.tokens).max() ?? 1))
                Path { path in
                    for (index, point) in points.enumerated() {
                        let position = CGPoint(x: geometry.size.width * Double(index) / Double(max(1, points.count - 1)),
                                               y: geometry.size.height * (1 - Double(point.tokens) / peak))
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }.frame(height: 48).padding(.vertical, 4).accessibilityHidden(true)
            HStack {
                Text((points.first?.tokens ?? 0).formatted())
                Spacer()
                Text((points.last?.tokens ?? 0).formatted())
            }.font(Theme.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(L10n.text("common.chat.stats.history_note")).font(Theme.caption).foregroundStyle(.tertiary)
        }
    }
}
