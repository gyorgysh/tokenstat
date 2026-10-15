// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Reads only while visible. A result belongs to the chat, backend and model
/// that requested it; navigating or opening a saved copy cancels publication.
struct ChatContextCard: View {
    @Bindable var model: ChatModel
    @State private var inspection: ChatInspection?
    @State private var loaded = false
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
        card(L10n.text("apple.chatcontext.context"), symbol: "chart.pie") {
            if let inspection = currentInspection {
                if let resolved = inspection.model {
                    Text(resolved).font(Theme.callout.weight(.medium)).textSelection(.enabled)
                }
                if let used = inspection.contextUsed {
                    HStack(alignment: .firstTextBaseline) {
                        Text(used.formatted()).font(Theme.title3.weight(.semibold)).monospacedDigit()
                        if let window = inspection.contextWindow {
                            Text(L10n.text("apple.chatcontext.of_tokens", window.formatted()))
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let fraction = inspection.fraction {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(Theme.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
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
                if let tools = inspection.tools { toolList(tools, title: L10n.text("apple.chatcontext.available_tools", tools.count.formatted())) }
                if !inspection.usedTools.isEmpty { toolList(inspection.usedTools, title: L10n.text("apple.chatcontext.used_tools", inspection.usedTools.count.formatted())) }
                if let stamp = inspection.observedAtMs {
                    Text(L10n.text("apple.chatcontext.reported_at", Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)))
                        .font(Theme.caption).foregroundStyle(.tertiary)
                }
            } else {
                unavailable
            }
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
                    ForEach(inspection.mcpServers) { server in
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(server.name).font(Theme.callout.weight(.medium)).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Text(status(server)).font(Theme.caption)
                                    .foregroundStyle(inspection.hasLiveConnection(server, running: model.selected?.running == true) ? Theme.accent : Color.secondary)
                            }
                            if let tools = server.tools {
                                toolList(tools, title: L10n.text("apple.chatcontext.server_tools", tools.count.formatted()))
                            }
                        }
                        if server.id != inspection.mcpServers.last?.id { Divider().overlay(Theme.border) }
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

    private func toolList(_ tools: [String], title: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(tools, id: \.self) { tool in
                    Text(tool).font(Theme.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
        }
        .tint(Theme.controlGlyph)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(title, systemImage: symbol).font(Theme.callout.weight(.semibold))
            content()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}
