// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// The same setup sections serve the compact composer and full conversation sheet.
struct ChatSetupForm: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool
    var onPickAgent: (() -> Void)? = nil
    @State private var pickingAgent = false

    private var readOnly: Bool { model.savedCopy != nil || model.isSharedSource }
    private var canEdit: Bool { !locked && !readOnly }
    private var bypassOnly: Bool { model.backend(for: chat.backend)?.gateTier == "bypassOnly" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("common.chat.setup.intro"))
                .font(Theme.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if readOnly {
                Text(L10n.text("common.chat.setup.read_only")).font(Theme.caption).foregroundStyle(.secondary)
            } else if locked && chat.running {
                Text(L10n.text("common.chat.setup.busy")).font(Theme.caption).foregroundStyle(Theme.warning)
            } else if locked, let reason = model.landingBlockReason {
                Text(reason).font(Theme.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card(title: L10n.text("common.chat.setup.agent"), subtitle: L10n.text("common.chat.setup.agent_help")) {
                ChatAgentField(model: model, chat: chat, locked: !canEdit) {
                    if let onPickAgent { onPickAgent() } else { pickingAgent = true }
                }
            }
            Card(title: L10n.text("common.chat_working_style"),
                 subtitle: (chat.mode == "plan" ? L10n.text("common.chat.setup.plan_help") : L10n.text("common.chat.setup.execute_help"))) {
                SegmentedCapsulePicker(options: [
                    (value: "plan", label: L10n.text("apple.chatsetupheader.plan.fa8ed0bd"), symbol: ActionIcon.plan.symbol),
                    (value: "execute", label: L10n.text("apple.chatsetupheader.execute.e3a67d95"), symbol: "hammer")
                ], selection: modeBinding).disabled(!canEdit)
            }
            Card(title: L10n.text("common.chat.setup.permissions"), subtitle: permissionHelp) {
                SegmentedCapsulePicker(options: permissionOptions, selection: autonomyBinding)
                    .disabled(!canEdit || bypassOnly)
            }
            if model.landingDraft == nil {
                ChatRoutingSection(model: model, chat: chat).disabled(readOnly)
                ChatInstructionsCard(model: model, chat: chat)
            }
        }
        .pickerPanelSurface(title: L10n.text("apple.chatsetupheader.agent_model_and_effort.217ff8ae"),
                            isPresented: $pickingAgent, anchorsToLeadingEdge: true) {
            ChatAgentPanel(model: model, chat: chat, locked: !canEdit) { pickingAgent = false }
        }
    }

    private var permissionOptions: [(value: String, label: String, symbol: String)] {
        if bypassOnly {
            return [(value: "bypass", label: L10n.text("apple.chatsetupheader.don_t_ask.15dae980"), symbol: ActionIcon.run.symbol)]
        }
        return [
            (value: "standard", label: L10n.text("apple.chatsetupheader.ask_first.4a9e8cf3"), symbol: ActionIcon.permissions.symbol),
            (value: "bypass", label: L10n.text("apple.chatsetupheader.don_t_ask.15dae980"), symbol: ActionIcon.run.symbol)
        ]
    }

    private var permissionHelp: String {
        if bypassOnly { return L10n.text("common.chat.setup.bypass_only_help") }
        return ChatGateCopy.explanation(model.backend(for: chat.backend)?.gateTier, bypass: chat.autonomy == "bypass")
    }
    private var modeBinding: Binding<String> {
        Binding(get: { chat.mode }, set: { next in
            guard canEdit else { return }
            performSetupChange(model: model, chat: chat) { await model.update(mode: next) }
        })
    }
    private var autonomyBinding: Binding<String> {
        Binding(get: { chat.autonomy }, set: { next in
            guard canEdit, !bypassOnly else { return }
            performSetupChange(model: model, chat: chat) { await model.update(autonomy: next) }
        })
    }
}
