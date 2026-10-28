// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Whether teammates' Asks may start an agent on this computer, for one
/// shared project. A run uses this computer's agent login and works in this
/// folder, so it is the sharer's choice, and a new share starts with it off.
enum TeamAgentAccess: String, Codable, CaseIterable, Sendable {
    case off, ask, on
    var label: String {
        switch self {
        case .off: L10n.text("common.teams.agent_access_off")
        case .ask: L10n.text("common.teams.agent_access_ask")
        case .on: L10n.text("common.teams.agent_access_on")
        }
    }
    var detail: String {
        switch self {
        case .off: L10n.text("common.teams.agent_access_off_detail")
        case .ask: L10n.text("common.teams.agent_access_ask_detail")
        case .on: L10n.text("common.teams.agent_access_on_detail")
        }
    }
}
struct TeamAgentAccessState: Decodable, Sendable { let access: TeamAgentAccess; let allowedPeople: Int }
struct TeamAgentRequest: Decodable, Identifiable, Equatable, Sendable {
    let id: String; let checkoutId: String; let organizationId: String; let repositoryId: String
    let personId: String; let personName: String; let text: String; let createdAtMs: Int64
}
struct TeamAgentRequests: Decodable, Sendable { let requests: [TeamAgentRequest] }

/// The setting itself, in a shared project's settings on the computer that
/// shares it. Who is eligible stays with the team's agent access controls.
struct TeamAgentAccessSettings: View {
    @Bindable var store: TeamStore
    let context: TeamMutationContext
    let checkoutId: String
    @State private var access: TeamAgentAccess = .off
    @State private var allowedPeople = 0
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.teams.agent_access")).font(Theme.headline)
            if let error { TeamNotice(message: error, warning: true) }
            accessPicker
                .labelsHidden()
                .accessibilityIdentifier("team.agent.access")
                .disabled(!loaded || saving)
            Text(access.detail).font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if access == .ask && allowedPeople > 0 {
                Text(L10n.text("common.teams.agent_access_always_count", "\(allowedPeople)"))
                    .font(Theme.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: checkoutId) { await load() }
    }

    @ViewBuilder private var accessPicker: some View {
        let picker = Picker(L10n.text("common.teams.agent_access"), selection: Binding(get: { access }, set: { value in
            Task { await save(value) }
        })) {
            ForEach(TeamAgentAccess.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        #if os(macOS)
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
            picker.pickerStyle(.menu)
        }
        #else
        picker.pickerStyle(.menu)
        #endif
    }

    private func load() async {
        error = nil
        do {
            let state: TeamAgentAccessState = try await store.read(.agentAccessGet, fields: ["checkout": .string(checkoutId)], context: context)
            access = state.access; allowedPeople = state.allowedPeople; loaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func save(_ value: TeamAgentAccess) async {
        guard value != access, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            let state: TeamAgentAccessState = try await store.perform(.agentAccessSet,
                fields: ["checkout": .string(checkoutId), "access": .string(value.rawValue)], context: context)
            access = state.access; allowedPeople = state.allowedPeople
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

/// Asks the sharer, wherever they are in the app, when a teammate's Ask is
/// waiting for them. The teammate's app keeps sending the same request, so
/// an answer here lets it start within a few seconds.
struct TeamAgentApprovalPrompt: ViewModifier {
    let store: TeamStore
    /// The local folder name for a shared checkout, for the prompt's wording.
    let projectName: (TeamLocalPublication) -> String?
    @State private var waiting: [TeamAgentRequest] = []
    @State private var answered: Set<String> = []
    @State private var failure: String?
    @Environment(\.scenePhase) private var scenePhase

    private var shown: TeamAgentRequest? { waiting.first { !answered.contains($0.id) } }
    private var sharing: Bool { store.phase == .ready && store.localProjects.contains { $0.phase == "active" } }

    func body(content: Content) -> some View {
        content
            .task(id: sharing) {
                guard sharing else { waiting = []; return }
                while !Task.isCancelled {
                    await poll()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            // A sheet rather than an alert: an alert makes its first button
            // the Return key's, and approving a run must take a deliberate
            // click. Escape and closing the sheet both deny.
            .sheet(item: Binding(get: { shown }, set: { _ in })) { request in
                ThemedSheet(title: title(request), subtitle: L10n.text("common.teams.agent_access"), icon: .run, scrolls: true,
                            onClose: { Task { await decide(request, "deny") } }) {
                    Text(message(request)).font(Theme.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } actions: {
                    Button(L10n.text("common.teams.agent_request_deny"), .deny, role: .destructive) { Task { await decide(request, "deny") } }
                        .buttonStyle(TeamButtonStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L10n.text("common.teams.agent_request_allow_always", request.personName), .allow) { Task { await decide(request, "always") } }
                        .buttonStyle(TeamButtonStyle())
                    Button(L10n.text("common.teams.agent_request_allow_once"), .allow) { Task { await decide(request, "once") } }
                        .buttonStyle(TeamButtonStyle())
                }
                #if os(macOS)
                .frame(width: 480)
                #endif
                .interactiveDismissDisabled()
            }
            .alert(L10n.text("common.teams.agent_request_failed"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("common.done"), role: .cancel) {}
            } message: { Text(failure ?? "") }
    }

    private func title(_ request: TeamAgentRequest) -> String {
        let organization = store.organizations.first { $0.id == request.organizationId }?.name
        return organization.map { L10n.text("common.teams.agent_request_title_from", request.personName, $0) }
            ?? L10n.text("common.teams.agent_request_title", request.personName)
    }

    private func message(_ request: TeamAgentRequest) -> String {
        let project = store.localProjects.first { $0.id == request.checkoutId }.flatMap(projectName)
            ?? L10n.text("common.teams.this_project")
        return L10n.text("common.teams.agent_request_message", project, request.text)
    }

    private func poll() async {
        guard let context = store.mutationContext else { return }
        guard let result: TeamAgentRequests = try? await store.read(.agentAccessRequests, fields: [:], context: context) else { return }
        let fresh = result.requests.contains { request in !waiting.contains { $0.id == request.id } }
        waiting = result.requests
        answered = answered.filter { id in result.requests.contains { $0.id == id } }
        #if os(macOS)
        if fresh, shown != nil, scenePhase != .active || !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        #endif
    }

    private func decide(_ request: TeamAgentRequest, _ decision: String) async {
        answered.insert(request.id)
        guard let context = store.mutationContext else { return }
        do {
            let _: JSONValue = try await store.perform(.agentAccessDecide,
                fields: ["request": .string(request.id), "decision": .string(decision)], context: context)
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
}
