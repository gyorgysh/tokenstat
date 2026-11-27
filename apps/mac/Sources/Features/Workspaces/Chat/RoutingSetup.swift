// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct RoutingSetup: View {
    enum Context {
        case chat(ChatModel, ChatConversation)
        case defaults(peer: String?)
    }

    private enum Step: Hashable { case behavior, agents, finish }
    private enum Scope: Hashable { case everywhere, thisChat }

    let context: Context
    var onSaved: (ChatRoutingPolicy?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var policy = ChatRoutingPolicy()
    @State private var behavior = RoutingBehavior.ask
    @State private var scope = Scope.everywhere
    @State private var step = Step.behavior
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?
    @State private var backends: [ChatBackend] = []
    @State private var followsDefault: Bool?
    @State private var defaultPolicy: ChatRoutingPolicy?
    @State private var showingMore = false
    @State private var showingHistory = false
    @State private var activity: ChatRoutingActivityPage?
    @State private var activityLoading = false

    private var steps: [Step] { behavior.needsAgents ? [.behavior, .agents, .finish] : [.behavior, .finish] }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var isChat: Bool { if case .chat = context { true } else { false } }
    private var peer: String? {
        switch context {
        case .chat(let model, _): model.peer
        case .defaults(let peer): peer
        }
    }

    var body: some View {
        ThemedSheet(title: L10n.text("common.chat_routing"),
                    subtitle: isChat ? L10n.text("common.chat_routing_intro") : L10n.text("common.chat_route_settings_intro"),
                    icon: .routing, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    SetupStepDots(count: steps.count, index: index)
                    Spacer()
                    if isChat { scopeBadge }
                }
                if !loaded && failure == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            switch step {
                            case .behavior: behaviorStep
                            case .agents: agentsStep
                            case .finish: finishStep
                            }
                        }
                        .padding(.bottom, Theme.Space.s)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                        .id(step)
                    }
                }
                if let failure {
                    Text(failure).font(Theme.caption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(saving)
        } actions: {
            if index > 0 {
                Button(L10n.text("common.back"), .back) { move(-1) }
            } else {
                Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
            }
            if step == .finish {
                Button(saveTitle, .save) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || saving)
            } else {
                Button(L10n.text("common.next"), .next) { move(1) }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || (step == .agents && policy.routes.isEmpty))
            }
        }
        .toggleStyle(.brandCheckbox)
        .modalFrame(width: 600, height: 680)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { await load() }
    }

    @ViewBuilder
    private var scopeBadge: some View {
        if let followsDefault, defaultPolicy != nil {
            HStack(spacing: Theme.Space.s) {
                Label(followsDefault ? L10n.text("common.chat_route_follows_default") : L10n.text("common.chat_route_own_routing"),
                      systemImage: followsDefault ? "link" : "pin")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                if !followsDefault {
                    Button(L10n.text("common.chat_route_use_default"), .refresh) { useDefault() }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
        }
    }

    private var behaviorStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            RoutingIllustration(behavior: behavior)
            header(L10n.text("common.chat_route_step_behavior_title"), L10n.text("common.chat_route_step_behavior_detail"))
            ForEach(RoutingBehavior.allCases) { option in
                SetupChoiceCard(symbol: option.symbol, title: option.title, detail: option.detail,
                                selected: behavior == option) {
                    withAnimation(.easeInOut(duration: 0.2)) { behavior = option }
                }
            }
        }
    }

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header(L10n.text("common.chat_route_step_agents_title"), L10n.text("common.chat_route_step_agents_detail"))
            ForEach(policy.routes.indices, id: \.self) { index in routeRow(index) }
            if policy.routes.isEmpty {
                Text(L10n.text("common.chat_route_need_agent")).font(Theme.caption).foregroundStyle(.secondary)
            }
            if policy.routes.count < 8, !available.isEmpty {
                Menu {
                    ForEach(available) { backend in
                        Button(backend.label, .create) {
                            withAnimation { policy.routes.append(ChatRouteDestination(backend: backend.id)) }
                        }
                    }
                } label: {
                    Label(L10n.text("common.chat_route_add_agent"), systemImage: "plus")
                        .font(Theme.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if isChat {
                header(L10n.text("common.chat_route_step_scope_title"), L10n.text("common.chat_route_step_scope_detail"))
                SetupChoiceCard(symbol: "rectangle.stack", title: L10n.text("common.chat_route_scope_all"),
                                detail: L10n.text("common.chat_route_scope_all_detail"), selected: scope == .everywhere) {
                    scope = .everywhere
                }
                SetupChoiceCard(symbol: "bubble.left", title: L10n.text("common.chat_route_scope_chat"),
                                detail: L10n.text("common.chat_route_scope_chat_detail"), selected: scope == .thisChat) {
                    scope = .thisChat
                }
            } else {
                header(L10n.text("common.chat_route_step_review_title"), L10n.text("common.chat_route_settings_scope"))
            }
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: behavior.symbol).foregroundStyle(Theme.accent)
                Text(behavior.summary(agents: policy.routes.map(label)))
                    .font(Theme.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            DisclosureGroup(L10n.text("common.chat_route_more_options"), isExpanded: $showingMore) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(L10n.text("common.chat_route_throttle"), isOn: $policy.failoverOnThrottle)
                    Toggle(L10n.text("common.chat_route_errors"), isOn: $policy.failoverOnErrors)
                    Toggle(L10n.text("common.chat_route_auth"), isOn: $policy.failoverOnAuth)
                    Toggle(L10n.text("common.chat_route_agent_errors"), isOn: $policy.failoverOnFailures)
                    Toggle(L10n.text("common.chat_route_notify"), isOn: Binding(get: { policy.notify ?? true }, set: { policy.notify = $0 }))
                }
                .padding(.top, Theme.Space.s)
            }
            if case .chat = context { history }
        }
    }

    private var history: some View {
        DisclosureGroup(L10n.text("common.chat_route_history"), isExpanded: $showingHistory) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                let entries = activity?.activity ?? []
                if entries.isEmpty {
                    Text(L10n.text("common.chat_route_empty_history")).foregroundStyle(.secondary)
                }
                ForEach(Array(entries.enumerated()).reversed(), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.label).fontWeight(.semibold)
                            Spacer(minLength: 0)
                            Text(Date(timeIntervalSince1970: Double(entry.atMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.reason).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ThemeRule()
                }
                if activity?.cursor != nil {
                    Button(L10n.text("common.chat_route_older"), .history) { Task { await loadActivity(older: true) } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(activityLoading)
                }
            }
            .font(Theme.caption)
            .padding(.top, Theme.Space.s)
        }
        .onChange(of: showingHistory) { _, open in if open { Task { await loadActivity() } } }
    }

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.font(17, weight: .semibold))
            Text(detail).font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func routeRow(_ index: Int) -> some View {
        let route = policy.routes[index]
        let backend = backend(route.backend)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("\(index + 1)")
                    .font(Theme.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accent))
                HarnessMark(id: route.backend, size: 24).accessibilityHidden(true)
                Text(label(route)).font(Theme.callout.weight(.semibold))
                Spacer(minLength: 0)
                AgentLimitsSummary(backend: route.backend, peer: peer)
                if index > 0 {
                    Button(L10n.text("common.move_up"), .move) { withAnimation { policy.routes.swapAt(index, index - 1) } }
                }
                Button(L10n.text("common.remove"), .delete) {
                    withAnimation {
                        if policy.preferred == policy.routes[index] { policy.preferred = nil }
                        _ = policy.routes.remove(at: index)
                    }
                }
            }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .environment(\.compactActions, true)
            if let backend {
                HStack(spacing: Theme.Space.m) {
                    AppMenuPicker(title: L10n.text("apple.favoritemodelpicker.model.5e2c614c"),
                        options: [(value: "", label: L10n.text("apple.chatsetupheader.default.21b111cb"))]
                            + Array(Set(backend.models + [route.model].compactMap { $0 }.filter { !$0.isEmpty })).sorted().map { (value: $0, label: $0) },
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
            if case .chat(_, let chat) = context, route.backend == "muse", chat.autonomy != "bypass" {
                Text(L10n.text("common.chat_route_permissions")).font(Theme.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    private var available: [ChatBackend] {
        backends.filter { candidate in
            candidate.id != "sh" && candidate.installed != false
                && !policy.routes.contains { $0.backend == candidate.id }
        }
    }

    private var saveTitle: String {
        guard isChat else { return L10n.text("common.save") }
        return scope == .everywhere ? L10n.text("common.chat_route_save_default") : L10n.text("common.chat_route_save_chat")
    }

    private func backend(_ id: String) -> ChatBackend? { backends.first { $0.id == id } }

    private func label(_ route: ChatRouteDestination) -> String {
        backend(route.backend)?.label ?? route.backend
    }

    private func setRoute(_ index: Int, model value: String? = nil, effort: String? = nil) {
        guard policy.routes.indices.contains(index) else { return }
        let preferred = policy.preferred == policy.routes[index]
        if let value { policy.routes[index].model = value.isEmpty ? nil : value }
        if let effort { policy.routes[index].effort = effort.isEmpty ? nil : effort }
        if preferred { policy.preferred = policy.routes[index] }
    }

    private func move(_ delta: Int) {
        let next = min(max(index + delta, 0), steps.count - 1)
        withAnimation(.easeInOut(duration: 0.25)) { step = steps[next] }
    }

    private func load() async {
        failure = nil
        switch context {
        case .chat(let model, let chat):
            guard let owner = model.currentReference, model.selected?.id == chat.id else { return }
            let success = await model.routing()
            guard !Task.isCancelled, model.currentReference == owner, model.selected?.id == chat.id else { return }
            guard success, let state = model.selected?.routing else {
                failure = model.error ?? L10n.text("common.chat_route_load_failed")
                return
            }
            backends = model.backends
            followsDefault = state.followsDefault
            defaultPolicy = state.defaultPolicy
            apply(state.policy)
            if let follows = state.followsDefault {
                scope = follows ? .everywhere : .thisChat
            } else {
                scope = state.policy.useAsDefault ? .everywhere : .thisChat
            }
        case .defaults(let peer):
            do {
                async let agents = Bridge.chatBackends(peer: peer)
                let saved = try await Bridge.routingDefaults(peer: peer)
                backends = try await agents
                apply(saved ?? ChatRoutingPolicy())
            } catch {
                failure = error.localizedDescription
                return
            }
        }
        loaded = true
    }

    private func apply(_ value: ChatRoutingPolicy) {
        policy = value
        behavior = RoutingBehavior(value)
    }

    private func save() {
        var submitted = policy
        behavior.apply(to: &submitted)
        if !behavior.needsAgents { submitted.preferred = nil }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            switch context {
            case .chat(let model, let chat):
                guard let owner = model.currentReference, model.selected?.id == chat.id else { return }
                submitted.useAsDefault = scope == .everywhere
                let saved = await model.routing(policy: submitted)
                guard model.currentReference == owner else { return }
                if saved { onSaved(submitted); dismiss() }
                else { failure = model.error ?? L10n.text("common.chat_route_load_failed") }
            case .defaults(let peer):
                do {
                    let stored = try await Bridge.saveRoutingDefaults(submitted, peer: peer)
                    onSaved(stored)
                    dismiss()
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }

    private func useDefault() {
        guard let defaultPolicy else { return }
        apply(defaultPolicy)
        scope = .everywhere
        withAnimation { step = .finish }
    }

    private func loadActivity(older: Bool = false) async {
        guard case .chat(let model, let chat) = context, !activityLoading else { return }
        activityLoading = true
        defer { activityLoading = false }
        var params: [String: Any] = ["id": chat.id]
        if older, let cursor = activity?.cursor { params["cursor"] = cursor }
        if let page = try? await Bridge.chatInvoke(peer: model.peer, "chat.routingHistory", params, as: ChatRoutingActivityPage.self) {
            activity = page
        }
    }
}
