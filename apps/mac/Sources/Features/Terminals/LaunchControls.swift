// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

enum LocalModelSelection {
    static func key(provider: String, model: String) -> String {
        "\(provider):\(model)"
    }

    static func parse(_ key: String?) -> (provider: String, model: String)? {
        LocalModelLaunch.parse(key)
    }

    @MainActor
    static func stored(for workspaceID: String, in workspaces: WorkspacesModel? = nil) -> (provider: String, model: String)? {
        parse(workspaces?.localModel(for: workspaceID) ?? WorkspacePreference.localModel(for: workspaceID))
    }
}

struct LocalModelControl: View {
    let folder: WorkspaceFolder
    let peer: String?
    @Bindable var workspaces: WorkspacesModel

    @State private var providers: [LocalProvider] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadGeneration = 0

    private var selectedKey: String {
        workspaces.localModel(for: folder.id) ?? ""
    }

    private var choices: [(key: String, label: String)] {
        providers.flatMap { provider -> [(key: String, label: String)] in
            guard provider.available,
                  peer != nil || LocalProviderPreference.isEnabled(provider.id)
            else { return [] }
            return provider.models.map {
                (key: LocalModelSelection.key(provider: provider.id, model: $0.id),
                 label: "\(provider.name): \($0.name)")
            }
        }
    }

    private var defaultLabel: String { L10n.text("apple.launchcontrols.each_tool_s_default.03e1b871") }

    private var buttonLabel: String {
        if let match = choices.first(where: { $0.key == selectedKey }) {
            return match.label
        }
        if let parsed = LocalModelSelection.parse(selectedKey) {
            return parsed.model
        }
        return defaultLabel
    }

    var body: some View {
        Menu {
            Button {
                select("")
            } label: {
                Label(defaultLabel, systemImage: selectedKey.isEmpty ? "checkmark" : "")
            }
            if !choices.isEmpty {
                ThemeRule()
                ForEach(choices, id: \.key) { choice in
                    Button {
                        select(choice.key)
                    } label: {
                        Label(
                            choice.label,
                            systemImage: choice.key == selectedKey ? "checkmark" : ""
                        )
                    }
                }
            }
            if !statusRows.isEmpty {
                ThemeRule()
                ForEach(statusRows, id: \.self) { row in
                    Text(row)
                }
            }
            if let errorMessage {
                ThemeRule()
                Text(L10n.text("apple.launchcontrols.could_not_read_local_models_0.15206f7a", "\(errorMessage)"))
            }
            Button(L10n.text("common.refresh"), .refresh) { Task { await load() } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(Theme.font(11))
                Text(buttonLabel)
                    .font(Theme.font(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(selectedKey.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 64)
        .accessibilityLabel(buttonLabel)
        // Rebuild the menu when the choice changes. macOS caches the label
        // of a `Menu` and otherwise keeps showing "Each tool's default"
        // until the view is torn down (Home and back).
        .id("\(selectedKey)|\(buttonLabel)")
        .help(helpText)
        .task(id: "\(folder.id)|\(peer ?? "local")") { await load() }
    }

    private var statusRows: [String] {
        providers.compactMap { provider in
            if !provider.available {
                return "\(provider.name): \(localProviderStatus(provider))"
            }
            if provider.models.isEmpty {
                return L10n.text("apple.launchcontrols.0_no_models_loaded.cc0537c5", "\(provider.name)")
            }
            if peer == nil && !LocalProviderPreference.isEnabled(provider.id) {
                return L10n.text("apple.launchcontrols.0_turned_off_in_settings.b76e5c4e", "\(provider.name)")
            }
            return nil
        }
    }

    private func localProviderStatus(_ provider: LocalProvider) -> String {
        let raw = provider.error ?? L10n.text("apple.launchcontrols.not_running.415ed734")
        if raw == "not running" || raw.hasPrefix("not running") {
            return provider.id == "lmstudio"
                ? L10n.text("apple.launchcontrols.not_running_start_the_app_local_server_on.0f8fa880")
                : L10n.text("apple.launchcontrols.not_running_start_the_app_port_11434.468ba7b0")
        }
        return raw
    }

    private var helpText: String {
        if let errorMessage {
            return L10n.text("apple.launchcontrols.local_model_servers_could_not_be_read_0.d4ad96a9", "\(errorMessage)")
        }
        if choices.isEmpty {
            return L10n.text("apple.launchcontrols.no_local_model_is_ready_start_lm_studio_po.45c025dd")
        }
        return L10n.text("apple.launchcontrols.which_model_the_next_session_starts_on_cla.07eb2e61")
    }

    private func select(_ key: String) {
        workspaces.setLocalModel(key.isEmpty ? nil : key, for: folder.id)
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        providers = []
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let loaded = if let peer {
                try await Bridge.localModels(onPeer: peer)
            } else {
                try await Bridge.localModels()
            }
            guard !Task.isCancelled, generation == loadGeneration else { return }
            providers = loaded
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            providers = []
            errorMessage = error.localizedDescription
        }
    }
}

struct BypassPermissionsControl: View {
    let folder: WorkspaceFolder
    @Bindable var workspaces: WorkspacesModel

    private var isOn: Bool { workspaces.bypassPermissions(for: folder.id) }

    var body: some View {
        Button {
            workspaces.setBypassPermissions(!isOn, for: folder.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "lock.open.fill" : "lock.fill")
                    .font(Theme.font(11))
                Text(isOn ? L10n.text("apple.launchcontrols.bypass_on.57526f50") : L10n.text("apple.launchcontrols.bypass_off.bd6707b9"))
                    .font(Theme.font(11))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(QuietLinkStyle())
        .fixedSize(horizontal: true, vertical: false)
        .help(
            isOn
                ? L10n.text("apple.launchcontrols.launches_here_skip_permission_prompts_shel.b6b1d520")
                : L10n.text("apple.launchcontrols.launches_here_ask_before_acting_turn_on_to.7f74555d")
        )
    }
}


struct AgentProfileLaunchControl: View {
    let folder: WorkspaceFolder
    let peer: String?

    @State private var profiles: AgentProfiles?
    @State private var chosen: String?
    @State private var loadGeneration = 0

    private var lock: String? {
        profiles?.workspaceLocks?[WorkDestinationResolver.route(folderID: folder.id).workspaceID]
    }

    private var current: String {
        lock ?? chosen ?? profiles?.default ?? AgentProfiles.system
    }

    var body: some View {
        // The load hangs off a view that is always there. Until the list
        // arrives there is nothing else to draw, and SwiftUI never starts a
        // task attached to an empty view.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let profiles, !profiles.named.isEmpty {
                Menu {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            chosen = profile.id
                            LaunchAgentProfile.choose(profile.id, for: folder.id)
                        } label: {
                            Label(profile.title, systemImage: profile.id == current ? "checkmark" : "")
                        }
                        .disabled(lock != nil && lock != profile.id)
                    }
                    if let lock, let title = profiles.profile(lock)?.title {
                        ThemeRule()
                        Text(L10n.text("common.profiles.locked", title))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: lock != nil ? "lock.fill" : "person.crop.circle")
                            .font(Theme.font(11))
                        Text(profiles.profile(current)?.title ?? AgentProfiles.system)
                            .font(Theme.font(11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(current == AgentProfiles.system
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // macOS caches a menu's label. Rebuild it when the choice moves.
                .id("\(current)|\(profiles.profile(current)?.title ?? "")")
                .help(L10n.text("common.profiles.launch_help"))
                .accessibilityLabel(L10n.text("common.profiles.label"))
            }
        }
        .task(id: "\(folder.id)|\(peer ?? "")") { await load() }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        chosen = LaunchAgentProfile.chosen(for: folder.id)
        let loaded: AgentProfiles?
        if let peer {
            guard await RemoteHostFeature.agentProfiles.isSupported(peer: peer) else {
                profiles = nil; LaunchAgentProfile.forget(folderID: folder.id); return
            }
            loaded = try? await Bridge.agentProfiles(peer: peer)
        } else {
            try? await AgentProfileCatalog.shared.refresh()
            loaded = AgentProfileCatalog.shared.value
        }
        guard !Task.isCancelled, generation == loadGeneration else { return }
        profiles = loaded
        LaunchAgentProfile.remember(loaded, folderID: folder.id,
                                    workspaceID: WorkDestinationResolver.route(folderID: folder.id).workspaceID)
    }
}

#endif
