// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// The two settings that decide how the next session starts: which model it
/// talks to, and whether it asks permission.
///
/// # Why they live in the chrome
///
/// Both used to sit in the middle of the launch surface, which meant they
/// existed only while a workspace had no session at all. Once anything was
/// running there was no way to see what the next launch would do, let alone
/// change it. They belong on the row that is always there, beside the New
/// session menu they modify.
///
/// The stored selection is `provider:model`, per workspace. The provider id
/// never contains a colon and a model id often does (`llama3.2:latest`), so
/// the split is at the first one only.
enum LocalModelSelection {
    /// The key a picker stores for one model.
    static func key(provider: String, model: String) -> String {
        "\(provider):\(model)"
    }

    /// The provider and model a stored key names, or nil when nothing is set.
    static func parse(_ key: String?) -> (provider: String, model: String)? {
        guard let key, let separator = key.firstIndex(of: ":") else { return nil }
        let provider = String(key[key.startIndex ..< separator])
        let model = String(key[key.index(after: separator)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }

    /// The selection stored for a workspace, ready to hand to a spawn.
    @MainActor
    static func stored(for workspaceID: String, in workspaces: WorkspacesModel? = nil) -> (provider: String, model: String)? {
        parse(workspaces?.localModel(for: workspaceID) ?? WorkspacePreference.localModel(for: workspaceID))
    }
}

/// The local model menu, sized for a chrome row.
///
/// Loads its own list. A provider that is not running still appears, disabled
/// and saying so, because "LM Studio: not running" answers the question the
/// user actually has, and an empty menu does not.
struct LocalModelControl: View {
    let folder: WorkspaceFolder
    /// The machine to probe. A remote folder's models come from the machine
    /// that owns it, never from the Mac drawing this row.
    let peer: String?
    @Bindable var workspaces: WorkspacesModel

    @State private var providers: [LocalProvider] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Bumped on every load. A slower answer for a previous folder or peer
    /// must not overwrite the list for the one on screen now.
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

    /// What the button says when nothing is selected, and as the menu's own
    /// first entry.
    private var defaultLabel: String { L10n.text("apple.launchcontrols.each_tool_s_default.03e1b871") }

    private var buttonLabel: String {
        if let match = choices.first(where: { $0.key == selectedKey }) {
            return match.label
        }
        // The list has not loaded yet, but a choice is already stored.
        // Show the model id rather than the default, so a folder-list
        // refresh does not flash "Each tool's default" over a real pick.
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
        .task { await load() }
        .onChange(of: folder.id) { _, _ in
            Task { await load() }
        }
    }

    /// Providers that cannot be picked: not running, empty, or disabled here.
    ///
    /// Listed in the menu so a short picker says why, instead of looking like
    /// nothing is installed.
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
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let loaded = if let peer {
                try await Bridge.localModels(onPeer: peer)
            } else {
                try await Bridge.localModels()
            }
            guard generation == loadGeneration else { return }
            providers = loaded
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            // Kept and shown. Swallowing this is what made a decoding failure
            // read as "no local models discovered" while both servers were up.
            providers = []
            errorMessage = error.localizedDescription
        }
    }
}

/// The bypass switch, as a chrome control with a visible on state.
///
/// An icon rather than a checkbox and two lines of prose: what it turns off is
/// worth a marker that stays on screen for the whole session, and the
/// explanation reads the same in a tooltip.
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
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(
            isOn
                ? L10n.text("apple.launchcontrols.launches_here_skip_permission_prompts_shel.b6b1d520")
                : L10n.text("apple.launchcontrols.launches_here_ask_before_acting_turn_on_to.7f74555d")
        )
    }
}

#endif
