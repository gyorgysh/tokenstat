#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise real AppKit drag sessions in an isolated, inert chat-shaped window.

Uses the production drop surface, provider decoder and native composer editor.
Requires existing event-posting permission; never requests permission. All
mouse events stay inside this QA window. The previous app/cursor are restored.
No account, host, clipboard or running Tokenstat state is accessed.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1] if len(sys.argv) > 1 else root / 'target/chat-drop-qa').resolve()
output.mkdir(parents=True, exist_ok=True)

def declaration(path, signature):
    source = (root / path).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

inbox = 'apps/mac/Sources/Features/Workspaces/Chat/ChatInbox.swift'
pieces = ['import AppKit\nimport SwiftUI\nimport UniformTypeIdentifiers\nimport ImageIO\n']
pieces += [declaration(inbox, item) for item in ['struct ChatInboxItem:', 'enum ChatInboxDrop:', 'enum ChatInbox {']]
pieces += [r'''
struct WorkReference: Equatable { let id = "isolated-draft" }
enum Theme { static let accent = Color.purple }
enum L10n { static func text(_ key: String, _ arguments: String...) -> String { key } }
@MainActor final class QAState: ObservableObject {
    @Published var enabled = true
    @Published var nativeEditorEnabled = true
    @Published var paneTargeted = false
    @Published var transcriptTargeted = false
    @Published var composerTargeted = false
    @Published var nativeTargeted = false
    @Published var draft = "Select these composer words"
    @Published var selection = NSRange(location: 0, length: 0)
    var receipts: [String] = []
    var buttons = 0
    func receive(_ providers: [NSItemProvider]) -> Bool {
        guard enabled, !providers.isEmpty else { return false }
        Task {
            let drops = await ChatInbox.drops(from: providers)
            for drop in drops {
                switch drop {
                case let .attachment(item):
                    receipts.append("attachment")
                    if let file = item.file { try? FileManager.default.removeItem(at: file) }
                case .text: receipts.append("text")
                case .folder: receipts.append("folder")
                }
            }
        }
        return true
    }
}
struct QAChat: View {
    @ObservedObject var state: QAState
    var body: some View {
        VStack(spacing: 0) {
            Text("Isolated chat · native drag regression").frame(maxWidth: .infinity).frame(height: 60).background(.gray.opacity(0.1))
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Text("Selectable transcript text for ordinary selection.")
                            .textSelection(.enabled).frame(height: 40, alignment: .topLeading)
                        Button { state.buttons += 1 } label: {
                            Image(systemName: "photo").resizable().scaledToFit().frame(width: 180, height: 100)
                        }.buttonStyle(.plain)
                        Color.clear.frame(height: 80)
                        Text("More transcript content").textSelection(.enabled)
                        Color.clear.frame(height: 700)
                    }.padding(30).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .chatDropSurface(enabled: state.enabled, isTargeted: $state.transcriptTargeted, receive: state.receive)
            }
            Text("Changes · 2 files").frame(maxWidth: .infinity).frame(height: 40).background(.gray.opacity(0.1))
            ChatDraftView(text: $state.draft, selection: $state.selection, owner: WorkReference(),
                placeholder: "Message", enabled: true, acceptsAttachmentDrops: state.enabled && state.nativeEditorEnabled, onSend: {},
                onAttachmentDrop: state.receive, onAttachmentDropTargeted: { state.nativeTargeted = $0 })
                .padding(12).frame(height: 110)
                .chatDropSurface(enabled: state.enabled, isTargeted: $state.composerTargeted, receive: state.receive)
        }
        .frame(width: 700, height: 650).background(Color(NSColor.windowBackgroundColor))
        .chatDropSurface(enabled: state.enabled, isTargeted: $state.paneTargeted, receive: state.receive)
    }
}
final class QADragSource: NSView, NSDraggingSource {
    var payload: NSPasteboardWriting!
    var operation: NSDragOperation?
    var session: NSDraggingSession?
    override func mouseDown(with event: NSEvent) {
        print("BEGIN NATIVE DRAG")
        operation = nil
        let item = NSDraggingItem(pasteboardWriter: payload)
        item.setDraggingFrame(NSRect(x: 10, y: 300, width: 48, height: 48),
            contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
        session = beginDraggingSession(with: [item], event: event, source: self)
        session?.animatesToStartingPositionsOnCancelOrFail = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { self.operation = operation; self.session = nil }
}
enum QAFailure: Error { case failed(String) }
@MainActor final class QARunner: NSObject, NSApplicationDelegate {
    let state = QAState()
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let previousApp = NSWorkspace.shared.frontmostApplication
    let previousCursor = CGEvent(source: nil)?.location
    let source = QADragSource(frame: NSRect(x: 0, y: 0, width: 90, height: 650))
    var window: NSWindow!
    var host: NSHostingView<QAChat>!
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CGPreflightPostEventAccess() else { fputs("Native drop QA requires existing event-posting permission.\n", stderr); exit(2) }
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tokenstat isolated drag QA"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 650))
        host = NSHostingView(rootView: QAChat(state: state))
        host.frame = NSRect(x: 100, y: 0, width: 700, height: 650)
        content.addSubview(source); content.addSubview(host); window.contentView = content
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                try await pause(500)
                try await check()
                finish()
                print("Native chat drops: file/image at text, image, blank gap, both margins, header, changes and composer; disabled rejection; native button, text selection and scrolling passed")
                NSApp.terminate(nil)
            } catch {
                finish()
                fputs("Native drop QA failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
    func finish() {
        if source.operation == nil { post(.leftMouseUp, at: NSPoint(x: 40, y: 350)) }
        window.orderOut(nil)
        if let previousCursor { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: previousCursor, mouseButton: .left)?.post(tap: .cghidEventTap) }
        previousApp?.activate(options: [])
    }
    func pause(_ milliseconds: Int = 180) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw QAFailure.failed(message) } }
    func post(_ type: CGEventType, at point: NSPoint) {
        let screen = window.convertPoint(toScreen: point)
        let location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    func drag(_ payload: NSPasteboardWriting, to point: NSPoint, expected: Bool = true, cancel: Bool = false) async throws {
        try require(window.isKeyWindow, "QA window lost focus; refusing to post mouse events")
        if let item = payload as? NSPasteboardItem {
            let fresh = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { fresh.setData(data, forType: type) } }
            source.payload = fresh
        } else { source.payload = payload }
        source.operation = nil
        post(.leftMouseDown, at: NSPoint(x: 40, y: 350))
        try await pause(100)
        for step in 1...12 {
            let fraction = CGFloat(step) / 12
            post(.leftMouseDragged, at: NSPoint(x: 40 + (point.x - 40) * fraction, y: 350 + (point.y - 350) * fraction))
            try await pause(20)
        }
        try await pause(80)
        if point.y == 55, state.enabled && state.nativeEditorEnabled {
            try require(state.nativeTargeted, "Native composer hover must highlight the shared attachment destination")
        }
        if cancel {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            try await pause()
        }
        post(.leftMouseUp, at: point)
        for _ in 0..<150 {
            if source.operation != nil { break }
            try await pause(20)
        }
        try await pause(400)
        try require(source.operation == (expected && !cancel ? .copy : []), "Native drag ended with unexpected operation at \(point): \(String(describing: source.operation))")
        try require(!state.nativeTargeted, "Native drag targeting must clear after drop or Escape")
    }
    func check() async throws {
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.lockFocus(); NSColor.purple.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let file = output.appendingPathComponent("native-fixture.png")
        try png.write(to: file)
        let filePayload = NSPasteboardItem(); filePayload.setString(file.absoluteString, forType: .fileURL)
        let imagePayload = NSPasteboardItem(); imagePayload.setData(png, forType: .png)
        let destinations: [(String, NSPoint)] = [
            ("text", NSPoint(x: 300, y: 540)), ("image", NSPoint(x: 250, y: 446)),
            ("blank", NSPoint(x: 480, y: 325)), ("left margin", NSPoint(x: 110, y: 440)),
            ("right margin", NSPoint(x: 790, y: 440)), ("header", NSPoint(x: 450, y: 620)),
            ("changes", NSPoint(x: 450, y: 130)), ("composer", NSPoint(x: 450, y: 55))]
        for payload in [filePayload, imagePayload] {
            for (name, point) in destinations {
                let before = state.receipts.count
                try await drag(payload, to: point)
                try require(state.receipts.count == before + 1 && state.receipts.last == "attachment", "\(name) must decode exactly one attachment")
                try require(state.draft == "Select these composer words", "Attachment drops cannot insert a file path into the composer")
                print("PASS \(payload === filePayload ? "file" : "image") over \(name)")
            }
        }
        // Reproduce the native editor's former decline-to-parent assumption:
        // the ancestor remains enabled, but AppKit ends this drop with none.
        state.nativeEditorEnabled = false; try await pause()
        let legacyCount = state.receipts.count
        try await drag(filePayload, to: NSPoint(x: 450, y: 55), expected: false)
        try require(state.receipts.count == legacyCount, "A declining native editor does not reliably bubble to its enabled parent")
        state.nativeEditorEnabled = true; try await pause()
        try await drag(filePayload, to: NSPoint(x: 450, y: 55), cancel: true)
        try require(state.receipts.count == legacyCount, "Escape must cancel the pending native attachment drop")
        state.enabled = false; try await pause()
        let before = state.receipts.count
        try await drag(filePayload, to: NSPoint(x: 300, y: 540), expected: false)
        try require(state.receipts.count == before, "An inactive surface must refuse new drops")
        state.enabled = true; try await pause()
        post(.leftMouseDown, at: NSPoint(x: 250, y: 446)); post(.leftMouseUp, at: NSPoint(x: 250, y: 446))
        try await pause()
        try require(state.buttons == 1, "The gallery-style image button must retain normal clicks")
        guard let editor = descendants(host).compactMap({ $0 as? ChatDraftTextView }).first,
              let layout = editor.layoutManager, let container = editor.textContainer else { throw QAFailure.failed("Missing native production composer") }
        let glyphs = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 12), in: container)
        let origin = editor.textContainerOrigin
        let start = editor.convert(NSPoint(x: glyphs.minX + origin.x + 2, y: glyphs.midY + origin.y), to: nil)
        let end = editor.convert(NSPoint(x: glyphs.maxX + origin.x - 2, y: glyphs.midY + origin.y), to: nil)
        post(.leftMouseDown, at: start)
        for step in 1...8 {
            post(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 8, y: start.y))
            try await pause(20)
        }
        post(.leftMouseUp, at: end); try await pause()
        try require(editor.selectedRange().length > 0, "Native mouse text selection must remain available")
        let textPayload = NSPasteboardItem(); textPayload.setString(" ordinary text ", forType: .string)
        let attachmentCount = state.receipts.count
        try await drag(textPayload, to: start)
        try require(state.receipts.count == attachmentCount && state.draft.contains("ordinary text"), "Plain text drags must remain native composer edits")
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: { !($0 is ChatDraftScrollView) }) else { throw QAFailure.failed("Missing transcript scroll view") }
        let oldTop = scroll.contentView.bounds.origin.y
        let point = window.convertPoint(toScreen: NSPoint(x: 600, y: 350))
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0)!
        wheel.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y)
        wheel.post(tap: .cghidEventTap); try await pause(400)
        try require(scroll.contentView.bounds.origin.y != oldTop, "Native transcript scrolling must remain available")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("native-drop-qa.png"))
        }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
@main enum NativeChatDropQA {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = QARunner(); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
''']
source = output / 'NativeChatDropQA.swift'
source.write_text('\n'.join(pieces))
binary = output / 'native-chat-drop-qa'
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(output / 'ModuleCache'),
    str(source), str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatDropSurface.swift'),
    str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatDraftView.swift'), '-o', str(binary)], check=True)
subprocess.run([str(binary), str(output)], check=True, timeout=90)
