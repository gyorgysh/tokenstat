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
    static let key = "chat.detail"

    var level: ChatDetail {
        didSet { UserDefaults.standard.set(level.rawValue, forKey: Self.key) }
    }

    private init() {
        level = UserDefaults.standard.string(forKey: Self.key).flatMap(ChatDetail.init(rawValue:)) ?? Self.defaultLevel
    }

    /// Every device starts at Minimal: each step one quiet line, the way
    /// most editors show an agent's work. A choice somebody made is kept.
    static let defaultLevel: ChatDetail = .minimal

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

/// The detail level, in both Apple settings surfaces. The same choice is one
/// menu away inside every conversation.
struct ChatDetailSettings: View {
    /// The conversation on screen, when this card sits beside one. It adds
    /// the open-all and fold-all action, which means nothing in Settings.
    var model: ChatModel?
    @State private var preference = ChatDetailPreference.shared

    var body: some View {
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

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker(L10n.text("apple.chatdetail.title"), selection: $preference.level) {
                ForEach(ChatDetail.allCases, id: \.self) { level in
                    Text(ChatDetailPreference.label(level)).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(ChatDetailPreference.explanation(preference.level))
                #if os(macOS)
                .font(Theme.caption)
                #else
                .font(ClientType.caption)
                #endif
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let model, preference.level != .detailed {
                Button(
                    model.anyGroupOpen ? L10n.text("apple.chatdetail.collapse_steps") : L10n.text("apple.chatdetail.expand_steps"),
                    model.anyGroupOpen ? .collapse : .preview
                ) {
                    model.setAllGroups(open: !model.anyGroupOpen)
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
        }
    }
}

/// The detail level as a menu of three, for the View menu and the phone's
/// chat menu. The same preference as the settings card.
struct ChatDetailMenuPicker: View {
    @State private var preference = ChatDetailPreference.shared

    var body: some View {
        Picker(L10n.text("apple.chatdetail.title"), selection: $preference.level) {
            ForEach(ChatDetail.allCases, id: \.self) { level in
                Text(ChatDetailPreference.label(level)).tag(level)
            }
        }
    }
}
