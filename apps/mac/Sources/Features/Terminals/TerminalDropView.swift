// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftTerm

final class TerminalDropView: TerminalSelectionView {
    weak var session: TerminalSession?

    private var highlight: NSView?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !counted {
            counted = true
            TerminalWheelForwarder.terminalAppeared(self)
        } else if window == nil, counted {
            counted = false
            TerminalWheelForwarder.terminalDisappeared(self)
        }
    }

    private var counted = false


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

        if !durable.isEmpty {
            type(paths: durable.map(\.path))
            return true
        }
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
            if isFileReferenceString(text) { return false }
            session?.paste(text: text)
            takeFocus()
            return true
        }
        return false
    }

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

    private func usableFileURL(_ url: URL) -> URL? {
        let pathURL = (url as NSURL).filePathURL ?? url
        guard pathURL.isFileURL else { return nil }
        return pathURL.resolvingSymlinksInPath()
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

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


    private func type(paths: [String]) {
        guard let session, !paths.isEmpty else { return }
        session.paste(text: paths.map(Self.shellQuoted).joined(separator: " ") + " ")
        takeFocus()
    }

    private func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    private static let unquotedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+=/,:@%")

    static func shellQuoted(_ path: String) -> String {
        if !path.isEmpty, path.allSatisfy(unquotedCharacters.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }


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

    private func persistIfFileReference(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/"), exists(URL(fileURLWithPath: trimmed)) {
            let url = URL(fileURLWithPath: trimmed)
            return persistCopy(url) ?? url.path
        }
        if let parsed = URL(string: trimmed) {
            if parsed.isFileURL, let url = usableFileURL(parsed), exists(url) {
                return persistCopy(url) ?? url.path
            }
            if trimmed.hasPrefix("file:") {
                let decoded = trimmed.removingPercentEncoding ?? trimmed
                let path = decoded.replacingOccurrences(of: "file://", with: "")
                let url = URL(fileURLWithPath: path)
                if exists(url) { return persistCopy(url) ?? url.path }
            }
            return nil
        }
        return nil
    }

    private func isFileReferenceString(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("file:") || trimmed.hasPrefix("/.file/")
    }

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
