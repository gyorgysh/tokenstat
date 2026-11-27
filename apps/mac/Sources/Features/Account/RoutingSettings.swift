// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

struct RoutingSettings: View {
    @State private var policy: ChatRoutingPolicy?
    @State private var backends: [ChatBackend] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var editing = false

    private var behavior: RoutingBehavior { RoutingBehavior(policy ?? ChatRoutingPolicy()) }

    var body: some View {
        Card(title: L10n.text("common.chat_routing"), subtitle: L10n.text("common.chat_route_settings_intro")) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RoutingIllustration(behavior: behavior, height: 140)
                if let failure {
                    ErrorBanner(message: failure)
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Image(systemName: behavior.symbol).foregroundStyle(Theme.accent)
                        Text(policy == nil ? L10n.text("common.chat_route_settings_none") : behavior.summary(agents: agents))
                            .font(Theme.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Label(L10n.text("common.chat_route_settings_scope"), systemImage: "info.circle")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(policy == nil ? L10n.text("common.chat_route_settings_setup") : L10n.text("common.edit"),
                           policy == nil ? .routing : .edit) { editing = true }
                        .buttonStyle(AccentButtonStyle())
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $editing) {
            RoutingSetup(context: .defaults(peer: nil)) { saved in policy = saved }
        }
    }

    private var agents: [String] {
        (policy?.routes ?? []).map { route in backends.first { $0.id == route.backend }?.label ?? route.backend }
    }

    private func load() async {
        do {
            async let agents = Bridge.chatBackends()
            policy = try await Bridge.routingDefaults()
            backends = try await agents
            loaded = true
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
#endif
