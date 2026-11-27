// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The chosen transcript detail level, shared by every chat on this device.
///
/// One observable object rather than `@AppStorage` in each view, because the
/// level is read by `ChatModel` while it folds rows, and a model cannot hold
/// a property wrapper that only works inside a view.
@MainActor @Observable
final class ChatDetailPreference {
    static let shared = ChatDetailPreference()
    static let key = "chat.detailLevel"
    static let previousKey = "chat.detail"

    var level: ChatDetail {
        didSet { UserDefaults.standard.set(level.rawValue, forKey: Self.key) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.key).flatMap(ChatDetail.init(rawValue:)) {
            level = stored
        } else if let previous = defaults.string(forKey: Self.previousKey).flatMap(Self.renamed) {
            level = previous
            defaults.set(previous.rawValue, forKey: Self.key)
        } else {
            level = Self.defaultLevel
        }
    }

    static func renamed(_ raw: String) -> ChatDetail? {
        switch raw {
        case "minimal": .compact
        case "compact": .minimal
        default: ChatDetail(rawValue: raw)
        }
    }

    static let defaultLevel: ChatDetail = .compact

    static func label(_ level: ChatDetail) -> String {
        switch level {
        case .minimal: L10n.text("apple.chatdetail.minimal")
        case .compact: L10n.text("apple.chatdetail.compact")
        case .standard: L10n.text("apple.chatdetail.standard")
        case .detailed: L10n.text("apple.chatdetail.detailed")
        }
    }

    static func explanation(_ level: ChatDetail) -> String {
        switch level {
        case .minimal: L10n.text("apple.chatdetail.minimal_explanation")
        case .compact: L10n.text("apple.chatdetail.compact_explanation")
        case .standard: L10n.text("apple.chatdetail.standard_explanation")
        case .detailed: L10n.text("apple.chatdetail.detailed_explanation")
        }
    }
}

struct ChatDetailSettings: View {
    var model: ChatModel?
    @State private var preference = ChatDetailPreference.shared
    @AppStorage("chat.smoothStreaming") private var smoothStreaming = true

    var body: some View {
        if model != nil {
            ChatSetupSection(title: L10n.text("apple.chatdetail.title"), icon: .comment,
                             subtitle: L10n.text("apple.chatdetail.subtitle"),
                             primary: levelPicker) { details }
        } else {
        #if os(macOS)
        Card(
            title: L10n.text("apple.chatdetail.title"),
            subtitle: L10n.text("apple.chatdetail.subtitle"),
            mark: "mark_chat"
        ) {
            rows
        }
        #else
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ClientSectionTitle(title: L10n.text("apple.chatdetail.title"), mark: "mark_chat")
            Text(L10n.text("apple.chatdetail.subtitle"))
                .font(ClientType.body)
                .foregroundStyle(.secondary)
            rows
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        #endif
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            levelPicker
            details
        }
    }

    private var levelPicker: some View {
        Group {
                #if os(macOS)
                SegmentedCapsulePicker(
                    options: ChatDetail.allCases.map {
                        (value: $0, label: ChatDetailPreference.label($0), symbol: "")
                    },
                    selection: $preference.level
                )
                #else
                SegmentedTabs(
                    options: ChatDetail.allCases,
                    selection: $preference.level,
                    title: ChatDetailPreference.label,
                    comfortable: true
                )
                #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("apple.chatdetail.title"))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(ChatDetailPreference.explanation(preference.level))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.caption)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("common.chat.smooth_streaming"), isOn: $smoothStreaming)
            Text(L10n.text("common.chat.smooth_streaming_help"))
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            if let model, preference.level != .detailed {
                Button(
                    model.anyGroupOpen ? L10n.text("apple.chatdetail.collapse_steps") : L10n.text("apple.chatdetail.expand_steps"),
                    model.anyGroupOpen ? .collapse : .preview
                ) {
                    model.setAllGroups(open: !model.anyGroupOpen)
                }
                .buttonStyle(AccentButtonStyle(small: true))
            }
        }
    }
}

struct ChatDetailMenuPicker: View {
    @State private var preference = ChatDetailPreference.shared
    @AppStorage("chat.smoothStreaming") private var smoothStreaming = true

    var body: some View {
        Picker(L10n.text("apple.chatdetail.title"), selection: $preference.level) {
            ForEach(ChatDetail.allCases, id: \.self) { level in
                Text(ChatDetailPreference.label(level)).tag(level)
            }
        }
    }
}
