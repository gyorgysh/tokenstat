// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import QuickLook
import SwiftUI
import UIKit

/// A file from a conversation, staged on disk and ready to open.
///
/// Identifiable so one `fullScreenCover(item:)` on the chat view can stand in
/// for a presentation per row. A presentation that lives on a row inside a
/// lazy stack is a presentation the stack can take away while it is being
/// asked for, which is how tapping an attachment came to do nothing at all.
struct ChatPreviewedFile: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
}

/// Writing a downloaded attachment somewhere the system can open it.
///
/// The bytes live in memory and in a hashed cache file with no extension, and
/// neither is something Quick Look, the share sheet or Save to Files can be
/// pointed at. This is the copy with the real name on it.
enum ChatFileStaging {
    /// Where staged copies go. The attachment cache prunes this directory on
    /// the same budget as the downloads, so a copy can be gone by the next
    /// time a row is tapped. Staging is therefore cheap and repeatable rather
    /// than done once.
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-chat-files", isDirectory: true)
    }

    /// The staged copy, made if it is not already there.
    ///
    /// Throws rather than returning nil. A silent failure here is a card that
    /// does nothing when tapped and says nothing about why, which is exactly
    /// what it did.
    static func stage(_ data: Data, id: String, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(sanitized(id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(sanitized(name))
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let existing = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existing == data.count {
            return url
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// One path component, whatever the host called the file.
    static func sanitized(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        let cleaned = leaf
            .filter { !$0.isNewline && !$0.unicodeScalars.contains(where: \.properties.isDefaultIgnorableCodePoint) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
        let flat = cleaned
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return flat.isEmpty ? "attachment" : flat
    }
}

/// The system's own file viewer, with the system's own share sheet in it.
///
/// Quick Look is what reads every kind of file an agent might hand back: it
/// plays video and audio, renders text, source, PDF and images, and its action
/// button is the share sheet, which is where Save to Files, AirDrop and
/// Messages live. Writing a viewer per file type would be worse at all of
/// them.
///
/// It is wrapped in a navigation controller on purpose. Presented bare inside
/// a cover it is a child view controller with no bar of its own, so there is
/// no way out of it and no action button.
struct ClientFilePreview: UIViewControllerRepresentable {
    let file: ChatPreviewedFile
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(file: file, onDone: onDone) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.finish)
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.file = file
        context.coordinator.onDone = onDone
        (controller.viewControllers.first as? QLPreviewController)?.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var file: ChatPreviewedFile
        var onDone: () -> Void

        init(file: ChatPreviewedFile, onDone: @escaping () -> Void) {
            self.file = file
            self.onDone = onDone
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> QLPreviewItem {
            file.url as NSURL
        }

        /// Let the share sheet offer everything, including Save to Files.
        func previewController(
            _ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }

        @objc func finish() { onDone() }
    }
}

#endif
