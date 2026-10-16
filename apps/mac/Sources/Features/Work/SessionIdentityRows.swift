// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// Every identifier is copied only by its own explicit button. Long native
/// session IDs retain their complete value while the row truncates visually.
struct SessionIdentityRows: View {
    let entries: [SessionIdentityEntry]
    var truncated = false
    var reportedTotal: UInt64? = nil
    @State private var historyOpen = false
    @State private var copiedID: String?
    private var visible: [SessionIdentityEntry] { entries.filter { !$0.isHistorical } }
    private var previous: [SessionIdentityEntry] { entries.filter(\.isHistorical) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(visible) { entry in row(entry) }
            if !entries.contains(where: \.isNative) {
                Text(L10n.text("common.session_identity.not_reported")).font(Theme.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !previous.isEmpty {
                ChatDisclosureRow(title: L10n.text("common.history") + " · " + previous.count.formatted(), expanded: $historyOpen)
                if historyOpen {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            ForEach(previous) { entry in row(entry) }
                        }
                    }
                    .frame(maxHeight: min(240, CGFloat(previous.count) * 58))
                    Text(L10n.text("common.session_identity.history_help")).font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if truncated, let reportedTotal {
                Text(L10n.text("common.session_identity.truncated", entries.filter(\.isNative).count.formatted(), reportedTotal.formatted()))
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: entries.first?.id) { _, _ in historyOpen = false; copiedID = nil }
    }

    private func row(_ entry: SessionIdentityEntry) -> some View {
        Button {
            ChatClipboard.copy(entry.value)
            copiedID = entry.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.8))
                if copiedID == entry.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(entry)).font(Theme.caption).foregroundStyle(.secondary)
                    Text(entry.value).font(Theme.mono(11)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                (copiedID == entry.id ? ActionIcon.done : .copy)
                    .label(L10n.text("common.session_identity.copy", title(entry)))
                    .labelStyle(.iconOnly).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("common.session_identity.copy", title(entry)) + ": " + entry.value)
        .accessibilityLabel(L10n.text("common.session_identity.copy", title(entry)))
        .accessibilityValue(copiedID == entry.id ? L10n.text("common.session_identity.copied") : entry.value)
    }
    private func title(_ entry: SessionIdentityEntry) -> String {
        switch entry.kind {
        case .conversation: return L10n.text("common.session_identity.conversation")
        case .terminal: return L10n.text("common.session_identity.terminal")
        case .current: return L10n.text("common.session_identity.current", harnessName(entry.backend ?? ""))
        case .saved: return L10n.text("common.session_identity.saved", harnessName(entry.backend ?? ""))
        case .historical: return L10n.text("common.session_identity.previous", harnessName(entry.backend ?? ""))
        case .sourceConversation: return L10n.text("common.session_identity.previous", L10n.text("common.session_identity.conversation"))
        }
    }
}

struct ChatSessionIdentityDetails: View {
    @Bindable var model: ChatModel
    let conversation: ChatConversation
    private var sessions: SessionIdentities? {
        guard model.selected?.id == conversation.id else { return nil }
        return model.currentActivityRead?.inspection?.sessions
    }
    var body: some View {
        SessionIdentityRows(entries: SessionIdentityPresentation.entries(localID: conversation.id, kind: .conversation, sessions: sessions),
                            truncated: sessions?.truncated ?? false, reportedTotal: sessions?.total)
    }
}
