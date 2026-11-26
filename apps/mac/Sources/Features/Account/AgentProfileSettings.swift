// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import SwiftUI

struct AgentProfileSettings: View {
    private struct NameEditor: Identifiable {
        let id = UUID()
        let profile: AgentProfile?
    }

    private struct SignIn: Identifiable {
        let profile: AgentProfile
        let backend: ChatBackend
        var id: String { backend.id }
    }

    @State private var catalog = AgentProfileCatalog.shared
    @State private var backends: [ChatBackend] = []
    @State private var selectedID = AgentProfiles.system
    @State private var editor: NameEditor?
    @State private var name = ""
    @State private var signIn: SignIn?
    @State private var deleting: AgentProfile?
    @State private var statuses: [String: AgentSetupStatus] = [:]
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Card(title: L10n.text("apple.profiles.title"),
             subtitle: L10n.text("apple.profiles.description"), mark: "mark_account") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let error { ErrorBanner(message: error) }
                if let profiles = catalog.value, let profile = profiles.profile(selectedID) {
                    HStack {
                        profilePicker(L10n.text("apple.profiles.profile"), profiles: profiles, selection: $selectedID)
                        Spacer()
                        Button(L10n.text("apple.profiles.add"), .create) { editName(nil) }
                    }
                    if profile.system {
                        Text(L10n.text("apple.profiles.terminal_logins"))
                            .font(Theme.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(backends.filter { $0.installed == true && $0.id != "sh" }) { backend in
                            agentRow(backend, profile: profile, supported: profiles.agents)
                        }
                        HStack {
                            Button(L10n.text("common.rename"), .edit) { editName(profile) }
                            Button(L10n.text("common.delete"), .delete) { deleting = profile }
                        }
                    }
                    if !profiles.named.isEmpty {
                        ThemeRule()
                        profilePicker(L10n.text("apple.profiles.default"), profiles: profiles,
                                      selection: Binding(get: { catalog.value?.default ?? AgentProfiles.system },
                                                         set: { id in change { try await Bridge.setDefaultAgentProfile(id: id) } }))
                    }
                } else if error == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.text("common.refresh"), .refresh) { Task { await load() } }
                }
            }
            .disabled(busy)
        }
        .task { await load() }
        .task(id: catalog.value?.profile(selectedID)) { await checkSelectedLogins() }
        .sheet(item: $editor) { edit in
            ThemedSheet(title: edit.profile == nil ? L10n.text("apple.profiles.add") : L10n.text("apple.profiles.rename"),
                        subtitle: "", onClose: { editor = nil }) {
                TextField(L10n.text("apple.profiles.name"), text: $name)
                    .textFieldStyle(.themed)
            } actions: {
                Button(L10n.text("common.cancel"), .dismiss) { editor = nil }
                Button(L10n.text("common.save"), .done) { saveName(edit.profile) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .modalFrame(width: 420, height: 200)
        }
        .sheet(item: $signIn) { target in
            AgentSignInSheet(backend: target.backend, peer: nil, profileID: target.profile.id,
                             profileTitle: target.profile.title) {
                await check(target.backend, profile: target.profile)?.outcome ?? .unavailable
            }
        }
        .confirmationDialog(L10n.text("apple.profiles.delete", deleting?.title ?? ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { profile in
            Button(L10n.text("common.delete"), role: .destructive) {
                change {
                    let profiles = try await Bridge.deleteAgentProfile(id: profile.id)
                    selectedID = AgentProfiles.system
                    return profiles
                }
            }
        } message: { _ in
            Text(L10n.text("apple.profiles.delete_message"))
        }
    }

    private func profilePicker(_ title: String, profiles: AgentProfiles, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(profiles.profiles) { profile in
                Text(profile.title).tag(profile.id)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func agentRow(_ backend: ChatBackend, profile: AgentProfile, supported: [String]) -> some View {
        let agent = backend.launcherID ?? backend.id
        let own = profile.own.contains(agent)
        let status = statuses[agent]
        return HStack(spacing: Theme.Space.s) {
            HarnessMark(id: backend.id, size: 22).accessibilityHidden(true)
            Text(backend.label)
            Spacer()
            if supported.contains(agent) {
                Picker(backend.label, selection: Binding(get: { own }, set: { next in
                    change { try await Bridge.setAgentProfileLogin(id: profile.id, agent: agent, own: next) }
                })) {
                    Text(L10n.text("apple.profiles.same_mac")).tag(false)
                    Text(L10n.text("apple.profiles.own_login")).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if own {
                    if let email = status?.email, !email.isEmpty {
                        Text(email).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if status?.outcome == .signedIn {
                        Text(L10n.text("apple.profiles.signed_in")).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    if backend.signInFlow?.supported == true {
                        Button(status?.outcome == .signedIn ? L10n.text("apple.profiles.sign_in_again") : L10n.text("common.sign_in"), .signIn) {
                            signIn = SignIn(profile: profile, backend: backend)
                        }
                    }
                }
            } else {
                Text(L10n.text("apple.profiles.same_mac")).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        error = nil
        do {
            async let agents = Bridge.chatBackends()
            try await catalog.refresh()
            backends = try await agents
            await checkSelectedLogins()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func checkSelectedLogins() async {
        statuses = [:]
        guard let profile = catalog.value?.profile(selectedID), !profile.system else { return }
        for backend in backends where profile.own.contains(backend.launcherID ?? backend.id) {
            guard !Task.isCancelled else { return }
            _ = await check(backend, profile: profile)
        }
    }

    private func check(_ backend: ChatBackend, profile: AgentProfile) async -> AgentSetupStatus? {
        guard let id = backend.launcherID else { return nil }
        do {
            let status = try await Bridge.agentSetupCheck(peer: nil, id: id, profile: profile.id)
            guard !Task.isCancelled, selectedID == profile.id,
                  catalog.value?.profile(profile.id)?.own.contains(id) == true else { return nil }
            statuses[id] = status
            return status
        } catch {
            if !Task.isCancelled, selectedID == profile.id { self.error = error.localizedDescription }
            return nil
        }
    }

    private func editName(_ profile: AgentProfile?) {
        name = profile?.name ?? ""
        editor = NameEditor(profile: profile)
    }

    private func saveName(_ profile: AgentProfile?) {
        let name = self.name
        editor = nil
        change {
            if let profile { return try await Bridge.renameAgentProfile(id: profile.id, name: name) }
            let created = try await Bridge.createAgentProfile(name: name)
            selectedID = created.id
            return created.profiles
        }
    }

    private func change(_ action: @escaping () async throws -> AgentProfiles) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { catalog.replace(try await action()) }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
