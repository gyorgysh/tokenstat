// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// Shared leading tile size for folder and session cards.
private enum ClientRowMark {
    static let size: CGFloat = 26
}

/// A workspace folder on the phone: folder mark, name, path.
///
/// The folder is the container. Sessions underneath it carry the harness
/// mark, same split the Mac sidebar uses.
struct ClientFolderRow: View {
    let folder: WorkspaceFolder

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            folderMark
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(folder.path)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = folder.subtitle {
                    Text(subtitle)
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .cardSurface()
    }

    private var folderMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClientRowMark.size * 0.28, style: .continuous)
                .fill(Theme.accent.opacity(0.12))
            Image(systemName: "folder.fill")
                .font(.system(size: ClientRowMark.size * 0.5, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: ClientRowMark.size, height: ClientRowMark.size)
    }
}

/// A running or stopped session: harness mark, name, state.
struct ClientSessionRow: View {
    let session: PtySessionInfo
    var showsChevron: Bool = false

    private var harness: String? { harnessID(forCommand: session.command) }

    private var title: String {
        if let harness { return harnessName(harness) }
        return URL(fileURLWithPath: session.command).lastPathComponent
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            leadingMark
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.alive ? "Running · \(session.cwd)" : "Stopped · tap to open")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .cardSurface()
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
                    .font(.system(size: ClientRowMark.size * 0.46, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: ClientRowMark.size, height: ClientRowMark.size)
        }
    }
}
#endif
