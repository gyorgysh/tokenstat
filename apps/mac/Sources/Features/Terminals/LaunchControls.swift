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
    private var defaultLabel: String { "Each tool's default" }

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
                Divider()
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
                Divider()
                ForEach(statusRows, id: \.self) { row in
                    Text(row)
                }
            }
            if let errorMessage {
                Divider()
                Text("Could not read local models: \(errorMessage)")
            }
            Button("Refresh", .refresh) { Task { await load() } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(Theme.font(11))
                Text(buttonLabel)
                    .font(Theme.font(11))
                    .lineLimit(1)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(selectedKey.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                return "\(provider.name): no models loaded"
            }
            if peer == nil && !LocalProviderPreference.isEnabled(provider.id) {
                return "\(provider.name): turned off in Settings"
            }
            return nil
        }
    }

    private func localProviderStatus(_ provider: LocalProvider) -> String {
        let raw = provider.error ?? "not running"
        if raw == "not running" || raw.hasPrefix("not running") {
            return provider.id == "lmstudio"
                ? "not running (start the app, local server on port 1234)"
                : "not running (start the app, port 11434)"
        }
        return raw
    }

    private var helpText: String {
        if let errorMessage {
            return "Local model servers could not be read: \(errorMessage)"
        }
        if choices.isEmpty {
            return """
            No local model is ready. Start LM Studio (port 1234) or Ollama \
            (port 11434), load a model, and refresh. Claude uses LM Studio's \
            Anthropic-compatible endpoint. Codex and OpenCode receive an \
            explicit local provider and model.
            """
        }
        return """
        Which model the next session starts on. Claude uses LM Studio's \
        Anthropic-compatible endpoint. Codex and OpenCode receive an explicit \
        local provider and model.
        """
    }

    private func select(_ key: String) {
        workspaces.setLocalModel(key.isEmpty ? nil : key, for: folder.id)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            providers = if let peer {
                try await Bridge.localModels(onPeer: peer)
            } else {
                try await Bridge.localModels()
            }
            errorMessage = nil
        } catch {
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
                Text(isOn ? "Bypass on" : "Bypass off")
                    .font(Theme.font(11))
            }
            .foregroundStyle(isOn ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(
            isOn
                ? "Agents launched here run without asking for permission. Remembered for this workspace. Only agents with a bypass flag are affected."
                : "Agents launched here ask before acting. Turn on to run them without permission prompts."
        )
    }
}

#endif
