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
        context.coordinator.onDone = onDone
        // Reloading on every SwiftUI update flashes the preview. Only the
        // file changing needs one.
        if context.coordinator.file.id != file.id {
            context.coordinator.file = file
            (controller.viewControllers.first as? QLPreviewController)?.reloadData()
        }
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

        /// No Markup, no rotation, no crop.
        ///
        /// The staged copy is a scratch file the cache prunes on a budget, so
        /// an edit made here would be thrown away without warning. Sharing is
        /// unaffected: the action button is the system share sheet, which is
        /// where Save to Files and AirDrop live.
        func previewController(
            _ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }

        @objc func finish() { onDone() }
    }
}

#endif
