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
    var placeholder: String
    var enabled: Bool
    var onSend: () -> Void
    var onStop: () -> Void = {}
    var onPasteAttachments: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSend: onSend, onStop: onStop)
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
        textView.draftSend = onSend
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
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: ChatDraftScrollView, context: Context) {
        guard let textView = scroll.documentView as? ChatDraftTextView else { return }
        context.coordinator.onSend = onSend
        context.coordinator.onStop = onStop
        textView.draftSend = onSend
        textView.draftStop = onStop
        textView.pasteAttachments = onPasteAttachments
        textView.placeholder = placeholder
        textView.isEditable = enabled
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        textView.invalidateIntrinsicContentSize()
        scroll.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onSend: () -> Void
        var onStop: () -> Void
        weak var textView: ChatDraftTextView?

        init(text: Binding<String>, onSend: @escaping () -> Void, onStop: @escaping () -> Void) {
            self.text = text
            self.onSend = onSend
            self.onStop = onStop
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChatDraftTextView else { return }
            text.wrappedValue = textView.string
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                onSend()
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
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            super.insertNewline(sender)
            return
        }
        draftSend?()
    }

    override func keyDown(with event: NSEvent) {
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
