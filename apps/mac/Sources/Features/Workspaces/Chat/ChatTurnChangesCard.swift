// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

/// The files a finished turn changed, under its last reply.
///
/// Shared by the Mac and the phone. The first few files are listed with
/// what each one gained and lost, the rest are one tap away, and Review opens
/// the folder's full changes review, in a document tab on desktop.
struct ChatTurnChangesCard: View {
    let changes: ChatTurnChanges
    /// Opens the folder's changes, at one file when a row was pressed. Nil
    /// for a saved copy, which has no folder to open.
    var review: ((String?) -> Void)?
    @State private var showingAll = false

    static let shownFiles = 4

    #if os(macOS)
    private static let titleFont = Theme.font(13, weight: .medium)
    private static let rowFont = Theme.font(13)
    private static let numberFont = Theme.numeric(12)
    #else
    private static let titleFont = ClientType.label.weight(.medium)
    private static let rowFont = ClientType.label
    private static let numberFont = ClientType.caption
    #endif

    private var shown: [ChatTurnChanges.File] {
        showingAll ? changes.files : Array(changes.files.prefix(Self.shownFiles))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                Text(changes.files.count == 1
                     ? L10n.text("apple.chatchanges.files_changed.one", "1")
                     : L10n.text("apple.chatchanges.files_changed.other", "\(changes.files.count)"))
                    .font(Self.titleFont)
                DiffStat(added: Int(changes.added), removed: Int(changes.removed), font: Self.numberFont)
                    .fixedSize()
                Spacer(minLength: Theme.Space.s)
                if let review {
                    Button(L10n.text("apple.chatchanges.review"), .preview) { review(nil) }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .fixedSize()
                        .help(L10n.text("apple.chatchanges.review_help"))
                }
            }
            .padding(.bottom, Theme.Space.xs)
            ForEach(shown) { file in
                row(file)
            }
            if changes.files.count > Self.shownFiles {
                Button(showingAll
                       ? L10n.text("apple.chatchanges.show_less")
                       : L10n.text("apple.chatchanges.show_more", "\(changes.files.count - Self.shownFiles)"),
                       showingAll ? .collapse : .more) {
                    showingAll.toggle()
                }
                .buttonStyle(.plain)
                .font(Self.rowFont)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.border)
        )
    }

    private func row(_ file: ChatTurnChanges.File) -> some View {
        Button { review?(file.path) } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: Self.symbol(for: file.path))
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(file.fileName)
                    .font(Self.rowFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                DiffStat(added: Int(file.added), removed: Int(file.removed), font: Self.numberFont)
                    .fixedSize()
            }
            .padding(.vertical, 3)
            #if !os(macOS)
            .frame(minHeight: 36)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(review == nil)
        .help(file.path)
        .accessibilityLabel(L10n.text("apple.chatchanges.file_row", file.fileName, "\(file.added)", "\(file.removed)"))
    }

    /// A glyph for the kind of file, so a long list can be scanned by shape.
    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "md", "txt", "rst": "doc.plaintext"
        case "json", "toml", "yml", "yaml", "plist", "xml", "lock": "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns": "photo"
        case "sh", "zsh", "bash", "ps1": "terminal"
        case "css", "scss", "html": "paintbrush"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}
