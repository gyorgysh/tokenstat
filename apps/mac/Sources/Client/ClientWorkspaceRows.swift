// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

struct ClientAdaptiveCards<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: () -> Content
    var body: some View {
        WidthReader { width in
        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(width > 0 ? width : 320, typeSize.isAccessibilitySize ? 600 : 320)), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            content()
        }
        }
    }
}

struct ClientStatPanels: View {
    var panels: [(label: String, value: String, mark: String)]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            ForEach(panels.indices, id: \.self) { index in
                panel(panels[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func panel(_ item: (label: String, value: String, mark: String)) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.value)
                    .font(ClientType.figureSmall)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(item.label)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            FeatureMark(name: item.mark, size: 22)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private enum ClientRowMark {
    static let size: CGFloat = 26
}

struct ClientFolderRow: View {
    let folder: WorkspaceFolder
    var grouped = false
    @Environment(TeamStore.self) private var teams

    var body: some View {
        let row = HStack(spacing: Theme.Space.s) {
            folderMark
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(folder.name)
                        .font(ClientType.label.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    TeamFolderBadges(names: teams.sharedOrganizations(reported: folder.teamOrganizations, workspace: folder.id, isRemote: folder.isRemote))
                }
                Text(folder.isGeneral ? L10n.text("common.new_chat.no_repository_help") : folder.path)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = folder.subtitle {
                    HStack(spacing: 4) {
                        if folder.git?.isRepo == true,
                           folder.git?.branch?.isEmpty == false {
                            Image(systemName: "arrow.triangle.branch")
                                .font(ClientType.caption.weight(.medium))
                        }
                        Text(subtitle)
                    }
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: grouped ? 58 : 72, alignment: .leading)
        .contentShape(.rect)
        if grouped { row } else { row.cardSurface() }
    }

    private var folderMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClientRowMark.size * 0.28, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
            Image(systemName: folder.isGeneral ? "bubble.left.and.bubble.right.fill" : "folder.fill")
                .font(Theme.font(ClientRowMark.size * 0.5, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: ClientRowMark.size, height: ClientRowMark.size)
    }
}

struct ClientSessionRow: View {
    let session: PtySessionInfo
    var showsChevron: Bool = false
    var displayName: String?
    var grouped = false

    private var harness: String? { harnessID(forCommand: session.command) }

    private var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let harness { return harnessName(harness) }
        return URL(fileURLWithPath: session.command).lastPathComponent
    }

    var body: some View {
        let row = HStack(spacing: Theme.Space.s) {
            leadingMark
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.alive ? L10n.text("apple.clientworkspacerows.running_0.e8f8155e", "\(session.cwd)") : L10n.text("apple.clientworkspacerows.stopped_tap_to_open.669cde36"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: grouped ? 58 : 72, alignment: .leading)
        .contentShape(.rect)
        if grouped { row } else { row.cardSurface() }
    }

    @ViewBuilder
    private var leadingMark: some View {
        if let harness {
            HarnessMark(id: harness, size: ClientRowMark.size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: ClientRowMark.size * 0.28, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                Image(systemName: "terminal")
                    .font(Theme.font(ClientRowMark.size * 0.46, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: ClientRowMark.size, height: ClientRowMark.size)
        }
    }
}
#endif
