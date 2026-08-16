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
/// Four kinds of drop arrive, in the order this tries them:
///
/// - **Durable files.** Finder, an editor's file list, anything with a real
///   `fileURL` that will still be there tomorrow. The path is typed, shell
///   quoted, with a trailing space.
/// - **Screenshot pixels.** The floating thumbnail on the right of the
///   screen carries TIFF even when its file URL is a promise or a string.
///   Those pixels are written to a drop folder first, because the thumbnail
///   disappears and a `file://` link is not a path the agent can open.
/// - **Promises.** Photos, Mail attachments and some browsers. Fetched into
///   a temporary folder, then typed.
/// - **Ephemeral files.** A `fileURL` that already exists but will vanish
///   (screencapture's holding folder). Copied first, then the copy is typed.
///
/// A screenshot thumbnail often also puts a `file://` string on the
/// pasteboard, pointing at a file that is not there yet or will be deleted
/// when the thumbnail slides away. That string is not pasted as a link:
/// image data and promises are tried first, and a file URL in the string
/// is resolved the same way as a dropped file.
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

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
    ]

    private func registerTypes() {
        registerForDraggedTypes(
            [.fileURL, .URL, .string] + Self.imageTypes + Self.promiseTypes
        )
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
        let urls = fileURLs(on: pasteboard)
        let durable = urls.filter { exists($0) && !isEphemeral($0) }

        // A project file from Finder is typed where it lives. A screenshot
        // thumbnail is not that: its URL is often missing, promised, or
        // about to be deleted, and taking it first pasted a `file://` link
        // the agent could not open.
        if !durable.isEmpty {
            type(paths: durable.map(\.path))
            return true
        }
        // The floating thumbnail always carries pixels. Prefer those over
        // its file promise, which can fail after the thumbnail has already
        // slid away.
        if looksLikeScreenshot(pasteboard, urls: urls), let path = writeImage(from: pasteboard) {
            type(paths: [path])
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
        let lingering = urls.filter { exists($0) }
        if !lingering.isEmpty {
            type(paths: lingering.compactMap(persistCopy))
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            if let path = persistIfFileReference(text) {
                type(paths: [path])
                return true
            }
            // A dead file:// from the screenshot thumbnail is not a path
            // anyone can open. Swallow it rather than typing the link.
            if isFileReferenceString(text) { return false }
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
        if !fileURLs(on: pasteboard).isEmpty { return .copy }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return .copy
        }
        if pasteboard.availableType(from: Self.imageTypes + [.string, .URL]) != nil {
            return .copy
        }
        return []
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        for raw in objects {
            guard let url = usableFileURL(raw), seen.insert(url.path).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// File-reference URLs (`file:///.file/id=…`) have a path nobody can
    /// open. Turn them into a real path URL first.
    private func usableFileURL(_ url: URL) -> URL? {
        let pathURL = (url as NSURL).filePathURL ?? url
        guard pathURL.isFileURL else { return nil }
        return pathURL.resolvingSymlinksInPath()
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The floating screenshot thumbnail, and the holding folder Screenshot
    /// uses before the user picks a destination, go away on their own. Typing
    /// that path leaves the agent with a link to a file that is already gone.
    private func isEphemeral(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("com.apple.screencapture") { return true }
        if path.contains("/TemporaryItems/") { return true }
        let name = url.lastPathComponent.lowercased()
        if path.contains("/var/folders/"), name.contains("screenshot") || name.hasPrefix("screencapture") {
            return true
        }
        return false
    }

    private func looksLikeScreenshot(_ pasteboard: NSPasteboard, urls: [URL]) -> Bool {
        if urls.contains(where: {
            isEphemeral($0) || $0.lastPathComponent.localizedCaseInsensitiveContains("Screenshot")
        }) {
            return true
        }
        return (pasteboard.types ?? []).contains { $0.rawValue.contains("screencapture") }
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
    /// one an agent CLI is likely to read. `NSImage(pasteboard:)` is last:
    /// the screenshot thumbnail always puts a TIFF there even when the file
    /// URL is a promise or a string.
    private func writeImage(from pasteboard: NSPasteboard) -> String? {
        var data: Data?
        if let png = pasteboard.data(forType: .png) {
            data = png
        } else if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            data = jpeg
        } else if let tiff = pasteboard.data(forType: .tiff) {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else if let image = NSImage(pasteboard: pasteboard),
                  let tiff = image.tiffRepresentation {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let data, let destination = Self.makeDropDirectory() else { return nil }
        let name = data.starts(with: [0xFF, 0xD8, 0xFF]) ? "screenshot.jpg" : "screenshot.png"
        let url = destination.appendingPathComponent(name)
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url.path
    }

    /// Copy an ephemeral file into our drop folder before the source
    /// disappears. The original path is never typed.
    private func persistCopy(_ url: URL) -> String? {
        guard let destination = Self.makeDropDirectory() else { return nil }
        var name = url.lastPathComponent
        if name.isEmpty || name == "/" { name = "screenshot.png" }
        let target = destination.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            return nil
        }
        return target.path
    }

    /// A `file://` string or an absolute path, which is what the screenshot
    /// thumbnail leaves when it does not hand over a real file URL. Resolve
    /// and persist it. Anything else is ordinary pasted text.
    private func persistIfFileReference(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = URL(string: trimmed) {
            if parsed.isFileURL, let url = usableFileURL(parsed), exists(url) {
                return persistCopy(url) ?? url.path
            }
            // A bare file:// that did not parse as a file URL (spaces,
            // percent-encoding). Try again after decoding.
            if trimmed.hasPrefix("file:") {
                let decoded = trimmed.removingPercentEncoding ?? trimmed
                let path = decoded.replacingOccurrences(of: "file://", with: "")
                let url = URL(fileURLWithPath: path)
                if exists(url) { return persistCopy(url) ?? url.path }
            }
            return nil
        }
        if trimmed.hasPrefix("/"), exists(URL(fileURLWithPath: trimmed)) {
            let url = URL(fileURLWithPath: trimmed)
            return persistCopy(url) ?? url.path
        }
        return nil
    }

    private func isFileReferenceString(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("file:") || trimmed.hasPrefix("/.file/")
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
