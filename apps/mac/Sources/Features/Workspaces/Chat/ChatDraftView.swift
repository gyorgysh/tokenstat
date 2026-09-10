// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI

/// Multiline draft that sends on Return. Shift+Return inserts a newline.
/// Escape stops a running turn.
///
/// SwiftUI's vertical `TextField` swallows Return as a newline and never
/// delivers `.onKeyPress(.return)`. The rest of the well stays SwiftUI.
struct ChatDraftView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var placeholder: String
    var enabled: Bool
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onPasteAttachments: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, onSend: onSend, onStop: onStop)
    }

    func makeNSView(context: Context) -> ChatDraftScrollView {
        let scroll = ChatDraftScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        let textView = ChatDraftTextView()
        textView.delegate = context.coordinator
        textView.draftSend = { context.coordinator.requestSend() }
        textView.draftStop = onStop
        textView.pasteAttachments = onPasteAttachments
        textView.placeholder = placeholder
        textView.isEditable = enabled
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 28)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        // The delegate is already attached, and setting `string` moves the
        // caret, which AppKit reports as a selection change before the
        // assignment returns. Writing the SwiftUI binding from there is a
        // write during view creation. It went unnoticed while this field was
        // always born empty; a restored draft is not. Same guard, same
        // reason as `updateNSView`.
        context.coordinator.applyingUpdate = true
        textView.string = text
        context.coordinator.applyingUpdate = false
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: ChatDraftScrollView, context: Context) {
        guard let textView = scroll.documentView as? ChatDraftTextView else { return }
        context.coordinator.onSend = onSend
        context.coordinator.onStop = onStop
        context.coordinator.selection = $selection
        textView.draftSend = { context.coordinator.requestSend() }
        textView.draftStop = onStop
        textView.pasteAttachments = onPasteAttachments
        textView.placeholder = placeholder
        textView.isEditable = enabled
        // Everything below writes into the text view, and AppKit answers a
        // write by calling the delegate back on the same turn. See
        // `applyingUpdate`.
        context.coordinator.applyingUpdate = true
        defer { context.coordinator.applyingUpdate = false }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            // Only when the height this field reports can have changed.
            //
            // An invalidation is not free and it is not local. AppKit answers
            // it by asking `intrinsicContentSize`, which lays the whole text
            // out; SwiftUI answers the new height by sizing the pane again,
            // and this field's neighbour in that pane is the transcript,
            // whose lazy stack has to measure every row it is holding to say
            // how wide it would like to be. Invalidating on every update
            // meant a streamed reply paid all of that per word, which is what
            // a chat open on a long conversation hung inside.
            //
            // The other two things that change the height already say so:
            // typing, through the delegate, and a change of width, through
            // `ChatDraftScrollView.layout()`.
            textView.invalidateIntrinsicContentSize()
            scroll.invalidateIntrinsicContentSize()
        }
        let safeSelection = NSRange(
            location: min(selection.location, (textView.string as NSString).length),
            length: min(selection.length, max(0, (textView.string as NSString).length - selection.location))
        )
        if textView.selectedRange() != safeSelection {
            textView.setSelectedRange(safeSelection)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var onSend: () -> Void
        var onStop: () -> Void
        weak var textView: ChatDraftTextView?
        private var sendQueued = false
        /// True while `updateNSView` is writing into the text view.
        ///
        /// Setting `string` moves the insertion point, and setting the
        /// selected range is a selection change, so AppKit calls the delegate
        /// back before the assignment returns. The delegate writes SwiftUI
        /// state, and doing that inside a view update is undefined behaviour
        /// that SwiftUI logs as such: the write invalidates the view being
        /// updated, so the update runs again, and the pair can trade the same
        /// range back and forth. The values being applied are the ones
        /// SwiftUI just handed over, so there is nothing to report back.
        var applyingUpdate = false

        init(
            text: Binding<String>,
            selection: Binding<NSRange>,
            onSend: @escaping () -> Void,
            onStop: @escaping () -> Void
        ) {
            self.text = text
            self.selection = selection
            self.onSend = onSend
            self.onStop = onStop
        }

        /// Leave the text view's command handling before SwiftUI updates.
        /// Send from inside Return used to land in the same turn as the
        /// field editor, and the new prompt stayed unmeasured until the
        /// next click on the composer.
        func requestSend() {
            guard !sendQueued else { return }
            sendQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.sendQueued = false
                self?.onSend()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingUpdate,
                  let textView = notification.object as? ChatDraftTextView
            else { return }
            text.wrappedValue = textView.string
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingUpdate,
                  let textView = notification.object as? ChatDraftTextView
            else { return }
            // Observation does not compare before it notifies, and a caret
            // that landed where it already was is most of this traffic.
            let range = textView.selectedRange()
            guard selection.wrappedValue != range else { return }
            selection.wrappedValue = range
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText(),
                  (textView as? ChatDraftTextView)?.handlingComposition != true else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                requestSend()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                onStop()
                return true
            }
            return false
        }
    }
}

final class ChatDraftScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        let inner = documentView?.intrinsicContentSize.height ?? 28
        return NSSize(width: NSView.noIntrinsicMetric, height: inner)
    }

    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, contentSize.height)))
            // A different width rewraps the draft, which is the one other way
            // the height changes. Nothing else asks again, and the guard
            // above means this settles on the next pass rather than driving
            // one of its own.
            textView.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(documentView)
        super.mouseDown(with: event)
    }
}

final class ChatDraftTextView: NSTextView {
    var placeholder: String = ""
    var draftSend: (() -> Void)?
    var draftStop: (() -> Void)?
    var pasteAttachments: (() -> Void)?
    private(set) var handlingComposition = false

    /// File and image drags belong to the composer well, which attaches them.
    /// Left alone, NSTextView swallows a drop on the text itself and inserts
    /// the path, while the same file dropped a few points above or below
    /// attaches. Declining here lets the drop bubble to the well's `onDrop`,
    /// so every point of the composer behaves the same way. Plain text drags
    /// still go through, which is what makes moving words around work.
    private static let attachmentImageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    private static func isAttachmentDrag(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return true
        }
        if attachmentImageTypes.contains(where: { pasteboard.data(forType: $0) != nil }) {
            return true
        }
        return NSImage(pasteboard: pasteboard) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.isAttachmentDrag(sender.draggingPasteboard) { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.isAttachmentDrag(sender.draggingPasteboard) { return [] }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.isAttachmentDrag(sender.draggingPasteboard) { return false }
        return super.performDragOperation(sender)
    }

    override var intrinsicContentSize: NSSize {
        guard let manager = layoutManager, let container = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 28)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let height = min(max(ceil(used.height) + 8, 28), 160)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let rect = bounds.insetBy(dx: inset.width, dy: inset.height)
        (placeholder as NSString).draw(in: rect, withAttributes: attrs)
    }

    override var acceptsFirstResponder: Bool { isEditable }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), !handlingComposition else {
            super.insertNewline(sender)
            return
        }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            super.insertNewline(sender)
            return
        }
        draftSend?()
    }

    override func keyDown(with event: NSEvent) {
        // Return confirms marked text and Escape cancels composition. Let
        // the input method finish before treating either as a chat action.
        guard !hasMarkedText() else {
            handlingComposition = true
            defer { handlingComposition = false }
            super.keyDown(with: event)
            return
        }
        // Return (36) and keypad Enter (76). Command+Return also sends.
        // Escape (53) stops a running turn.
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            draftSend?()
            return
        }
        if event.keyCode == 53 {
            draftStop?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if ChatInbox.pasteboardHasAttachment() {
            pasteAttachments?()
            return
        }
        super.paste(sender)
    }
}
#endif
