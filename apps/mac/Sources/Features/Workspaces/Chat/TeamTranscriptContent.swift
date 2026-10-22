// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import ImageIO
import SwiftUI

/// Reuses the chat renderer while leaving personal models, file transfers and
/// approval callbacks out of this read-only Team history surface.
struct TeamTranscriptContent: View {
    let history: TeamChatHistory
    @State private var rows: [ChatDisplayItem] = []
    @State private var people: [String: TeamPerson] = [:]
    @State private var asks: Set<String> = []
    @State private var former: Set<String> = []
    @State private var readyRenderId: UUID?
    @State private var error: String?
    @Environment(\.teamAvatarOwner) private var owner
    @Environment(\.teamAttachmentLoader) private var loadAttachment
    @State private var files: [String: TeamAttachmentFile] = [:]
    @State private var fetching: String?
    @State private var fileError: String?
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error { TeamNotice(message: error, warning: true) }
            ForEach(rows) { row in
                if case .user = row.kind {
                    if let person = people[row.id] {
                        HStack(spacing: Theme.Space.s) {
                            Avatar(url: teamAvatarURL(person.avatar, owner: owner)?.absoluteString, name: person.name, handle: person.handle, size: 24, tint: Avatar.tint(for: person.id)).accessibilityHidden(true)
                            Text(person.name).font(Theme.caption.weight(.semibold)).lineLimit(2)
                            Text(asks.contains(row.id) ? L10n.text("common.teams.ask") : L10n.text("common.teams.comment")).font(Theme.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .trailing).accessibilityElement(children: .combine)
                    } else if former.contains(row.id) {
                        Label(L10n.text("common.teams.former_member"), systemImage: "person.crop.circle.badge.minus")
                            .font(Theme.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Label(L10n.text("common.teams.local_before_teams"), systemImage: "person.crop.circle")
                            .font(Theme.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if case let .attachment(file) = row.kind {
                    if let fetched = files[file.id] {
                        // Never opened from here: a file from another computer
                        // is looked at inline when it is an image, and saved
                        // otherwise, so nothing it names can launch.
                        if let image = TeamFilePreview.image(fetched) {
                            image.resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 360, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel(TeamFilePreview.safeName(fetched.name))
                        } else {
                            HStack(spacing: Theme.Space.s) {
                                Label(TeamFilePreview.safeName(fetched.name), systemImage: "doc").font(Theme.callout).lineLimit(1).truncationMode(.middle)
                                #if os(macOS)
                                Button(L10n.text("common.teams.save_file"), .download) { TeamFilePreview.save(fetched) }
                                    .buttonStyle(TeamButtonStyle())
                                #endif
                            }
                        }
                    } else {
                        // Fetched on request: a file comes from the publishing
                        // computer, and only when someone wants to see it.
                        Button {
                            Task { await fetch(file.id) }
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "paperclip").accessibilityHidden(true)
                                Text(file.name).lineLimit(1)
                                if fetching == file.id { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                            }.font(Theme.callout)
                        }
                        .buttonStyle(.plain).foregroundStyle(loadAttachment == nil ? Color.secondary : TeamColors.action)
                        .disabled(loadAttachment == nil || fetching != nil)
                        .accessibilityHint(L10n.text("common.teams.open_file"))
                        if let fileError, fetching == nil { Text(fileError).font(Theme.caption).foregroundStyle(TeamColors.warning) }
                    }
                } else {
                    ChatEventRow(item: row, defaultAgentName: label(history.backend), agentLabel: label, attachmentData: nil,
                                 isPending: false, resolve: { _, _ in }, canAnswerQuestions: false)
                }
            }
        }
        .preference(key: TeamTranscriptRenderedKey.self, value: readyRenderId)
        // A link in someone else's checkout must not become an action on a
        // personal checkout, simulator or workbench on this device.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .task(id: history.renderId) {
            let events = history.events, backend = history.backend
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let decoded = try JSONDecoder().decode([ChatTimelineEvent].self, from: JSONEncoder().encode(events))
                    try Task.checkCancellation()
                    return (ChatDisplayItem.coalesce(decoded, defaultBackend: backend, running: false), try TeamMessageAttribution.people(events), TeamMessageAttribution.asks(events), TeamMessageAttribution.former(events))
                }.value
                try Task.checkCancellation()
                rows = result.0; people = result.1; asks = result.2; former = result.3; readyRenderId = history.renderId; error = nil
            } catch is CancellationError {} catch {
                rows = []; people = [:]; asks = []; former = []; readyRenderId = history.renderId; self.error = L10n.text("common.teams.history_cannot_display")
            }
        }
    }
    private func fetch(_ id: String) async {
        guard let loadAttachment, fetching == nil else { return }
        fetching = id; fileError = nil
        defer { fetching = nil }
        do { files[id] = try await loadAttachment(id) } catch is CancellationError {} catch { fileError = error.localizedDescription }
    }
    private func label(_ backend: String) -> String {
        switch backend {
        case "codex": "Codex"
        case "claude": "Claude Code"
        case "muse": "Muse"
        default: backend
        }
    }
    @MainActor static func render(_ history: TeamChatHistory) -> AnyView { AnyView(TeamTranscriptContent(history: history)) }
}

enum TeamFilePreview {
    static func image(_ file: TeamAttachmentFile) -> Image? {
        guard file.mediaType?.hasPrefix("image/") == true, file.mediaType != "image/svg+xml",
              let source = CGImageSourceCreateWithData(file.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= 100_000_000, max(width, height) / min(width, height) <= 50 else { return nil }
        // A small file can still describe a huge bitmap. Decode a bounded
        // thumbnail, never the full image.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Image(decorative: image, scale: 1)
    }
    /// Plain data a saved file may keep as its extension. Anything else,
    /// including every type that can launch or be followed from Finder,
    /// gets .download added, so an unknown kind is never trusted.
    private static let plainData: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp",
        "txt", "md", "markdown", "csv", "tsv", "json", "log", "pdf", "yaml", "yml", "toml", "diff", "patch",
    ]

    /// The name as sent by another computer, made safe to show and to save:
    /// no control or direction characters, no path, no leading dot, bounded,
    /// and ending in a plain data extension or in .download.
    static func safeName(_ raw: String) -> String {
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
              || scalar == "/" || scalar == "\\" || scalar == ":")
        })).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            name = String(name.prefix(100)) + (ext.isEmpty || ext.count > 10 ? "" : "." + ext)
        }
        if name.isEmpty { name = "file" }
        if !plainData.contains((name as NSString).pathExtension.lowercased()) { name += ".download" }
        return name
    }

    #if os(macOS)
    /// Saved where the person chooses, marked as downloaded so macOS checks
    /// it before anything in it can run. The mark goes on a hidden copy
    /// first, and only a marked copy is moved into place.
    @MainActor static func save(_ file: TeamAttachmentFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(file.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let staged = url.deletingLastPathComponent().appendingPathComponent(".tokenstat-" + UUID().uuidString)
        do {
            try file.data.write(to: staged, options: .withoutOverwriting)
            let mark = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));tokenstat;"
            let marked = mark.withCString { value in setxattr(staged.path, "com.apple.quarantine", value, strlen(value), 0, 0) }
            guard marked == 0 else { throw CocoaError(.fileWriteUnknown) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staged, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: staged, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            NSSound.beep()
        }
    }
    #endif
}
