// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct ChatSetupHeader: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var collapsed: Bool
    var showsIntro: Bool = true
    var organized: Bool = false
    var onOpenInspector: (() -> Void)? = nil

    var body: some View {
        Group {
            if collapsed {
                chips
            } else if organized {
                ChatSetupForm(model: model, chat: chat, locked: chat.running)
            } else {
                form
            }
        }
        .onAppear { enforceBypassOnly() }
        .onChange(of: chat.backend) { _, _ in enforceBypassOnly() }
    }

    private var personaRow: some View {
        HStack(spacing: Theme.Space.s) {
            PersonaMark(seed: model.faceSeed, size: 30)
                .environment(\.personaMotionAllowed, false)
            AppMenuPicker(
                title: L10n.text("apple.chatsetupheader.persona.31bdeef9"),
                options: personaOptions,
                selection: personaBinding
            )
            .disabled(chat.running)
        }
    }

    private var personaOptions: [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [(value: "", label: L10n.text("apple.chatsetupheader.no_persona.cce53fca"))]
        for persona in model.personas {
            options.append((value: persona.id, label: persona.name))
        }
        return options
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ChatRoutingSection(model: model, chat: chat)
            agentForm
        }
    }

    private var agentForm: some View {
        ChatSetupSection(title: L10n.text("common.chat_agent_behavior"), icon: .run,
                         initiallyExpanded: showsIntro,
                         primary: agentRow.disabled(model.savedCopy != nil)) {
            Group {
                if showsIntro {
                    Text(L10n.text("apple.chatsetupheader.how_this_chat_should_work.b5eec3c8"))
                        .font(Theme.callout.weight(.semibold))
                    Text(L10n.text("apple.chatsetupheader.these_stay_here_until_the_first_message_af.61e86a8e"))
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.personas.isEmpty {
                    personaRow
                }
                ThemeRule()
                Text(L10n.text("common.chat_working_style"))
                    .font(Theme.callout.weight(.semibold))
                SegmentedCapsulePicker(
                    options: [
                        (value: "plan", label: L10n.text("apple.chatsetupheader.plan.fa8ed0bd"), symbol: ActionIcon.plan.symbol),
                        (value: "execute", label: L10n.text("apple.chatsetupheader.execute.e3a67d95"), symbol: "hammer"),
                    ],
                    selection: modeBinding
                )
                .disabled(chat.running)
                Toggle(L10n.text("apple.chatsetupheader.work_without_asking.dde89661"), isOn: bypassBinding)
                    .toggleStyle(.brandCheckbox)
                    .disabled(chat.running || isBypassOnly)
                Text(ChatGateCopy.explanation(backend?.gateTier, bypass: chat.autonomy == "bypass"))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.disabled(model.savedCopy != nil)
        }
    }

    private var chips: some View {
        HStack(spacing: Theme.Space.s) {
            chip(L10n.text("apple.chatsetupheader.next_response_0.b4c572aa", "\(backend?.label ?? chat.backend)"))
            chip(chat.mode == "plan" ? L10n.text("apple.chatsetupheader.plan.fa8ed0bd") : L10n.text("apple.chatsetupheader.execute.e3a67d95"))
            if let modelName = chat.model, !modelName.isEmpty {
                chip(modelName)
            }
            chip(chat.autonomy == "bypass"
                ? L10n.text("apple.chatsetupheader.don_t_ask.15dae980")
                : ChatGateCopy.chip(backend?.gateTier))
            Spacer(minLength: 0)
            if let onOpenInspector {
                Button(L10n.text("apple.chatsetupheader.edit_setup.5311c363"), .settings) { onOpenInspector() }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .environment(\.compactActions, true)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
    }

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                AppMenuPicker(
                    title: L10n.text("apple.chatsetupheader.agent.11b39c93"),
                    options: agentOptions,
                    selection: backendBinding
                )
                .disabled(chat.running)
            }
            if let backend, backend.installed != false, !backend.models.isEmpty || !backend.efforts.isEmpty {
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    if !backend.models.isEmpty {
                        FavoriteModelPicker(
                            backendID: backend.id,
                            models: backend.models,
                            extra: chat.model ?? "",
                            selection: modelBinding
                        )
                        .disabled(chat.running)
                    }
                    if !backend.efforts.isEmpty {
                        AppMenuPicker(
                            title: L10n.text("apple.chatsetupheader.effort.4387e5d3"),
                            options: [(value: "", label: L10n.text("apple.chatsetupheader.default.21b111cb"))]
                                + backend.efforts.map { (value: $0, label: $0) },
                            selection: effortBinding
                        )
                        .disabled(chat.running)
                    }
                }
            }
        }
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var isBypassOnly: Bool { backend?.gateTier == "bypassOnly" }

    private var agentOptions: [(value: String, label: String)] {
        model.backends
            .filter { ($0.id != "sh" || $0.id == chat.backend) && $0.installed != false }
            .map { (value: $0.id, label: $0.label) }
    }

    private var backendBinding: Binding<String> {
        Binding(
            get: { chat.backend },
            set: { next in
                performSetupChange(model: model, chat: chat) {
                    if model.backend(for: next)?.gateTier == "bypassOnly" {
                        await model.update(backend: next, autonomy: "bypass")
                    } else {
                        await model.update(backend: next)
                    }
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { chat.model ?? "" },
            set: { next in performSetupChange(model: model, chat: chat) { await model.requestModelChange(next) } }
        )
    }

    private var effortBinding: Binding<String> {
        Binding(
            get: { chat.effort ?? "" },
            set: { next in performSetupChange(model: model, chat: chat) { await model.update(effort: next) } }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { chat.mode },
            set: { next in performSetupChange(model: model, chat: chat) { await model.update(mode: next) } }
        )
    }

    private var bypassBinding: Binding<Bool> {
        Binding(
            get: { chat.autonomy == "bypass" },
            set: { next in performSetupChange(model: model, chat: chat) { await model.update(autonomy: next ? "bypass" : "standard") } }
        )
    }

    private var personaBinding: Binding<String> {
        Binding(
            get: { chat.personaID ?? "" },
            set: { id in
                performSetupChange(model: model, chat: chat) { await model.applyPersona(model.personas.first { $0.id == id }) }
            }
        )
    }

    private func enforceBypassOnly() {
        guard isBypassOnly, chat.autonomy != "bypass", !chat.running else { return }
        performSetupChange(model: model, chat: chat) { await model.update(autonomy: "bypass") }
    }
}

struct ChatFastModeButton: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool
    @State private var saving = false
    #if os(iOS)
    @State private var showingOptions = false
    #endif

    private var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var available: Bool { ChatFastMode.available(model: chat.model, models: backend?.fastModeModels, backend: chat.backend) }
    private var speedLocked: Bool { locked && !(chat.running && backend?.fastModeLive == true) }
    private var title: String { chat.fastMode ? (chat.backend == "grok" ? L10n.text("common.chat.fast_mode_fast") : L10n.text("common.chat.fast_mode_priority")) : L10n.text("common.chat.fast_mode_default") }
    private var help: String {
        if !available { return chat.backend == "grok" ? L10n.text("common.chat.fast_mode_select_grok") : L10n.text("common.chat.fast_mode_select_opus") }
        let tradeoff = chat.backend == "claude" ? L10n.text("common.chat.fast_mode_claude_help") : (chat.backend == "grok" ? L10n.text("common.chat.fast_mode_grok_help") : L10n.text("common.chat.fast_mode_codex_help"))
        return title + ". " + tradeoff + " " + (backend?.fastModeLive == true
            ? L10n.text("common.chat.fast_mode_live_help") : (chat.backend == "grok" ? L10n.text("common.chat.fast_mode_grok_next_turn_help") : L10n.text("common.chat.fast_mode_next_turn_help")))
    }

    var body: some View {
        if backend?.fastModeModels != nil, backend?.installed != false, model.savedCopy == nil,
           LocalChatModel.parse(chat.model) == nil {
            Button(title, .fastMode) {
                #if os(macOS)
                save(!chat.fastMode)
                #else
                showingOptions = true
                #endif
            }
            .labelStyle(.iconOnly)
            #if os(macOS)
            .buttonStyle(ControlFeedbackStyle(diameter: 28))
            #else
            .buttonStyle(ControlFeedbackStyle(diameter: 44))
            #endif
            .font(Theme.callout)
            .foregroundStyle(chat.fastMode ? Theme.accent : .secondary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accentSoft)
                    .opacity(chat.fastMode ? 1 : 0)
                    .scaleEffect(chat.fastMode ? 1 : 0.6)
            }
            .symbolEffect(.bounce, value: chat.fastMode)
            .animation(Motion.morph, value: chat.fastMode)
            .contentShape(.rect)
            #if os(macOS)
            .disabled(speedLocked || saving || !available)
            #else
            .popover(isPresented: $showingOptions) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text(help)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ChoiceChip(title: L10n.text("common.chat.fast_mode_default"), isSelected: !chat.fastMode) {
                        save(false)
                        showingOptions = false
                    }
                    .disabled(speedLocked || saving)
                    ChoiceChip(title: chat.backend == "grok" ? L10n.text("common.chat.fast_mode_fast") : L10n.text("common.chat.fast_mode_priority"), isSelected: chat.fastMode) {
                        save(true)
                        showingOptions = false
                    }
                    .disabled(speedLocked || saving || !available)
                }
                .padding(Theme.Space.m)
                .frame(width: 300, alignment: .leading)
                .presentationCompactAdaptation(.popover)
            }
            .onChange(of: model.currentReference) { _, _ in showingOptions = false }
            #endif
            .help(help)
            .accessibilityLabel(title)
            .accessibilityHint(help)
            .accessibilityValue(chat.fastMode ? L10n.text("common.chat.fast_mode_on") : L10n.text("common.chat.fast_mode_off"))
            .accessibilityIdentifier("chat.fastMode")
        }
    }

    private func save(_ fast: Bool) {
        guard !speedLocked, !saving, fast != chat.fastMode, !fast || available else { return }
        let owner = model.currentReference
        saving = true
        Task {
            defer { saving = false }
            guard model.currentReference == owner, model.selected?.id == chat.id,
                  model.selected?.sendRevision == chat.sendRevision,
                  model.savedCopy == nil, !speedLocked else { return }
            await model.update(fastMode: fast)
        }
    }
}

struct ChatComposerControls<Chrome: View>: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool
    var compact = false
    var condensed = false
    var showCompactAgent = true
    let chrome: Chrome

    @State private var pickingAgent = false
    @State private var showingAccessibleSetup = false
    @Environment(\.chatAgentPickerFocus) private var agentPickerFocus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: ChatModel, chat: ChatConversation, locked: Bool, compact: Bool = false,
         condensed: Bool = false, showCompactAgent: Bool = true,
         @ViewBuilder chrome: () -> Chrome) {
        self.model = model
        self.chat = chat
        self.locked = locked || (model.landingDraft != nil && !model.landingCanSubmit)
        self.compact = compact
        self.condensed = condensed
        self.showCompactAgent = showCompactAgent
        self.chrome = chrome()
    }

    var body: some View {
        #if DEBUG && os(macOS)
        let _ = DebugUIHooks.printsChanges ? Self._printChanges() : ()
        #endif
        layout
            .sheet(isPresented: $showingAccessibleSetup, onDismiss: { pickingAgent = false }) {
                ThemedSheet(
                    title: L10n.text("apple.clientchatview.chat_setup.9fa79d00"),
                    subtitle: "",
                    scrolls: true,
                    onClose: { showingAccessibleSetup = false }
                ) {
                    ChatSetupForm(model: model, chat: chat, locked: locked) { pickingAgent = true }
                }
                .pickerPanelSurface(
                    title: L10n.text("apple.chatsetupheader.agent_model_and_effort.217ff8ae"),
                    isPresented: $pickingAgent,
                    anchorsToLeadingEdge: true
                ) { agentPanel }
                .modalFrame(width: 600, height: 640)
            }
            .pickerPanelSurface(
                title: L10n.text("apple.chatsetupheader.agent_model_and_effort.217ff8ae"),
                isPresented: Binding(get: { pickingAgent && !showingAccessibleSetup }, set: { pickingAgent = $0 }),
                anchorsToLeadingEdge: true
            ) { agentPanel }
            .onAppear { enforceBypassOnly() }
            .onChange(of: model.agentPickerRequest) { _, _ in if !locked { pickingAgent = true } }
            .onChange(of: pickingAgent) { _, presented in agentPickerFocus(presented) }
            .onDisappear { if pickingAgent { agentPickerFocus(false) } }
            .onChange(of: chat.backend) { _, _ in enforceBypassOnly() }
            .onChange(of: model.currentReference) { _, _ in
                pickingAgent = false
                showingAccessibleSetup = false
            }
            .onChange(of: model.savedCopy != nil) { _, saved in
                if saved { pickingAgent = false; showingAccessibleSetup = false }
            }
    }

    private var agentPanel: some View {
        ChatAgentPanel(model: model, chat: chat, locked: locked) { pickingAgent = false }
    }

    @ViewBuilder
    private var layout: some View {
        if model.savedCopy != nil || model.isSharedSource {
            if compact {
                HStack(spacing: Theme.Space.s) {
                    savedCopyLabel
                    Spacer(minLength: 0)
                    chrome
                }
            } else {
                savedCopyLabel
            }
        } else if compact && dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: Theme.Space.s) {
                Button { showingAccessibleSetup = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(L10n.text("apple.clientchatview.chat_setup.9fa79d00"))
                Spacer(minLength: 0)
                chrome
            }
            .dynamicTypeSize(.large)
        } else if compact && condensed {
            HStack(spacing: Theme.Space.xs) {
                if showCompactAgent {
                    ChatAgentField(model: model, chat: chat, locked: locked, compactLabel: true) { pickingAgent = true }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                Button { showingAccessibleSetup = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        #if os(macOS)
                        .frame(width: 28, height: 28)
                        #else
                        .frame(width: 44, height: 44)
                        #endif
                }
                #if os(macOS)
                .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(L10n.text("apple.clientchatview.chat_setup.9fa79d00"))
                chrome
            }
            .fixedSize(horizontal: !showCompactAgent, vertical: false)
        } else if compact {
            compactLayout
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.s) { content }
                    .fixedSize(horizontal: true, vertical: true)
                compactLayout
            }
        }
    }

    private var savedCopyLabel: some View {
        Label(L10n.text("apple.chatsetupheader.draft_on_this_device.8c266c9c"), systemImage: ActionIcon.edit.symbol)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                agentField
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                chrome
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    pills(fitsWidth: true)
                }
                .fixedSize(horizontal: true, vertical: true)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    pills(fitsWidth: true)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        agentField
        pills()
        chrome
    }

    private var agentField: some View {
        HStack(spacing: Theme.Space.s) {
            ChatAgentField(model: model, chat: chat, locked: locked) { pickingAgent = true }
            if model.landingDraft == nil {
                ChatRoutingControls(model: model, chat: chat, compact: true)
            }
        }
    }

    @ViewBuilder
    private func pills(fitsWidth: Bool = false) -> some View {
        ChatCompactPills(
            options: [
                (value: "plan", label: L10n.text("apple.chatsetupheader.plan.fa8ed0bd")),
                (value: "execute", label: L10n.text("apple.chatsetupheader.execute.e3a67d95")),
            ],
            selection: modeBinding,
            fitsWidth: fitsWidth
        )
        .disabled(locked)
        if isBypassOnly {
            ChatCompactPills(
                options: [(value: "bypass", label: L10n.text("apple.chatsetupheader.don_t_ask.15dae980"))],
                selection: autonomyBinding,
                fitsWidth: fitsWidth
            )
            .disabled(true)
        } else {
            ChatCompactPills(
                options: [
                    (value: "standard", label: L10n.text("apple.chatsetupheader.ask_first.4a9e8cf3")),
                    (value: "bypass", label: L10n.text("apple.chatsetupheader.don_t_ask.15dae980")),
                ],
                selection: autonomyBinding,
                fitsWidth: fitsWidth
            )
            .disabled(locked)
        }
    }

    private var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var isBypassOnly: Bool { backend?.gateTier == "bypassOnly" }

    private var modeBinding: Binding<String> {
        Binding(
            get: { chat.mode },
            set: { next in performSetupChange(model: model, chat: chat) { await model.update(mode: next) } }
        )
    }

    private var autonomyBinding: Binding<String> {
        Binding(
            get: { chat.autonomy },
            set: { next in performSetupChange(model: model, chat: chat) { await model.update(autonomy: next) } }
        )
    }

    private func enforceBypassOnly() {
        guard isBypassOnly, chat.autonomy != "bypass", !chat.running else { return }
        performSetupChange(model: model, chat: chat) { await model.update(autonomy: "bypass") }
    }
}

extension ChatComposerControls where Chrome == EmptyView {
    init(model: ChatModel, chat: ChatConversation, locked: Bool, compact: Bool = false, condensed: Bool = false) {
        self.init(model: model, chat: chat, locked: locked, compact: compact, condensed: condensed) { EmptyView() }
    }
}

/// What the agent picker offers and what picking a row does.
///
/// Not a view. The field that opens the panel and the panel itself are two
/// views now, in two places in the hierarchy, and they need the same summary,
/// the same rows and the same rules about which of the three settings a row
/// belongs to.
///
/// This was three nested menus, declared twice: once for macOS and once for
/// iOS, because iOS renders a nested `Menu` bottom-up inside the glass sheet
/// and the only way to keep the visual order the same on both was to write the
/// sections out backwards. That is gone. One panel, three sections, one
/// declaration, and the filter runs across all of them, so typing "meta" in a
/// forty-model list gets there in four keystrokes instead of a scroll.
@MainActor
struct ChatAgentChoices {
    let model: ChatModel
    let chat: ChatConversation

    enum Choice: Hashable {
        case agent(String)
        case model(String)
        case effort(String)
    }

    var backend: ChatBackend? { model.backend(for: chat.backend) }
    private var agentLabel: String {
        if let backend { return backend.label }
        return chat.backend.isEmpty || chat.backend == "agent"
            ? L10n.text("common.chat.select_agent") : chat.backend
    }

    var choices: [PickerChoice<Choice>] {
        var rows = agentOptions.map {
            PickerChoice(value: Choice.agent($0.value), label: $0.label,
                         detail: readiness($0.value) == "needsSignIn" ? L10n.text("apple.chatsetupheader.sign_in_may_be_needed.c3dde98c") :
                            readiness($0.value) == "expired" ? L10n.text("apple.chatsetupheader.stored_login_has_expired.bf189dae") : nil,
                         section: L10n.text("apple.chatsetupheader.agent.11b39c93"),
                         monospaced: false)
        }
        if let backend, backend.installed != false {
            rows.append(
                PickerChoice(
                    value: .model(""),
                    label: L10n.text("apple.chatsetupheader.default.21b111cb"),
                    detail: L10n.text("apple.chatsetupheader.0_picks_the_model.59367853", "\(backend.label)"),
                    section: L10n.text("apple.chatsetupheader.model.5e2c614c")
                )
            )
            rows += modelIDs.map { id in
                let local = LocalChatModel.parse(id)
                let detail: String? = !backend.models.contains(id)
                    ? L10n.text("apple.chatsetupheader.saved_choice_availability_unverified.96a7ce32")
                    : local.map {
                        let place = model.peer == nil
                            ? L10n.text("common.chat.local_model_here", LocalChatModel.providerName($0.provider))
                            : L10n.text("common.chat.local_model_host", LocalChatModel.providerName($0.provider))
                        guard let tokens = backend.contextLength(of: id), tokens < LocalChatModel.roomyContext else { return place }
                        return place + " · " + L10n.text("common.chat.local_model_small", "\(tokens / 1024)K")
                    }
                return PickerChoice(value: Choice.model(id), label: local?.model ?? id, detail: detail,
                                    section: L10n.text("apple.chatsetupheader.model.5e2c614c"))
            }
        }
        if let backend, backend.installed != false, !backend.efforts.isEmpty {
            rows.append(PickerChoice(value: .effort(""), label: L10n.text("apple.chatsetupheader.default.21b111cb"), section: L10n.text("apple.chatsetupheader.effort.4387e5d3")))
            rows += backend.efforts.map {
                PickerChoice(value: Choice.effort($0), label: $0, section: L10n.text("apple.chatsetupheader.effort.4387e5d3"))
            }
        }
        return rows
    }

    private func readiness(_ id: String) -> String? {
        guard let backend = model.backend(for: id) else { return nil }
        return model.signInReadiness(for: backend, chat: chat)
    }

    var selectableSections: [String] {
        var seen = Set<String>()
        return choices.compactMap { choice in
            seen.insert(choice.section).inserted ? choice.section : nil
        }
    }

    func currentValue(_ section: String) -> String? {
        let values: [String: String?] = [
            L10n.text("apple.chatsetupheader.agent.11b39c93"): agentLabel,
            L10n.text("apple.chatsetupheader.model.5e2c614c"): chat.model?.isEmpty == false
                ? chat.model.map { LocalChatModel.parse($0)?.model ?? $0 }
                : L10n.text("apple.chatsetupheader.default.21b111cb"),
            L10n.text("apple.chatsetupheader.effort.4387e5d3"): chat.effort?.isEmpty == false ? chat.effort : L10n.text("apple.chatsetupheader.default.21b111cb"),
        ]
        return values[section] ?? nil
    }

    func searchPrompt(_ section: String) -> String {
        let prompts: [String: String] = [
            L10n.text("apple.chatsetupheader.agent.11b39c93"): L10n.text("apple.chatsetupheader.search_agents.212fd04a"),
            L10n.text("apple.chatsetupheader.model.5e2c614c"): L10n.text("apple.chatsetupheader.search_models.10421935"),
            L10n.text("apple.chatsetupheader.effort.4387e5d3"): L10n.text("apple.chatsetupheader.search_efforts.f7909b52"),
        ]
        return prompts[section] ?? L10n.text("apple.chatsetupheader.filter_agents_models_and_efforts.315032da")
    }

    func isSelected(_ choice: Choice) -> Bool {
        switch choice {
        case let .agent(id): id == chat.backend
        case let .model(id): id == (chat.model ?? "")
        case let .effort(id): id == (chat.effort ?? "")
        }
    }

    func apply(_ choice: Choice) async {
        switch choice {
        case let .agent(id):
            if model.backend(for: id)?.gateTier == "bypassOnly" {
                await model.update(backend: id, autonomy: "bypass")
            } else {
                await model.update(backend: id)
            }
        case let .model(id):
            await model.requestModelChange(id)
        case let .effort(id):
            await model.update(effort: id)
        }
    }

    var agentOptions: [(value: String, label: String)] {
        model.backends
            .filter { ($0.id != "sh" || $0.id == chat.backend) && $0.installed != false }
            .map { (value: $0.id, label: $0.label) }
    }

    var modelIDs: [String] {
        guard let backend, backend.installed != false else { return [] }
        var ids = backend.models
        let extra = chat.model ?? ""
        if !extra.isEmpty, !ids.contains(extra) {
            ids.insert(extra, at: 0)
        }
        let favs = ModelFavoritesStore.shared.ids(for: backend.id).filter { ids.contains($0) }
        let rest = ids.filter { !favs.contains($0) }
        return favs + rest
    }

    var compactSummary: String {
        var parts = [chat.model.flatMap { $0.isEmpty ? nil : (LocalChatModel.parse($0)?.model ?? $0) } ?? agentLabel]
        if backend?.efforts.isEmpty == false, let effort = chat.effort, !effort.isEmpty {
            parts.append(effort)
        }
        if let profile = model.profileTitle(chat) { parts.append(profile) }
        return parts.joined(separator: " · ")
    }

    var summary: String {
        let agent = agentLabel
        var parts = [agent]
        if let name = chat.model, !name.isEmpty {
            parts.append(LocalChatModel.title(name))
        }
        if backend?.efforts.isEmpty == false, let effort = chat.effort, !effort.isEmpty {
            parts.append(L10n.text("apple.chatsetupheader.0_effort.b0d63362", "\(effort)"))
        }
        if let profile = model.profileTitle(chat) { parts.append(profile) }
        return parts.joined(separator: " · ")
    }
}

struct ChatAgentField: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool
    var compactLabel = false
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                if compactLabel { HarnessMark(id: chat.backend, size: 16).accessibilityHidden(true) }
                fieldLabel
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.fixed(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
            .background { ChipHoverFill() }
            .chatControlChrome()
            .overlay(alignment: .topTrailing) {
                if updateWaiting {
                    Circle().fill(Theme.accent)
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChipButtonStyle())
        .disabled(locked)
        .fixedSize(horizontal: false, vertical: true)
        .help(updateWaiting ? L10n.text("common.agent_updates.waiting")
              : L10n.text("apple.chatsetupheader.agent_model_and_effort.217ff8ae"))
        .accessibilityLabel(updateWaiting ? choices.summary + ", " + L10n.text("common.agent_updates.waiting") : choices.summary)
    }

    private var choices: ChatAgentChoices { ChatAgentChoices(model: model, chat: chat) }

    @ViewBuilder private var fieldLabel: some View {
        Group {
            if compactLabel, let profile = model.profileTitle(chat) {
                ViewThatFits(in: .horizontal) {
                    Text(choices.compactSummary).fixedSize(horizontal: true, vertical: false)
                    Text(profile).truncationMode(.tail)
                }
            } else {
                Text(compactLabel ? choices.compactSummary : choices.summary).truncationMode(.middle)
            }
        }
        #if os(macOS)
        .font(Theme.font(12, weight: .medium))
        #else
        .font(Theme.callout.weight(.medium))
        #endif
        .lineLimit(compactLabel ? 1 : 2)
        .minimumScaleFactor(compactLabel ? 0.85 : 1)
    }

    private var updateWaiting: Bool {
        model.backend(for: chat.backend).map { $0.updateAvailable && $0.installed != false } ?? false
    }
}

struct AgentUpdatePill: View {
    let backend: ChatBackend
    let updating: Bool
    let enabled: Bool
    let onUpdate: () -> Void

    var body: some View {
        Button(updating ? L10n.text("common.agent_updates.updating") : L10n.text("common.agent_updates.update"), .download, action: onUpdate)
            .labelStyle(.iconOnly)
            .font(Theme.font(11, weight: .semibold))
            .buttonStyle(QuietLinkStyle())
            .foregroundStyle(Theme.accent)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Theme.accent.opacity(0.16)))
            .overlay {
                if updating { ProgressView().controlSize(.mini).tint(Theme.accent) }
            }
            .fixedSize()
            .disabled(!enabled || updating)
            .help(label)
            .accessibilityLabel(label)
    }

    private var label: String {
        backend.latestVersion.map { L10n.text("common.agent_updates.update_to", backend.label, $0) }
            ?? L10n.text("common.agent_updates.update")
    }
}

struct ChatAgentPanel: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    var locked: Bool
    var onDone: () -> Void = {}

    @State private var continuingProfile: AgentProfile?
    @State private var addingProfile = false
    @State private var newProfileName = ""
    @State private var showingSetup = false
    @State private var installing: String?
    @State private var signInBackend: ChatBackend?
    @State private var setupError: String?
    @State private var canRefresh = false
    @State private var refreshingAgents = false
    @State private var updating = false
    @State private var favorites = ModelFavoritesStore.shared
    @State private var versions: [String: AgentUpdateRow] = [:]
    @State private var supportsUpdates = false
    @State private var checkingUpdates = false
    @State private var updatingAll = false
    @State private var checkedUpdates = false
    @State private var updateNotes: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack {
                Text(L10n.text("apple.chatsetupheader.agent_model_and_effort.217ff8ae")).font(Theme.callout.weight(.semibold))
                Spacer()
                Button(L10n.text("common.done"), .done) { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.s)
            #endif
            if showingSetup {
                setupList
            } else {
                PickerOptionList(
                    choices: choices.choices,
                    isSelected: choices.isSelected,
                    prompt: L10n.text("apple.chatsetupheader.filter_agents_models_and_efforts.315032da"),
                    emptyMessage: L10n.text("apple.chatsetupheader.no_agents_installed_set_up_an_agent_to_sta.2f73b57f"),
                    caption: pickerCaption,
                    header: profileRow,
                    refresh: nil,
                    sectionValue: choices.currentValue,
                    sectionTabs: choices.selectableSections,
                    stepped: true,
                    stepPrompt: choices.searchPrompt,
                    finish: onDone,
                    stepPick: pick,
                    selectionSummary: choices.summary,
                    pick: { _ in },
                    accessory: { value in AnyView(star(for: value)) },
                    icon: { value in
                        switch value {
                        case let .agent(id):
                            return AnyView(HarnessMark(id: id, size: 26))
                        case let .model(id) where !id.isEmpty:
                            let local = LocalChatModel.parse(id) != nil
                            return AnyView(
                                Image(systemName: local ? "desktopcomputer" : "cloud")
                                    .font(Theme.font(12, weight: .medium))
                                    .foregroundStyle(local ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                            )
                        default:
                            return nil
                        }
                    },
                    trailing: { value in
                        guard case let .agent(id) = value else { return nil }
                        return AnyView(HStack(spacing: Theme.Space.s) {
                            if let backend = model.backend(for: id), backend.updateAvailable, backend.installed != false {
                                AgentUpdatePill(
                                    backend: backend,
                                    updating: model.updatingAgentID == backend.launcherID,
                                    enabled: model.updatingAgentID == nil && installing == nil && !locked
                                ) { Task { await model.updateAgent(id: backend.launcherID ?? backend.id, label: backend.label) } }
                            }
                            if let backend = model.backend(for: id), model.usesOwnLogin(backend, chat: chat) {
                                if model.peer == nil && model.signInReadiness(for: backend, chat: chat) == "needsSignIn" {
                                    Button(L10n.text("common.sign_in"), .signIn) { signInBackend = backend }
                                        .buttonStyle(.borderless)
                                } else {
                                    AgentLimitsSummary(backend: id, peer: model.peer, profileID: model.profileID(for: chat))
                                }
                            } else {
                                AgentLimitsSummary(backend: id, peer: model.peer)
                            }
                        })
                    }
                )
                .disabled(updating || locked)
                .task(id: model.peer ?? "local") {
                    canRefresh = await RemoteHostFeature.modelRefresh.isSupported(peer: model.peer)
                    supportsUpdates = await RemoteHostFeature.agentUpdates.isSupported(peer: model.peer)
                    await model.reloadBackends(refreshModels: false)
                }
            }
            if choices.backend?.modelListStatus == "refreshFailed" {
                Text(L10n.text("apple.chatsetupheader.couldn_t_refresh_models_use_the_agent_defa.d28dc412"))
                    .font(Theme.caption).foregroundStyle(Theme.warning).padding(.horizontal, Theme.Space.s)
            } else if choices.backend?.modelListStatus == "loading" {
                Text(L10n.text("apple.chatsetupheader.checking_models_agent_default_is_available.6cb73a5c"))
                    .font(Theme.caption).foregroundStyle(Theme.controlGlyph).padding(.horizontal, Theme.Space.s)
            }
            if let error = setupError ?? model.backendRefreshError {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
                    .padding(.horizontal, Theme.Space.s)
            }
            HStack {
                Button(showingSetup ? L10n.text("apple.chatsetupheader.back_to_agent_choices.a5dc0271") : L10n.text("apple.chatsetupheader.set_up_another_agent.ba92ba58"), showingSetup ? .back : .create) {
                    showingSetup.toggle()
                }
                Spacer(minLength: 0)
                Button(refreshingAgents ? L10n.text("common.agent_updates.checking") : L10n.text("common.refresh"), .refresh) {
                    Task { await refreshAll() }
                }
                .help(L10n.text("common.agent_updates.refresh_help"))
                .disabled(installing != nil || locked || refreshingAgents)
                .opacity(refreshingAgents ? 0.5 : 1)
            }
            .font(Theme.caption)
            .padding(Theme.Space.s)
            .disabled(locked)
        }
        .task(id: model.peer ?? "local") { await model.refreshAgentProfiles() }
        .task(id: ProfileProbeKey(profile: model.profileID(for: chat), catalog: model.agentProfiles,
                                  agents: model.backends.map(\.id))) {
            for backend in model.backends where model.usesOwnLogin(backend, chat: chat) && backend.installed == true {
                guard !Task.isCancelled else { return }
                _ = await model.checkSignIn(backend)
            }
        }
        .sheet(item: $signInBackend) { backend in
            AgentSignInSheet(backend: backend, peer: model.peer, profileID: model.profileID(for: chat),
                             profileTitle: model.profileTitle(chat)) {
                let status = await model.checkSignIn(backend)
                guard model.backendRefreshError == nil else { return .unavailable }
                return status?.outcome ?? .unconfirmed
            }
        }
        .alert(L10n.text("common.profiles.add"), isPresented: $addingProfile) {
            if model.peer == nil {
                TextField(L10n.text("apple.profiles.name"), text: $newProfileName)
                Button(L10n.text("common.cancel"), role: .cancel) {}
                Button(L10n.text("common.profiles.add")) { createProfile() }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button(L10n.text("common.done"), role: .cancel) {}
            }
        } message: {
            Text(model.peer == nil ? L10n.text("common.profiles.add_message") : L10n.text("common.profiles.add_on_host"))
        }
        .alert(L10n.text("apple.profiles.continue", continuingProfile?.title ?? ""), isPresented: Binding(
            get: { continuingProfile != nil }, set: { if !$0 { continuingProfile = nil } }
        ), presenting: continuingProfile) { profile in
            Button(L10n.text("common.cancel"), role: .cancel) {}
            Button(L10n.text("apple.profiles.continue", profile.title)) {
                performSetupChange(model: model, chat: chat) {
                    if await model.continueInNew(chat, expectedDraft: model.draft, profileID: profile.id) != nil {
                        onDone()
                    }
                }
            }
        } message: { profile in
            Text(continueMessage(chat: chat, profile: profile, peer: model.peer))
        }
    }

    private func continueMessage(chat: ChatConversation, profile: AgentProfile, peer: String?) -> String {
        var parts = [L10n.text("apple.profiles.continue_message", profile.title)]
        if let cache = chat.promptCache {
            parts.append(L10n.text("apple.profiles.continue_cache",
                                   cache.tokens.formatted(.number.grouping(.automatic))))
        }
        let readings = ChatPlanLimits.store(peer: peer)
        if let provider = ComposerLimits.pick(
            backend: chat.backend, canonical: harnessCanonicalID,
            providers: readings.visible.filter { $0.profileId == profile.id },
            source: \.source, hasWindows: \.hasWindows
        ) {
            let rows = harnessCanonicalID(provider.source) == "codex"
                ? ComposerLimits.codexHeadlineRows(windows: provider.windows, label: \.label, scope: \.scope)
                : ComposerLimits.badgeRows(windows: provider.windows, label: \.label, scope: \.scope)
            let windows = rows.map {
                L10n.text("apple.composerlimitsbadge.0_1_percent.f674c60d", $0.display,
                          $0.window.percent.formatted(.number.precision(.fractionLength(0))))
            }.joined(separator: ", ")
            if !windows.isEmpty {
                parts.append(L10n.text("apple.profiles.continue_limits", profile.title, windows))
            }
        }
        return parts.joined(separator: "\n")
    }

    private struct ProfileProbeKey: Equatable {
        let profile: String?
        let catalog: AgentProfiles?
        let agents: [String]
    }

    private var pickerCaption: String? {
        if model.peer != nil { return L10n.text("apple.chatsetupheader.agents_on_this_chat_s_remote_host.2c090971") }
        #if os(macOS)
        if model.agentProfiles != nil { return nil }
        #endif
        return L10n.text("apple.chatsetupheader.agents_on_this_computer.133ab3d5")
    }

    private var profileRow: AnyView? {
        guard let profiles = model.agentProfiles else { return nil }
        let selected = model.profileID(for: chat) ?? AgentProfiles.system
        let current = profiles.profile(selected)?.title ?? L10n.text("apple.profiles.unavailable")
        if let lock = model.workspaceProfileLock, let profile = profiles.profile(lock) {
            if selected != lock && !locked {
                return AnyView(
                    Button { continuingProfile = profile } label: {
                        ProfileRowLabel(title: current, detail: L10n.text("apple.profiles.continue", profile.title),
                                        symbol: "arrow.turn.down.right")
                    }
                    .buttonStyle(.plain)
                )
            }
            return AnyView(
                ProfileRowLabel(title: profile.title, detail: L10n.text("apple.profiles.locked", profile.title),
                                symbol: "lock.fill")
                    .help(L10n.text("apple.profiles.locked", profile.title))
            )
        }
        return AnyView(
            Menu {
                Section {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            guard selected != profile.id else { return }
                            if chat.lastMessageAtMs != nil || chat.resumeToken != nil {
                                continuingProfile = profile
                            } else {
                                performSetupChange(model: model, chat: chat) { await model.update(profileID: profile.id) }
                            }
                        } label: {
                            if selected == profile.id { Label(profile.title, systemImage: "checkmark") }
                            else { Text(profile.title) }
                        }
                    }
                } header: {
                    ProfileMenuHeader()
                }
                Section {
                    Button(L10n.text("common.profiles.add_ellipsis"), .create) {
                        newProfileName = ""
                        addingProfile = true
                    }
                }
            } label: {
                ProfileRowLabel(title: current,
                                detail: Self.profileRowDetail(main: selected == AgentProfiles.system),
                                chevron: true)
            }
            .modifier(ProfileMenuStyle())
            .menuIndicator(.hidden)
            .disabled(locked || updating)
            .accessibilityLabel(L10n.text("apple.profiles.profile"))
            .accessibilityValue(current)
        )
    }

    #if os(macOS)
    private static func profileRowDetail(main: Bool) -> String { L10n.text("apple.profiles.profile") }
    #else
    private static func profileRowDetail(main: Bool) -> String {
        L10n.text(main ? "common.profiles.main_detail" : "common.profiles.row_detail")
    }
    #endif

    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, model.peer == nil else { return }
        Task {
            do {
                let created = try await Bridge.createAgentProfile(name: name)
                AgentProfileCatalog.shared.replace(created.profiles)
                if chat.lastMessageAtMs == nil && chat.resumeToken == nil {
                    performSetupChange(model: model, chat: chat) { await model.update(profileID: created.id) }
                }
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    private var setupList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text(model.peer == nil ? L10n.text("apple.chatsetupheader.set_up_on_this_computer.ba4e1cd3") : L10n.text("apple.chatsetupheader.set_up_on_this_chat_s_remote_host.95b6115d"))
                        .font(Theme.callout.weight(.semibold))
                    Spacer(minLength: Theme.Space.s)
                    if supportsUpdates, !behind.isEmpty {
                        Button(updateAllTitle, .download) { Task { await updateAll() } }
                            .font(Theme.caption)
                            .disabled(updatingAll || checkingUpdates || refreshingAgents
                                      || model.updatingAgentID != nil || installing != nil || locked)
                    }
                }
                ForEach(model.backends.filter { $0.id != "sh" }) { backend in
                    let row = backend.launcherID.flatMap { versions[$0] }
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backend.label).font(Theme.callout)
                            Text(backend.installed == false ? L10n.text("apple.chatsetupheader.not_installed.d177cdc0") :
                                 ["needsSignIn", "expired"].contains(model.signInReadiness(for: backend, chat: chat) ?? "")
                                 ? L10n.text("apple.chatsetupheader.open_this_agent_in_the_host_s_terminal_to.717a86f6")
                                 : backend.installed == true ? L10n.text("apple.chatsetupheader.installed.f8b32f4e") : L10n.text("apple.chatsetupheader.availability_unknown.2e0078a8"))
                                .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                            if backend.installed != false, let row {
                                versionLine(row)
                            }
                            if let id = backend.launcherID, let note = updateNotes[id] {
                                Text(note).font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        if backend.installed != false, let row, offersUpdate(row) {
                            Button(model.updatingAgentID == row.id ? L10n.text("common.agent_updates.updating") : L10n.text("common.agent_updates.update"), .download) {
                                Task { await update(row) }
                            }
                            .disabled(model.updatingAgentID != nil || installing != nil || checkingUpdates || locked || row.busy)
                            .help(row.busy ? L10n.text("common.agent_updates.busy") : "")
                        } else if backend.installed == false && backend.canInstall {
                            Button(installing == backend.id ? L10n.text("apple.chatsetupheader.installing.530bcc35") : L10n.text("apple.chatsetupheader.install.569ca49f"), .download) {
                                install(backend)
                            }
                            .disabled(installing != nil || locked)
                        } else if backend.signInFlow?.supported == true && (model.peer == nil || !model.usesOwnLogin(backend, chat: chat)) {
                            Button(L10n.text("apple.agentsetup.sign_in", backend.label), .signIn) { signInBackend = backend }
                                .disabled(installing != nil || locked)
                        }
                    }
                }
            }.padding(Theme.Space.s)
        }
        .task(id: model.peer ?? "local") {
            supportsUpdates = await RemoteHostFeature.agentUpdates.isSupported(peer: model.peer)
            checkedUpdates = false
            updateNotes = [:]
            if supportsUpdates { await loadVersions(check: false) }
        }
    }

    @ViewBuilder
    private func versionLine(_ row: AgentUpdateRow) -> some View {
        let parts: [String] = [
            row.version.map { L10n.text("common.agent_updates.version", $0) },
            row.updateAvailable == true ? row.latest.map { L10n.text("common.agent_updates.available", $0) } : nil,
            checkedUpdates && row.updateAvailable == false ? L10n.text("common.agent_updates.up_to_date") : nil,
            checkedUpdates && !row.canCheck ? L10n.text("common.agent_updates.unknown_latest") : nil,
            row.error.map { L10n.text("common.agent_updates.check_failed", $0) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.caption)
                .foregroundStyle(row.updateAvailable == true ? Theme.accent : Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func offersUpdate(_ row: AgentUpdateRow) -> Bool {
        supportsUpdates && row.canUpdate
            && (row.updateAvailable == true || (checkedUpdates && !row.canCheck))
    }

    private var behind: [AgentUpdateRow] {
        model.backends.compactMap { backend in
            guard backend.installed != false, let id = backend.launcherID, let row = versions[id],
                  row.canUpdate, row.updateAvailable == true, !row.busy else { return nil }
            return row
        }
    }

    private var updateAllTitle: String {
        updatingAll ? L10n.text("common.agent_updates.updating")
            : L10n.text("common.agent_updates.update_all", "\(behind.count)")
    }

    private func updateAll() async {
        guard !updatingAll else { return }
        updatingAll = true
        defer { updatingAll = false }
        for row in behind {
            guard !Task.isCancelled else { return }
            await update(row)
        }
    }

    private func refreshAll() async {
        guard !refreshingAgents else { return }
        refreshingAgents = true
        defer { refreshingAgents = false }
        if supportsUpdates { await loadVersions(check: true) }
        await model.reloadBackends(refreshModels: canRefresh)
    }

    private func loadVersions(check: Bool) async {
        let peer = model.peer
        if check { checkingUpdates = true }
        defer { if check { checkingUpdates = false } }
        do {
            let rows = try await Bridge.agentUpdates(check: check, peer: peer)
            guard model.peer == peer else { return }
            versions = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            if check { checkedUpdates = true }
        } catch {
            guard model.peer == peer, check else { return }
            setupError = error.localizedDescription
        }
    }

    private func update(_ row: AgentUpdateRow) async {
        updateNotes[row.id] = nil
        let label = model.backends.first { $0.launcherID == row.id }?.label ?? row.name ?? row.id
        guard let result = await model.updateAgent(id: row.id, label: label) else { return }
        if result.ok {
            updateNotes[row.id] = result.after.map { L10n.text("common.agent_updates.updated", $0) }
                ?? L10n.text("common.agent_updates.updated_unknown")
            if var refreshed = versions[row.id] {
                refreshed.version = result.after ?? refreshed.version
                refreshed.updateAvailable = false
                versions[row.id] = refreshed
            }
        } else {
            let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            updateNotes[row.id] = L10n.text("common.agent_updates.failed", String(tail.suffix(600)))
        }
    }

    private func install(_ backend: ChatBackend) {
        guard let id = backend.launcherID, installing == nil else { return }
        let peer = model.peer
        installing = backend.id
        setupError = nil
        Task {
            defer { installing = nil }
            do {
                let result: LauncherInstallResult
                if let peer {
                    result = try await Bridge.onPeer(peer, "launcher.install", ["id": id], patience: Bridge.Patience.long, as: LauncherInstallResult.self)
                } else {
                    result = try await Bridge.launcherInstall(id: id)
                }
                guard model.peer == peer else { return }
                if !result.ok { setupError = L10n.text("apple.chatsetupheader.installation_failed_0.f293f900", "\(result.output.suffix(600))") }
                await model.reloadBackends()
            } catch {
                guard model.peer == peer else { return }
                setupError = error.localizedDescription
            }
        }
    }

    private var choices: ChatAgentChoices { ChatAgentChoices(model: model, chat: chat) }

    private func pick(_ choice: ChatAgentChoices.Choice) async -> [String]? {
        guard !updating, !locked else { return nil }
        let choices = self.choices
        if case let .agent(id) = choice, model.backend(for: id)?.installed == false { return nil }
        guard let owner = model.currentReference, model.currentReference == owner,
              model.selected?.id == chat.id, model.savedCopy == nil,
              model.selected?.running == false else { return nil }
        if choices.isSelected(choice) { return choices.selectableSections }
        updating = true
        defer { updating = false }
        await choices.apply(choice)
        guard model.currentReference == owner, let updated = model.selected, updated.id == chat.id else { return nil }
        let updatedChoices = ChatAgentChoices(model: model, chat: updated)
        guard updatedChoices.isSelected(choice) else { return nil }
        return updatedChoices.selectableSections
    }

    @ViewBuilder
    private func star(for choice: ChatAgentChoices.Choice) -> some View {
        if case let .model(id) = choice, !id.isEmpty, let backend = choices.backend {
            Button {
                favorites.toggle(backend: backend.id, model: id)
            } label: {
                Image(systemName: favorites.contains(backend: backend.id, model: id)
                    ? "star.fill" : "star")
                    .frame(width: Theme.Control.heightComfortable, height: Theme.Control.heightComfortable)
                    .contentShape(.rect)
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(
                        favorites.contains(backend: backend.id, model: id)
                            ? Theme.accent : Color.secondary.opacity(0.4)
                    )
            }
            .buttonStyle(ControlFeedbackStyle(pressScale: 0.9))
            .accessibilityLabel(
                favorites.contains(backend: backend.id, model: id)
                    ? L10n.text("apple.chatsetupheader.unpin_0.450ccf9f", "\(id)") : L10n.text("apple.chatsetupheader.pin_0.67fd141b", "\(id)")
            )
        }
    }
}

extension View {
    @ViewBuilder
    func chatControlChrome(cornerRadius: CGFloat = 8) -> some View {
        #if os(macOS)
        chatControlPanel(cornerRadius: cornerRadius)
        #else
        if #available(iOS 26, *) {
            overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border.opacity(0.7), lineWidth: 1)
            }
        } else {
            chatControlPanel(cornerRadius: cornerRadius)
        }
        #endif
    }

    private func chatControlPanel(cornerRadius: CGFloat) -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
    }
}

struct ChatCompactPills: View {
    var options: [(value: String, label: String)]
    @Binding var selection: String
    var fitsWidth = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(option.value == selection ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        #if !os(macOS)
                        .frame(minHeight: 44)
                        #endif
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option.value == selection ? Theme.accentSoft : .clear)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(QuietLinkStyle())
            }
        }
        .padding(3)
        .chatControlChrome(cornerRadius: 10)
        .fixedSize(horizontal: !fitsWidth, vertical: true)
        .frame(maxWidth: fitsWidth ? .infinity : nil, alignment: .leading)
    }
}

/// Capture before scheduling so a control cannot apply to a later selection.
@MainActor
func performSetupChange(
    model: ChatModel, chat: ChatConversation,
    operation: @escaping @MainActor () async -> Void
) {
    let owner = model.currentReference
    Task {
        guard let owner, model.currentReference == owner,
              model.selected?.id == chat.id, model.savedCopy == nil,
              model.selected?.running == false else { return }
        await operation()
    }
}

struct ChatAgentAvailabilityNotice: View {
    @Bindable var model: ChatModel
    let chat: ChatConversation
    @State private var showingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.chatsetupheader.0_isn_t_installed_on_this_computer.27bea130", "\(model.backend(for: chat.backend)?.label ?? chat.backend)"))
                .font(Theme.caption).foregroundStyle(Theme.warning)
            Button(L10n.text("apple.chatsetupheader.set_up_or_choose_another_agent.f544267b"), .create) { showingOptions = true }
                .font(Theme.caption)
        }
        .pickerPanelSurface(title: L10n.text("apple.chatsetupheader.agent_options.31eb33af"), isPresented: $showingOptions) {
            ChatAgentPanel(model: model, chat: chat, locked: chat.running,
                           onDone: { showingOptions = false })
        }
    }
}

enum ChatSectionStyle {
    case card, flat
}

private struct ChatSectionStyleKey: EnvironmentKey {
    static let defaultValue = ChatSectionStyle.card
}

extension EnvironmentValues {
    var chatSectionStyle: ChatSectionStyle {
        get { self[ChatSectionStyleKey.self] }
        set { self[ChatSectionStyleKey.self] = newValue }
    }
}

private struct ChatSectionSurface: ViewModifier {
    @Environment(\.chatSectionStyle) private var style

    func body(content: Content) -> some View {
        switch style {
        case .card:
            content
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        case .flat:
            content
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.hairline).frame(height: 1).accessibilityHidden(true)
                }
        }
    }
}

extension View {
    func chatSectionSurface() -> some View { modifier(ChatSectionSurface()) }
}

struct ChatSetupSection<Content: View, Primary: View>: View {
    let title: String
    let icon: ActionIcon
    var subtitle: String? = nil
    var summary: String? = nil
    let primary: Primary
    let content: Content
    private let externalExpansion: Binding<Bool>?
    @State private var localExpansion: Bool

    init(title: String, icon: ActionIcon, subtitle: String? = nil, summary: String? = nil,
         initiallyExpanded: Bool = false, expanded: Binding<Bool>? = nil,
         primary: Primary, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.summary = summary
        self.primary = primary
        self.content = content()
        externalExpansion = expanded
        _localExpansion = State(initialValue: initiallyExpanded)
    }

    private var expansion: Binding<Bool> { externalExpansion ?? $localExpansion }
    private var expanded: Bool { expansion.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { expansion.wrappedValue.toggle() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: icon.symbol).accessibilityHidden(true)
                        Text(title)
                        Spacer(minLength: 8)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(Theme.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    }.font(Theme.callout.weight(.semibold))
                    if let summary, !summary.isEmpty {
                        Text(summary).font(Theme.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowFeedbackStyle(bleed: 6, radius: 8))
            .accessibilityValue(expanded ? L10n.text("common.collapse") : L10n.text("common.expand"))
            primary
            if expanded {
                if let subtitle {
                    Text(subtitle).font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .chatSectionSurface()
    }
    private var rowHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }
}

extension ChatSetupSection where Primary == EmptyView {
    init(title: String, icon: ActionIcon, subtitle: String? = nil, summary: String? = nil,
         initiallyExpanded: Bool = false, expanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, subtitle: subtitle, summary: summary,
                  initiallyExpanded: initiallyExpanded, expanded: expanded, primary: EmptyView(), content: content)
    }
}

private struct ChatAgentPickerFocusKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var chatAgentPickerFocus: (Bool) -> Void {
        get { self[ChatAgentPickerFocusKey.self] }
        set { self[ChatAgentPickerFocusKey.self] = newValue }
    }
}

private struct ProfileMenuHeader: View {
    var body: some View {
        #if !os(macOS)
        Text(L10n.text("common.profiles.explain"))
        #endif
    }
}

private struct ProfileMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.menuStyle(.button).buttonStyle(.plain)
        #else
        content
        #endif
    }
}

private struct ProfileRowLabel: View {
    let title: String
    let detail: String
    var symbol = "person.crop.circle"
    var chevron = false

    var body: some View {
        #if os(macOS)
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.accentSoft))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.callout.weight(.semibold))
                .foregroundStyle(Self.label)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Self.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Self.secondaryLabel)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(Rectangle())
        #else
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(Theme.font(rowIcon, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: rowIcon * 2, height: rowIcon * 2)
                .background(Circle().fill(Theme.accentSoft))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(Self.label)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(Self.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.font(11, weight: .semibold))
                    .foregroundStyle(Self.secondaryLabel)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.hairline))
        .contentShape(Rectangle())
        #endif
    }

    #if os(macOS)
    private static let label = Color(nsColor: .labelColor)
    private static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    #else
    private static let label = Color(uiColor: .label)
    private static let secondaryLabel = Color(uiColor: .secondaryLabel)
    #endif

    #if os(macOS)
    private let rowIcon: CGFloat = 11
    private let rowPadding: CGFloat = 6
    #else
    private let rowIcon: CGFloat = 14
    private let rowPadding: CGFloat = 10
    #endif
}
