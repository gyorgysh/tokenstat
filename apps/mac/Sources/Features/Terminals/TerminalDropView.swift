// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

/// A `TerminalView` that accepts a drop, the way every other terminal does.
///
/// Dropping a file into a terminal types its path. That is how anyone hands a
/// screenshot to an agent CLI, and SwiftTerm registers no dragged types at all,
/// so a drop over a pane here did nothing and the feature people expected from
/// the harness they were running was missing.
///
/// Three kinds of drop arrive, in the order this tries them:
///
/// - **Files.** Finder, an editor's file list, anything with a `fileURL`. The
///   path is typed, shell quoted, with a trailing space.
/// - **Promises.** Photos, Mail attachments and some browsers hand over a
///   promise rather than a file. It is fetched into a temporary folder first,
///   then typed, which is why that path arrives a moment later.
/// - **Raw image data.** A drag straight out of a web page carries pixels and
///   no file at all. Those are written next to the promises and typed the same
///   way, because a path is the only thing a process on the other side of a
///   pty can open.
///
/// Anything else that carries plain text is inserted as text, which is what a
/// terminal does with a dragged selection.
final class TerminalDropView: TerminalView {
    /// The session that owns this view. Weak because the ownership runs the
    /// other way: the session holds the emulator for its whole life.
    weak var session: TerminalSession?

    /// Border shown while a drag is over the pane. A drop target that gives no
    /// feedback reads as a broken one.
    private var highlight: NSView?

    /// One queue for promise fetches, created once rather than per drop.
    private let promiseQueue = OperationQueue()

    private static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        .map { NSPasteboard.PasteboardType($0) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerTypes()
    }

    private func registerTypes() {
        registerForDraggedTypes([.fileURL, .png, .tiff, .string] + Self.promiseTypes)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = self.operation(for: sender)
        if operation.isEmpty { removeHighlight() } else { showHighlight() }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        removeHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        removeHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        removeHighlight()
        let pasteboard = sender.draggingPasteboard

        if let urls = fileURLs(on: pasteboard), !urls.isEmpty {
            type(paths: urls.map(\.path))
            return true
        }
        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receive(receivers)
            return true
        }
        if let path = writeImage(from: pasteboard) {
            type(paths: [path])
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            session?.paste(text: text)
            takeFocus()
            return true
        }
        return false
    }

    /// Only a copy, never a move: a drop reads the file and types its path, and
    /// nothing here has any business taking somebody's file away from where it
    /// was. Read only is the rule for other tools' data and it holds here too.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard session != nil else { return [] }
        let pasteboard = sender.draggingPasteboard
        if fileURLs(on: pasteboard) != nil { return .copy }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return .copy
        }
        if pasteboard.availableType(from: [.png, .tiff, .string]) != nil { return .copy }
        return []
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    // MARK: - Typing the result

    /// Type paths at the cursor, quoted for a shell, separated and followed by
    /// a space so the next word does not run into the last path.
    private func type(paths: [String]) {
        guard let session, !paths.isEmpty else { return }
        session.paste(text: paths.map(Self.shellQuoted).joined(separator: " ") + " ")
        takeFocus()
    }

    /// A drop is a deliberate act on this pane, so it should also be the pane
    /// the keyboard is talking to afterwards.
    private func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    /// Characters that need no quoting in any shell anyone runs. Everything
    /// else, spaces most of all, goes inside single quotes with embedded
    /// quotes broken out, which is the one form no shell reinterprets.
    private static let unquotedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+=/,:@%")

    static func shellQuoted(_ path: String) -> String {
        if !path.isEmpty, path.allSatisfy(unquotedCharacters.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Drops that are not files yet

    private func receive(_ receivers: [NSFilePromiseReceiver]) {
        guard let destination = Self.makeDropDirectory() else { return }
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: promiseQueue
            ) { [weak self] url, error in
                guard error == nil else { return }
                DispatchQueue.main.async { self?.type(paths: [url.path]) }
            }
        }
    }

    /// Pixels with no file behind them, written out so the process can open
    /// them. TIFF is converted, because that is a pasteboard format rather than
    /// one an agent CLI is likely to read.
    private func writeImage(from pasteboard: NSPasteboard) -> String? {
        var data: Data?
        if let png = pasteboard.data(forType: .png) {
            data = png
        } else if let tiff = pasteboard.data(forType: .tiff) {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let data, let destination = Self.makeDropDirectory() else { return nil }
        let url = destination.appendingPathComponent("dropped-image.png")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url.path
    }

    /// A fresh folder per drop under the system temporary directory, so two
    /// drops of the same file name cannot overwrite one another. Cleaning up is
    /// left to the system, which is what that directory is for: the alternative
    /// is deleting a file while the process the user dropped it into is still
    /// reading it.
    private static func makeDropDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return url
    }

    // MARK: - Highlight

    private func showHighlight() {
        guard highlight == nil else { return }
        let border = NSView(frame: bounds)
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor(Theme.accent).cgColor
        border.layer?.cornerRadius = 4
        addSubview(border)
        highlight = border
    }

    private func removeHighlight() {
        highlight?.removeFromSuperview()
        highlight = nil
    }
}
#endif
