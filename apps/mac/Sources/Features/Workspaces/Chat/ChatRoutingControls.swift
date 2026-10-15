// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct ChatRoutingControls: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var title: String? = nil
    var prominent = false
    var compact = false
    @State private var showing = false
    private var automatic: Bool {
        chat.routing?.policy.enabled == true || chat.routing?.policy.waitForReset == true
    }
    private var mode: String {
        let policy = chat.routing?.policy ?? ChatRoutingPolicy()
        return L10n.text(policy.enabled
            ? (policy.waitForReset ? "common.chat_route_combined_mode" : "common.chat_route_fallback_mode")
            : (policy.waitForReset ? "common.chat_route_wait_mode" : "common.chat_route_manual"))
    }
    var body: some View {
        Group {
            if compact {
                action
                    .environment(\.compactActions, true)
                    .buttonStyle(.plain)
                    .font(Theme.callout)
                    #if os(macOS)
                    .frame(width: 28, height: 28)
                    #else
                    .frame(width: 44, height: 44)
                    #endif
                    .foregroundStyle(automatic ? Theme.accent : .secondary)
                    .background(automatic ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(.rect)
                    .help(L10n.text("common.chat_routing_intro"))
                    .accessibilityLabel(L10n.text("common.chat_routing"))
                    .accessibilityHint(L10n.text("common.chat_routing_intro"))
                    .accessibilityValue(mode)
                    .accessibilityIdentifier("chat.routing")
            }
            else if prominent { action.buttonStyle(AccentButtonStyle()) }
            else { action.buttonStyle(SecondaryButtonStyle(small: true)) }
        }
            .disabled(model.savedCopy != nil)
            .sheet(isPresented: $showing) { ChatRoutingSheet(model: model, chat: chat) }
    }
    private var action: some View {
        Button(title ?? L10n.text("common.chat_routing"), compact ? .routing : .settings) { showing = true }
    }
}
struct ChatRoutingSection: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    private var policy: ChatRoutingPolicy { chat.routing?.policy ?? ChatRoutingPolicy() }
    private var summary: String {
        L10n.text(policy.enabled
            ? (policy.waitForReset ? "common.chat_route_combined_mode" : "common.chat_route_fallback_mode")
            : (policy.waitForReset ? "common.chat_route_wait_mode" : "common.chat_route_manual"))
    }
    var body: some View {
        ChatSetupSection(title: L10n.text("common.chat_routing"), icon: .settings,
                         subtitle: L10n.text("common.chat_routing_intro"), summary: summary) {
            if !policy.routes.isEmpty {
                Text(policy.routes.map { model.backend(for: $0.backend)?.label ?? $0.backend }.joined(separator: " → "))
                    .font(Theme.caption).fixedSize(horizontal: false, vertical: true)
            }
            if policy.returnPreferred {
                Text(L10n.text("common.chat_route_preferred", model.backend(for: policy.preferred?.backend ?? chat.routing?.preferred?.backend ?? chat.backend)?.label ?? chat.backend))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            ChatRoutingControls(model: model, chat: chat, title: L10n.text("common.chat_route_setup"), prominent: true)
        }

    }
}
struct ChatRoutingNotice: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var body: some View {
        if let state = chat.routing, let limit = state.limit {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(limit.kind == "usage" ? L10n.text("common.chat_limit_reached", limit.provider.capitalized) : limit.kind == "throttle" ? L10n.text("common.chat_throttled", limit.provider.capitalized) : L10n.text("common.chat_route_failure", limit.provider.capitalized))
                    .font(Theme.callout.weight(.semibold))
                if let instant = limit.resetsAtMs {
                    Text(L10n.text("common.chat_resets_at", Date(timeIntervalSince1970: Double(instant) / 1000).formatted(date: .abbreviated, time: .shortened)))
                } else { Text(L10n.text("common.chat_reset_unknown")) }
                if let reset = state.nextReset, reset.destination.backend != limit.provider {
                    Text(L10n.text("common.chat_route_waiting_for", reset.destination.backend.capitalized, Date(timeIntervalSince1970: Double(reset.atMs) / 1000).formatted(date: .abbreviated, time: .shortened)))
                }
                Text(limit.reason).textSelection(.enabled)
                if state.needsDeliveryCheck { Text(L10n.text("common.chat_route_delivery")) }
                if let note = state.note { Text(note).font(Theme.caption) }
                Toggle(L10n.text("common.chat_wait_reset"), isOn: Binding(
                    get: { state.policy.waitForReset }, set: { value in
                        var policy = state.policy; policy.waitForReset = value
                        change(policy: policy)
                    }))
                    .toggleStyle(.brandCheckbox)
                    .disabled((limit.resetsAtMs == nil && state.nextReset == nil) || state.needsDeliveryCheck)
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("common.chat_route_retry"), .refresh) { change(action: "resume") }
                        .disabled(chat.running || state.needsDeliveryCheck)
                    ChatRoutingControls(model: model, chat: chat)
                    if state.waiting {
                        Button(L10n.text("common.cancel"), .dismiss) { change(action: "cancel") }
                    }
                }.buttonStyle(SecondaryButtonStyle(small: true))
            }
            .font(Theme.caption).padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func change(policy: ChatRoutingPolicy? = nil, action: String? = nil) {
        guard let owner = model.currentReference, model.selected?.id == chat.id else { return }
        Task {
            guard model.currentReference == owner, model.selected?.id == chat.id else { return }
            _ = await model.routing(policy: policy, action: action)
        }
    }
}
private struct ChatRoutingSheet: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @Environment(\.dismiss) private var dismiss
    @State private var policy = ChatRoutingPolicy()
    @State private var loaded = false
    @State private var saving = false
    @State private var adding = ""
    @State private var loadFailed = false
    @State private var showingHistory = false
    @State private var activityPage: ChatRoutingActivityPage?
    @State private var activityLoading = false
    @State private var activityError: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private var stackRouteChoices: Bool {
        #if os(iOS)
        sizeClass == .compact || typeSize.isAccessibilitySize
        #else
        typeSize.isAccessibilitySize
        #endif
    }

    var body: some View {
        ThemedSheet(title: L10n.text("common.chat_routing"), subtitle: L10n.text("common.chat_route_explanation"), icon: .settings,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Toggle(L10n.text("common.chat_routing_enabled"), isOn: $policy.enabled)
                ThemeRule()
                Text(L10n.text("common.chat_route_order")).font(Theme.callout.weight(.semibold))
                ForEach(policy.routes.indices, id: \.self) { index in routeRow(index) }
                AppMenuPicker(title: L10n.text("apple.chatsetupheader.agent.11b39c93"),
                    options: [(value: "", label: L10n.text("common.add"))] + model.backends.filter { $0.id != "sh" && $0.installed != false }.map { (value: $0.id, label: $0.label) },
                    selection: $adding)
                    .disabled(policy.routes.count >= 8 || !loaded)
                    .onChange(of: adding) { _, backend in
                        guard !backend.isEmpty else { return }
                        policy.routes.append(ChatRouteDestination(backend: backend))
                        adding = ""
                    }
                Text(L10n.text("common.chat_route_policy_help")).font(Theme.caption).foregroundStyle(.secondary)
                ThemeRule()
                Toggle(L10n.text("common.chat_wait_reset"), isOn: $policy.waitForReset)
                Text(L10n.text("common.chat_route_priority_help")).font(Theme.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("common.chat_return_preferred"), isOn: $policy.returnPreferred)
                if policy.returnPreferred {
                    AppMenuPicker(title: L10n.text("common.chat_route_preferred_picker"),
                        options: [(value: -1, label: L10n.text("common.chat_route_current_preferred"))] + policy.routes.enumerated().map { index, route in
                            (value: index, label: [model.backend(for: route.backend)?.label ?? route.backend, route.model, route.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        }, selection: Binding(get: { policy.routes.firstIndex(where: { $0 == policy.preferred }) ?? -1 }, set: { policy.preferred = policy.routes.indices.contains($0) ? policy.routes[$0] : nil }))
                    Text(L10n.text("common.chat_route_preferred", model.backend(for: policy.preferred?.backend ?? model.selected?.routing?.preferred?.backend ?? chat.backend)?.label ?? chat.backend))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.text("common.settings")) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Toggle(L10n.text("common.chat_route_throttle"), isOn: $policy.failoverOnThrottle)
                        Toggle(L10n.text("common.chat_route_errors"), isOn: $policy.failoverOnErrors)
                        Toggle(L10n.text("common.chat_route_auth"), isOn: $policy.failoverOnAuth)
                        Toggle(L10n.text("common.chat_route_agent_errors"), isOn: $policy.failoverOnFailures)
                        Toggle(L10n.text("common.chat_route_notify"), isOn: Binding(get: { policy.notify ?? true }, set: { policy.notify = $0 }))
                    }.padding(.top, Theme.Space.s)
                }
                Toggle(L10n.text("common.chat_route_default"), isOn: $policy.useAsDefault)
                routingActivity
                if loadFailed { Text(L10n.text("common.chat_route_load_failed")).font(Theme.caption).foregroundStyle(Theme.warning) }
                if let error = model.error { Text(error).font(Theme.caption).foregroundStyle(Theme.warning) }
            }
            .disabled(!loaded || saving)
        } actions: {
            if loadFailed { Button(L10n.text("common.retry"), .refresh) { Task { await loadPolicy() } } }
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
            Button(L10n.text("common.save"), .save) {
                guard let owner = model.currentReference, model.selected?.id == chat.id else { return }
                let submitted = policy
                saving = true
                Task {
                    defer { saving = false }
                    guard model.currentReference == owner, model.selected?.id == chat.id else { return }
                    if await model.routing(policy: submitted) { dismiss() }
                }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!loaded || saving)
        }
        .toggleStyle(.brandCheckbox)
        .disclosureGroupStyle(ChatRoutingDisclosureStyle())
        .modalFrame(width: 600, height: min(760, 500 + CGFloat(policy.routes.count) * 110))
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .onChange(of: model.selected?.id) { _, id in if id != chat.id { dismiss() } }
        .onChange(of: model.currentReference) { _, _ in dismiss() }
        .task(id: model.selected?.sendRevision) { if !loaded { await loadPolicy() } }
    }

    private func loadPolicy() async {
        guard let owner = model.currentReference, model.selected?.id == chat.id else { return }
        loadFailed = false
        let success = await model.routing()
        guard !Task.isCancelled, model.currentReference == owner, model.selected?.id == chat.id else { return }
        if success { policy = model.selected?.routing?.policy ?? ChatRoutingPolicy(); loaded = true }
        else { loadFailed = true }
    }

    private var routingActivity: some View {
        DisclosureGroup(L10n.text("common.chat_route_history"), isExpanded: $showingHistory) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if (activityPage?.activity ?? model.selected?.routing?.activity ?? []).isEmpty {
                    Text(L10n.text("common.chat_route_empty_history")).foregroundStyle(.secondary)
                }
                ForEach(Array((activityPage?.activity ?? model.selected?.routing?.activity ?? []).enumerated()).reversed(), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack {
                            Text(entry.label).fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Text(Date(timeIntervalSince1970: Double(entry.atMs) / 1000).formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                        if let target = entry.target {
                            Text([entry.source.map { "\($0.backend) → \(target.backend)" } ?? target.backend, target.model, target.effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        } else if let source = entry.source { Text(source.backend) }
                        Text(entry.reason).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ThemeRule()
                }
                if let error = activityError { Text(error).foregroundStyle(Theme.warning) }
                HStack {
                    Button(L10n.text("common.refresh"), .refresh) { Task { await loadActivity() } }
                    if activityPage?.cursor != nil { Button(L10n.text("common.chat_route_older"), .history) { Task { await loadActivity(older: true) } } }
                }.buttonStyle(SecondaryButtonStyle(small: true)).disabled(activityLoading)
            }.font(Theme.caption).padding(.top, Theme.Space.s)
        }
        .onChange(of: showingHistory) { _, expanded in if expanded { Task { await loadActivity() } } }
    }

    private func loadActivity(older: Bool = false) async {
        guard !activityLoading, model.selected?.id == chat.id else { return }
        let owner = model.currentReference
        activityLoading = true
        defer { activityLoading = false }
        do {
            var params: [String: Any] = ["id": chat.id]
            if older, let cursor = activityPage?.cursor { params["cursor"] = cursor }
            let page = try await Bridge.chatInvoke(peer: model.peer, "chat.routingHistory", params, as: ChatRoutingActivityPage.self)
            guard owner == model.currentReference, model.selected?.id == chat.id else { return }
            activityPage = page
            activityError = nil
        } catch { if owner == model.currentReference { activityError = error.localizedDescription } }
    }

    private func routeRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("\(index + 1). \(model.backend(for: policy.routes[index].backend)?.label ?? policy.routes[index].backend)")
                    .font(Theme.callout.weight(.semibold))
                Spacer(minLength: 0)
                if index > 0 {
                    Button(L10n.text("common.move_up"), .move) { policy.routes.swapAt(index, index - 1) }
                }
                Button(L10n.text("common.remove"), .delete) {
                    if policy.preferred == policy.routes[index] { policy.preferred = nil }
                    policy.routes.remove(at: index)
                }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .environment(\.compactActions, true)
            if ["muse", "sh"].contains(policy.routes[index].backend), chat.autonomy != "bypass" {
                Text(L10n.text("common.chat_route_permissions")).font(Theme.caption).foregroundStyle(Theme.warning)
            }
            if let backend = model.backend(for: policy.routes[index].backend) {
                if stackRouteChoices {
                    VStack(alignment: .leading, spacing: Theme.Space.s) { routeChoices(index, backend) }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Theme.Space.l) { routeChoices(index, backend) }
                        VStack(alignment: .leading, spacing: Theme.Space.s) { routeChoices(index, backend) }
                    }
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func setRoute(_ index: Int, model value: String? = nil, effort: String? = nil) {
        guard policy.routes.indices.contains(index) else { return }
        let preferred = policy.preferred == policy.routes[index]
        if let value { policy.routes[index].model = value.isEmpty ? nil : value }
        if let effort { policy.routes[index].effort = effort.isEmpty ? nil : effort }
        if preferred { policy.preferred = policy.routes[index] }
    }

    @ViewBuilder
    private func routeChoices(_ index: Int, _ backend: ChatBackend) -> some View {
        AppMenuPicker(title: L10n.text("apple.favoritemodelpicker.model.5e2c614c"),
            options: [(value: "", label: L10n.text("apple.chatsetupheader.default.21b111cb"))] + Array(Set(backend.models + [policy.routes[index].model].compactMap { $0 }.filter { !$0.isEmpty })).sorted().map { (value: $0, label: $0) },
            selection: Binding(get: { policy.routes.indices.contains(index) ? policy.routes[index].model ?? "" : "" },
                               set: { setRoute(index, model: $0) }))
        if !backend.efforts.isEmpty {
            AppMenuPicker(title: L10n.text("apple.chatsetupheader.effort.4387e5d3"),
                options: [(value: "", label: L10n.text("apple.chatsetupheader.default.21b111cb"))] + backend.efforts.map { (value: $0, label: $0) },
                selection: Binding(get: { policy.routes.indices.contains(index) ? policy.routes[index].effort ?? "" : "" },
                                   set: { setRoute(index, effort: $0) }))
        }
    }
}

/// The full header is the expansion target, including its empty space.
private struct ChatRoutingDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: Theme.Space.s) {
                    configuration.label.font(Theme.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(configuration.isExpanded ? L10n.text("common.collapse") : L10n.text("common.expand"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
