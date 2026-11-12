// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// When a message is about to make the agent read a whole conversation again.
///
/// The provider caches the conversation for one model, for a few minutes or an
/// hour after the last turn. A message after that, or on another model, is read
/// in full. The host records the size, model and lifetime after every turn
/// (`ChatPromptCache`), and these rules decide whether that is worth a question.
/// No percentage of a plan is shown: nobody publishes how tokens map onto one.
enum ChatPromptCacheRule {
    /// Below this a full read is cheap, and a question would only be noise.
    static let minimumTokens: UInt64 = 50_000
    static let idleSuppressedKey = "chat.cacheWarning.idle.suppressed"
    static let modelSuppressedKey = "chat.cacheWarning.model.suppressed"

    /// The record, when it belongs to the agent the chat is on now and is big
    /// enough to matter.
    static func cache(_ chat: ChatConversation) -> ChatPromptCache? {
        guard let cache = chat.promptCache, cache.backend == chat.backend,
              cache.tokens >= minimumTokens else { return nil }
        return cache
    }

    /// How long the cache has been gone, or nil while it still holds.
    static func idle(_ chat: ChatConversation, nowMs: Int64) -> Int64? {
        guard let cache = cache(chat) else { return nil }
        let idle = nowMs - cache.atMs
        return idle > cache.ttlMs ? idle : nil
    }

    /// A warm cache on another model. A cold one costs the same either way,
    /// and the send warning covers it.
    static func switching(_ chat: ChatConversation, to next: String, nowMs: Int64) -> Bool {
        guard let cache = cache(chat), nowMs - cache.atMs <= cache.ttlMs else { return false }
        return (cache.selection ?? "") != next
    }

    static func tokens(_ count: UInt64) -> String {
        Double(count).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func duration(_ milliseconds: Int64) -> String {
        Duration.milliseconds(milliseconds).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))
    }

    static func modelName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return L10n.text("common.chat.cache.default_model") }
        return id
    }

    static func isSuppressed(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

/// One question waiting for an answer, held by `ChatModel` so any view that
/// changes the chat can raise it and the chat view answers it.
struct ChatCacheWarning: Identifiable {
    enum Kind {
        /// Sending after the cache expired. `startNew` is nil when this message
        /// cannot move, because it has files attached to this chat or the
        /// host is too old to start a continuing chat.
        case idle(idleMs: Int64, startNew: (@MainActor () -> Void)?)
        case modelSwitch(from: String?, to: String)
    }

    let id = UUID()
    let kind: Kind
    let tokens: UInt64
    let proceed: @MainActor () -> Void

    var title: String {
        switch kind {
        case .idle: L10n.text("common.chat.cache.resume_title")
        case .modelSwitch: L10n.text("common.chat.cache.switch_title")
        }
    }

    var message: String {
        let size = ChatPromptCacheRule.tokens(tokens)
        switch kind {
        case let .idle(idleMs, startNew):
            let base = L10n.text("common.chat.cache.resume_message",
                                 ChatPromptCacheRule.duration(idleMs), size)
            guard startNew != nil else { return base }
            return base + "\n\n" + L10n.text("common.chat.cache.resume_new_hint")
        case let .modelSwitch(from, to):
            return L10n.text("common.chat.cache.switch_message",
                             ChatPromptCacheRule.modelName(from), ChatPromptCacheRule.modelName(to), size)
        }
    }

    var suppressionKey: String {
        switch kind {
        case .idle: ChatPromptCacheRule.idleSuppressedKey
        case .modelSwitch: ChatPromptCacheRule.modelSuppressedKey
        }
    }
}

/// Presents `ChatModel.cacheWarning`. Attach it once per chat surface.
struct ChatCacheWarningAlert: ViewModifier {
    @Bindable var model: ChatModel
    var isActive = true
    @State private var suppressed = false

    func body(content: Content) -> some View {
        let warning = isActive ? model.cacheWarning : nil
        content.alert(warning?.title ?? "", isPresented: Binding(
            get: { warning != nil },
            set: { if !$0 { model.cacheWarning = nil } }
        ), presenting: warning) { warning in
            switch warning.kind {
            case let .idle(_, startNew):
                if let startNew {
                    Button(L10n.text("common.chat.cache.start_new")) { answer(warning, startNew) }
                        .keyboardShortcut(.defaultAction)
                }
                Button(L10n.text("common.chat.cache.send_here")) { answer(warning, warning.proceed) }
            case .modelSwitch:
                Button(L10n.text("common.chat.cache.switch_model")) { answer(warning, warning.proceed) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { model.cacheWarning = nil }
        } message: { warning in
            Text(warning.message)
        }
        #if os(macOS)
        .dialogSuppressionToggle(L10n.text("common.chat.cache.dont_ask_again"), isSuppressed: $suppressed)
        #endif
        .onChange(of: warning?.id) { suppressed = false }
    }

    private func answer(_ warning: ChatCacheWarning, _ action: @MainActor () -> Void) {
        if suppressed { UserDefaults.standard.set(true, forKey: warning.suppressionKey) }
        model.cacheWarning = nil
        action()
    }
}
