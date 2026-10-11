// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct ChatRoutingControls: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @State private var showing = false
    var body: some View {
        Button(L10n.text("common.chat_routing"), .settings) { showing = true }
            .buttonStyle(SecondaryButtonStyle(small: true))
            .disabled(model.savedCopy != nil)
            .sheet(isPresented: $showing) { ChatRoutingSheet(model: model, chat: chat) }
    }
}
struct ChatRoutingNotice: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var body: some View {
        if let state = chat.routing, let limit = state.limit {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(limit.kind == "usage" ? L10n.text("common.chat_limit_reached", limit.provider.capitalized) : L10n.text("common.chat_throttled", limit.provider.capitalized))
                    .font(Theme.callout.weight(.semibold))
                if let instant = limit.resetsAtMs {
                    Text(L10n.text("common.chat_resets_at", Date(timeIntervalSince1970: Double(instant) / 1000).formatted(date: .abbreviated, time: .shortened)))
                } else { Text(L10n.text("common.chat_reset_unknown")) }
                if state.needsDeliveryCheck { Text(L10n.text("common.chat_route_delivery")) }
                if let note = state.note { Text(note).font(Theme.caption) }
                Toggle(L10n.text("common.chat_wait_reset"), isOn: Binding(
                    get: { state.policy.waitForReset }, set: { value in
                        var policy = state.policy; policy.waitForReset = value
                        Task { _ = await model.routing(policy: policy) }
                    }))
                    .toggleStyle(.brandCheckbox)
                    .disabled(limit.resetsAtMs == nil || state.needsDeliveryCheck)
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.text("common.chat_route_retry"), .refresh) { Task { _ = await model.routing(action: "resume") } }
                        .disabled(chat.running || state.needsDeliveryCheck)
                    ChatRoutingControls(model: model, chat: chat)
                    if state.waiting {
                        Button(L10n.text("common.cancel"), .stop) { Task { _ = await model.routing(action: "cancel") } }
                    }
                }.buttonStyle(SecondaryButtonStyle(small: true))
            }
            .font(Theme.caption).padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
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
    var body: some View {
        ThemedSheet(title: L10n.text("common.chat_routing"), subtitle: L10n.text("common.chat_route_explanation"), icon: .settings,
                    scrolls: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
            Toggle(L10n.text("common.chat_routing_enabled"), isOn: $policy.enabled)
            Toggle(L10n.text("common.chat_wait_reset"), isOn: $policy.waitForReset)
            Toggle(L10n.text("common.chat_return_preferred"), isOn: $policy.returnPreferred)
            Toggle(L10n.text("common.chat_route_default"), isOn: $policy.useAsDefault)
            Text(L10n.text("common.chat_route_order")).font(Theme.callout.weight(.semibold))
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(policy.routes.indices, id: \.self) { index in
                        HStack(spacing: Theme.Space.s) {
                            Text("\(index + 1). \(model.backend(for: policy.routes[index].backend)?.label ?? policy.routes[index].backend)")
                            if let backend = model.backend(for: policy.routes[index].backend) {
                                AppMenuPicker(title: L10n.text("apple.chatsetupheader.default.21b111cb"),
                                    options: [(value: "", label: L10n.text("apple.chatsetupheader.default.21b111cb"))] + backend.models.map { (value:$0,label:$0) },
                                    selection: Binding(get:{policy.routes.indices.contains(index) ? policy.routes[index].model ?? "" : ""},set:{ if policy.routes.indices.contains(index) { policy.routes[index].model = $0.isEmpty ? nil : $0 } }))
                            }
                            Button(L10n.text("common.move_up"), .move) { policy.routes.swapAt(index, index - 1) }.disabled(index == 0)
                            Button(L10n.text("common.remove"), .delete) { policy.routes.remove(at: index) }
                        }
                    }
                }
            }.frame(maxHeight: policy.routes.isEmpty ? 0 : 240)
            HStack {
                AppMenuPicker(title: L10n.text("apple.chatsetupheader.agent.11b39c93"), options: [(value:"",label:L10n.text("common.add"))] + model.backends.filter{$0.id != "sh" && $0.installed != false}.map{(value:$0.id,label:$0.label)}, selection:$adding)
                Button(L10n.text("common.add"), .create) { policy.routes.append(ChatRouteDestination(backend:adding)); adding = "" }.disabled(adding.isEmpty || policy.routes.count >= 8 || policy.routes.contains{$0.backend == adding && $0.model == nil})
            }
            HStack {
                Spacer()
                Button(L10n.text("common.cancel"), .stop) { dismiss() }
                Button(L10n.text("common.save"), .save) { saving = true; Task { if await model.routing(policy:policy) { dismiss() }; saving = false } }
                    .disabled(!loaded || saving)
            }
        }
        }
        .toggleStyle(.brandCheckbox)
        .modalFrame(width: 560, height: 680)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .task { if await model.routing() { policy = model.selected?.routing?.policy ?? ChatRoutingPolicy(); loaded = true } }
    }
}
