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
            .disabled(model.savedCopy != nil || model.isSharedSource)
            .sheet(isPresented: $showing) { RoutingSetup(context: .chat(model, chat)) }
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
                         subtitle: L10n.text("common.chat_routing_intro"), summary: summary,
                         primary: ChatRoutingControls(model: model, chat: chat, title: L10n.text("common.chat_route_setup"))) {
            if !policy.routes.isEmpty {
                Text(policy.routes.map { model.backend(for: $0.backend)?.label ?? $0.backend }.joined(separator: " → "))
                    .font(Theme.caption).fixedSize(horizontal: false, vertical: true)
            }
            if policy.returnPreferred {
                Text(L10n.text("common.chat_route_preferred", model.backend(for: policy.preferred?.backend ?? chat.routing?.preferred?.backend ?? chat.backend)?.label ?? chat.backend))
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }

    }
}
struct ChatRoutingNotice: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @State private var pendingWait: Bool?
    @State private var saving = false
    @State private var failure: String?
    @State private var showingRouting = false

    var body: some View {
        if let state = chat.routing, let limit = state.limit {
            let waitAvailable = (limit.resetsAtMs != nil || state.nextReset != nil) && !state.needsDeliveryCheck
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Image(systemName: limit.kind == "usage" ? "hourglass" : "exclamationmark.triangle.fill")
                        .font(Theme.font(14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(LinearGradient(colors: [Theme.danger, Theme.danger.opacity(0.75)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(limit))
                            .font(Theme.font(15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(resetLine(limit))
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if !limit.reason.isEmpty {
                    Text(limit.reason)
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reset = state.nextReset, reset.destination.backend != limit.provider {
                    Text(L10n.text("common.chat_route_waiting_for", reset.destination.backend.capitalized, Date(timeIntervalSince1970: Double(reset.atMs) / 1000).formatted(date: .abbreviated, time: .shortened)))
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                if state.needsDeliveryCheck {
                    Text(L10n.text("common.chat_route_delivery")).font(Theme.caption).foregroundStyle(Theme.warning)
                }
                if let note = state.note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
                waitOption(state: state, available: waitAvailable)
                if let failure {
                    Text(failure).font(Theme.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionGrid(state: state, limit: limit)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: 1))
            .padding(.vertical, Theme.Space.xs)
            .onChange(of: state.policy.waitForReset) { _, value in
                if pendingWait == value { pendingWait = nil }
            }
            .sheet(isPresented: $showingRouting) { RoutingSetup(context: .chat(model, chat)) }
        }
    }

    private enum Action: Hashable { case handOff, retry, routing, cancel }

    @ViewBuilder
    private func actionGrid(state: ChatRoutingState, limit: ChatProviderLimit) -> some View {
        let actions: [Action] = [.handOff, .retry, .routing]
            + (state.waiting ? [.cancel] : [])
        let rows = stride(from: 0, to: actions.count, by: 2).map { Array(actions[$0..<min($0 + 2, actions.count)]) }
        Grid(horizontalSpacing: Theme.Space.s, verticalSpacing: Theme.Space.s) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { action in
                        actionButton(action, state: state, limit: limit)
                            .gridCellColumns(row.count == 1 ? 2 : 1)
                    }
                }
            }
        }
        .disabled(model.savedCopy != nil || model.isSharedSource)
    }

    @ViewBuilder
    private func actionButton(_ action: Action, state: ChatRoutingState, limit: ChatProviderLimit) -> some View {
        let busy = chat.running || saving || state.needsDeliveryCheck
        switch action {
        case .handOff:
            Button(L10n.text("common.chat_hand_off_now"), .routing) { handOff() }
                .buttonStyle(LimitActionStyle(prominent: true))
                .disabled(chat.running || saving)
        case .retry:
            Button(L10n.text("common.chat_route_retry"), .refresh) { change(action: "resume") }
                .buttonStyle(LimitActionStyle())
                .disabled(busy)
        case .routing:
            Button(L10n.text("common.chat_routing"), .settings) { showingRouting = true }
                .buttonStyle(LimitActionStyle())
        case .cancel:
            Button(L10n.text("common.cancel"), .dismiss) { change(action: "cancel") }
                .buttonStyle(LimitActionStyle())
                .disabled(saving)
        }
    }

    private func title(_ limit: ChatProviderLimit) -> String {
        let name = limit.provider.capitalized
        return limit.kind == "usage" ? L10n.text("common.chat_limit_reached", name)
            : limit.kind == "throttle" ? L10n.text("common.chat_throttled", name)
            : L10n.text("common.chat_route_failure", name)
    }

    private func resetLine(_ limit: ChatProviderLimit) -> String {
        guard let instant = limit.resetsAtMs else { return L10n.text("common.chat_reset_unknown") }
        let date = Date(timeIntervalSince1970: Double(instant) / 1000)
        let relative = RelativeClock.phrase(for: date)
        if date <= Date() {
            return L10n.text("common.chat_reset_elapsed", date.formatted(date: .abbreviated, time: .shortened))
        }
        return L10n.text("common.chat_resets_in", relative,
                         date.formatted(date: .omitted, time: .shortened))
    }

    @ViewBuilder
    private func waitOption(state: ChatRoutingState, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Toggle(L10n.text("common.chat_wait_reset"), isOn: Binding(
                    get: { pendingWait ?? state.policy.waitForReset },
                    set: { value in setWait(value, state: state) }))
                    .toggleStyle(.brandCheckbox)
                    .disabled(!available || saving)
                if saving { ProgressView().controlSize(.small) }
            }
            if !available && !state.needsDeliveryCheck {
                Text(L10n.text("common.chat_wait_reset_unavailable"))
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .contentShape(.rect)
        .onTapGesture {
            guard available, !saving else { return }
            setWait(!(pendingWait ?? state.policy.waitForReset), state: state)
        }
    }

    private func setWait(_ value: Bool, state: ChatRoutingState) {
        guard !saving else { return }
        pendingWait = value
        var policy = state.policy
        policy.waitForReset = value
        change(policy: policy, revert: true)
    }

    private func handOff() {
        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.draft = L10n.text("common.continue")
        }
        model.agentPickerRequest &+= 1
    }

    private func change(policy: ChatRoutingPolicy? = nil, action: String? = nil, revert: Bool = false) {
        guard !saving, let owner = model.currentReference, model.selected?.id == chat.id else {
            if revert { pendingWait = nil }
            return
        }
        failure = nil
        saving = true
        Task {
            defer { saving = false }
            guard model.currentReference == owner, model.selected?.id == chat.id else {
                if revert { pendingWait = nil }
                return
            }
            let saved = await model.routing(policy: policy, action: action)
            guard model.currentReference == owner else { return }
            if !saved {
                if revert { pendingWait = nil }
                failure = model.error ?? L10n.text("common.chat_route_load_failed")
            } else if revert, pendingWait == model.selected?.routing?.policy.waitForReset {
                pendingWait = nil
            }
        }
    }
}
private struct LimitActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    #if os(macOS)
    private let height: CGFloat = 32
    private let fontSize: CGFloat = 13
    #else
    private let height: CGFloat = 44
    private let fontSize: CGFloat = 15
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(Glyph(size: fontSize))
            .font(Theme.font(fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Theme.accent : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : Theme.border, lineWidth: 1)
            )
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.42)
    }

    private struct Glyph: LabelStyle {
        let size: CGFloat
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 7) {
                configuration.icon
                    .font(Theme.font(size, weight: .semibold))
                    .frame(width: size + 3, height: size + 3)
                configuration.title
            }
        }
    }
}
