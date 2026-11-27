// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

struct AgentUpdatePrompt: Identifiable {
    let id = UUID()
    let backend: ChatBackend
    let send: @MainActor () -> Void

    static func isDue(_ backend: ChatBackend?, peer: String?) -> Bool {
        guard let backend, backend.updateAvailable, backend.installed != false,
              backend.launcherID != nil, let latest = backend.latestVersion else { return false }
        return UserDefaults.standard.string(forKey: skipKey(backend, peer: peer)) != latest
    }

    static func skip(_ backend: ChatBackend, peer: String?) {
        guard let latest = backend.latestVersion else { return }
        UserDefaults.standard.set(latest, forKey: skipKey(backend, peer: peer))
    }

    private static func skipKey(_ backend: ChatBackend, peer: String?) -> String {
        "agentUpdate.skipped.v1.\(peer ?? "local").\(backend.launcherID ?? backend.id)"
    }
}

struct AgentUpdatePromptSheet: ViewModifier {
    @Bindable var model: ChatModel
    var isActive = true

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { isActive ? model.agentUpdatePrompt : nil },
            set: { if $0 == nil { model.agentUpdatePrompt = nil } }
        )) { prompt in
            AgentUpdatePromptView(model: model, prompt: prompt)
        }
    }
}

private struct AgentUpdatePromptView: View {
    let model: ChatModel
    let prompt: AgentUpdatePrompt

    @State private var updating = false
    @State private var failed = false

    private var backend: ChatBackend { prompt.backend }

    var body: some View {
        ThemedSheet(
            title: L10n.text("common.agent_updates.prompt_title", backend.label),
            subtitle: L10n.text("common.agent_updates.prompt_subtitle"),
            icon: .download,
            onClose: { if !updating { model.agentUpdatePrompt = nil } }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    HarnessMark(id: backend.id, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        versionRow(L10n.text("common.agent_updates.installed"), backend.installedVersion, current: false)
                        versionRow(L10n.text("common.agent_updates.latest"), backend.latestVersion, current: true)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                Text(failed ? L10n.text("common.agent_updates.prompt_failed", backend.label)
                     : updating ? L10n.text("common.agent_updates.prompt_updating")
                     : L10n.text("common.agent_updates.prompt_detail"))
                    .font(Theme.callout)
                    .foregroundStyle(failed ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { model.agentUpdatePrompt = nil }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(updating)
            Spacer()
            Button(skipTitle, .send, action: skip)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(updating)
            Button(updateTitle, .download, action: update)
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(updating || failed)
        }
        .modalFrame(width: 500, height: 330)
        .interactiveDismissDisabled(updating)
    }

    private var skipTitle: String {
        failed ? L10n.text("common.agent_updates.send_anyway") : L10n.text("common.agent_updates.skip_version")
    }

    private var updateTitle: String {
        updating ? L10n.text("common.agent_updates.updating") : L10n.text("common.agent_updates.update_and_send")
    }

    private func versionRow(_ label: String, _ version: String?, current: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(version ?? L10n.text("common.agent_updates.unknown_version"))
                .font(Theme.monoText(13, relativeTo: .callout).weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Theme.accent : .primary)
        }
    }

    private func skip() {
        if !failed { AgentUpdatePrompt.skip(backend, peer: model.peer) }
        model.agentUpdatePrompt = nil
        prompt.send()
    }

    private func update() {
        guard !updating, let id = backend.launcherID else { return }
        updating = true
        Task {
            let result = await model.updateAgent(id: id, label: backend.label)
            updating = false
            guard result?.ok == true else { failed = true; return }
            model.agentUpdatePrompt = nil
            prompt.send()
        }
    }
}
