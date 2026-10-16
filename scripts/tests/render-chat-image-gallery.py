#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Render the production gallery/lightbox with inert synthetic chat fixtures.

The accessory QA app uses its own bundle/preferences domain, no sockets, and
an offscreen window. It never launches or touches the running tokenstat app.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', nargs='?', type=Path, default=root / 'target/chat-image-qa')
parser.add_argument('--fixture', action='append', type=Path, default=[], help='Read-only local image; repeat to render a set')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
app = output / 'ImageGalleryQA.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
resources = app / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'apps/localization', resources / 'localization', dirs_exist_ok=True)
for font in (root / 'apps/mac').rglob('*Variable.ttf'):
    shutil.copy(font, resources / font.name)
(app / 'Contents/Info.plist').write_text('''<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tokenstat.image-gallery-qa</string><key>CFBundleExecutable</key><string>ImageGalleryQA</string><key>CFBundleName</key><string>Image Gallery QA</string><key>LSUIElement</key><true/></dict></plist>''')

def declaration(path, signature):
    source = (root / path).read_text()
    start = source.index(signature)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

theme_path = 'apps/mac/Sources/Design/Theme.swift'
pieces = ['import SwiftUI\nimport AppKit\nimport Observation\nimport ImageIO\nimport UniformTypeIdentifiers\n']
pieces += [declaration(theme_path, marker) for marker in [
    'enum Theme {', 'extension Color {', 'struct ThemeRule:',
    'struct ActionLabelStyle:', 'struct SecondaryButtonStyle:', 'enum DisplayFit {',
    'struct ThemedFieldStyle:', 'extension TextFieldStyle where Self == ThemedFieldStyle {', 'struct ThemedFieldBox:']]
pieces += ['extension View {\n' + declaration(theme_path, '    func themedFieldBox(') + '\n}']
pieces += [declaration('apps/mac/Sources/Features/Workspaces/Chat/ChatInbox.swift', 'enum ChatThumbnail {')]
pieces += [declaration('apps/mac/Sources/Features/Workspaces/Chat/ChatFileTransferControls.swift', 'struct ChatFileRelayConsent:')]
pieces += ['''
enum SyntaxKind { case keyword, string, number, constant, comment, type, function, attribute, property, markup, variable, `operator`, punctuation, unknown }
struct WorkReference: Hashable { let id = "synthetic-gallery"; let itemID: String? = "synthetic-gallery" }
struct ChatAttachment: Hashable, Sendable { let id: String; let name: String; let mediaType: String?; var size: UInt64? = nil }
struct QAConversation { var backend = "claude"; var model: String? = "synthetic-model"; var runRevision: UInt64? = 1; var running = true }
@MainActor enum GalleryQAState { static var expanded = false }
@MainActor @Observable final class WorkSessionContext { static let shared = WorkSessionContext(); var scope: String? = "gallery-qa" }
enum WorkCacheAccess { static func canRead(_ reference: WorkReference) -> Bool { true } }
@MainActor @Observable final class ChatModel {
    var currentReference: WorkReference? = WorkReference()
    var responseAttachmentData: [String: Data] = [:]
    var responseAttachmentFiles: [String: URL] = [:]
    var loadingResponseAttachments: Set<String> = []
    var responseAttachmentErrors: [String: String] = [:]
    var savedCopy: Bool? = nil
    var selected: QAConversation? = QAConversation()
    var peer: String? = nil
    var selectionGeneration: UInt64 = 1
    var activityRead: ChatActivityRead?
    var busy: Bool { selected?.running == true }
    var turnUsage: ChatUsageSummary = .available(.init(input: 40000, output: 20000, cacheRead: 180000, cacheWrite: 12000, cost: 0.18))
    var fileRelayPresenter: UUID?
    var fileTransferInFlight = false
    var fileRelayName: String?
    var fileRelaySize: UInt64?
    var fileRelayRemaining: UInt64?
    func answerFileRelay(_ answer: Bool) { fileRelayName = nil }
    func downloadResponseAttachment(_ attachment: ChatAttachment) async {}
}
enum BridgeError: Error { case core(code: String, message: String) }
enum Bridge {
    static func chatInspection(id: String, peer: String?) async throws -> ChatInspection {
        let wire = #"{"backend":"claude","model":"synthetic-model","contextUsed":16782,"contextWindow":200000,"contextSource":"lastInput","windowSource":"agent","contextBreakdown":{"input":5782,"cacheRead":11000,"cacheWrite":0},"contextHistory":[{"tokens":8000,"atMs":1},{"tokens":12500,"atMs":2},{"tokens":16782,"atMs":3}],"tools":["Read","Bash","Edit","mcp__design__capture"],"usedTools":["Read","Bash"],"mcpServers":[{"name":"design-tools","status":"connected","source":"agent","tools":["capture"]},{"name":"project-files","status":"connected","source":"agent","tools":["read"]},{"name":"tokenstat","status":"connected","source":"agent","tools":["status"]},{"name":"optional-service","status":"configured","source":"configuration"}],"mcpReported":true,"currentRun":true,"observedAtMs":1792000000000}"#
        return try JSONDecoder().decode(ChatInspection.self, from: Data(wire.utf8))
    }
}
''']
activity_path = 'apps/mac/Sources/Features/Workspaces/Chat/ChatActivityView.swift'
pieces += [declaration(activity_path, marker) for marker in [
    'struct ChatActivityOwner:', 'struct ChatActivityRead {', 'extension ChatModel {']]
pieces += [(root / 'apps/mac/Sources/Bridge/SessionIdentities.swift').read_text()]
pieces += [(root / 'apps/mac/Sources/Bridge/ChatInspection.swift').read_text()]
pieces += [(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatCostMeter.swift').read_text()]
context = (root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatContextCard.swift').read_text()
for name in ['contextOpen', 'serversOpen', 'otherServersOpen', 'promptOpen', 'historyOpen', 'conversationOpen']:
    context = context.replace(name + ' = false', name + ' = GalleryQAState.expanded')
pieces += [context]
pieces += [(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatImageLayout.swift').read_text()]
pieces += [(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatImageDecode.swift').read_text()]
pieces += [(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatImageGallery.swift').read_text()]
pieces += [declaration('scripts/tests/ChatImageDecodeTests.swift', '    static func tiff(').replace('static func', 'func', 1)]
pieces += [r'''
@MainActor private struct GalleryMutationQA: View {
    @Bindable var model: ChatModel
    let file: ChatAttachment
    var body: some View { ChatImageGallery(resources: model.imageResources(for: [file])).frame(width: 320) }
}
@MainActor final class GalleryQARunner: NSObject, NSApplicationDelegate {
    let output: URL
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await render() } catch { fputs("Gallery QA failed: \(error)\n", stderr); exit(1) }; NSApp.terminate(nil) }
    }
    func fixture(_ index: Int) -> Data {
        let size = index == 1 ? CGSize(width: 440, height: 1000) : CGSize(width: 960, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill(); NSRect(origin: .zero, size: size).fill(using: .copy)
        if index == 2 {
            NSColor.systemPurple.setFill(); NSBezierPath(ovalIn: NSRect(x: 200, y: 110, width: 380, height: 380)).fill()
            NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 310, y: 230, width: 160, height: 140), xRadius: 24, yRadius: 24).fill()
        } else {
            NSColor(calibratedWhite: index == 1 ? 0.94 : 0.97, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
            NSColor(calibratedRed: 0.2, green: 0.12, blue: 0.36, alpha: 1).setFill()
            NSRect(x: 0, y: size.height - 72, width: size.width, height: 72).fill()
            ("SYNTHETIC WORKSPACE \(index + 1)" as NSString).draw(at: NSPoint(x: 28, y: size.height - 52),
                withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
            for row in 0..<6 {
                let gap = min(95, (size.height - 110) / 6)
                let y = size.height - 90 - CGFloat(row + 1) * gap
                NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 25, y: y, width: size.width - 50, height: 72), xRadius: 10, yRadius: 10).fill()
                NSColor.systemPurple.setFill(); NSRect(x: 42, y: y + 22, width: 10, height: 28).fill()
                ("\(row + 1). Review the image layout" as NSString).draw(at: NSPoint(x: 70, y: y + 25),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray])
            }
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    func render() async throws {
        AppFonts.register()
        let model = ChatModel()
        model.activityRead = ChatActivityRead(owner: model.activityOwner,
            inspection: try await Bridge.chatInspection(id: "synthetic-gallery", peer: nil), loaded: true)
        var files: [ChatAttachment] = []
        for index in 0..<9 {
            let file = ChatAttachment(id: "qa-\(index)", name: index == 1 ? "portrait-layout-with-a-long-descriptive-file-name.png" : "workspace-\(index + 1).png", mediaType: "image/png")
            let data = fixture(index % 3)
            if index == 1 {
                let url = output.appendingPathComponent("portrait-source.png")
                try data.write(to: url); model.responseAttachmentFiles[file.id] = url
            } else { model.responseAttachmentData[file.id] = data }
            files.append(file)
        }
        var localFiles: [ChatAttachment] = []
        for (index, path) in CommandLine.arguments.dropFirst(2).enumerated() {
            // Names are intentionally generic; source paths never enter PNGs.
            let file = ChatAttachment(id: "local-\(index)", name: "image.png", mediaType: "image/png")
            model.responseAttachmentFiles[file.id] = URL(fileURLWithPath: path)
            localFiles.append(file)
        }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Exercise the actual SwiftUI task identity, not only the metadata
        // actor: equal-byte-count EXIF changes must update a mounted gallery.
        let mutationFile = ChatAttachment(id: "mutation-qa", name: "orientation.tiff", mediaType: "image/tiff")
        let before = tiff(width: 370, height: 830, orientation: 1)
        let after = tiff(width: 370, height: 830, orientation: 6)
        precondition(before.count == after.count)
        model.responseAttachmentData[mutationFile.id] = before
        let mutationHost = NSHostingView(rootView: GalleryMutationQA(model: model, file: mutationFile))
        mutationHost.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        window.contentView = mutationHost; window.setContentSize(mutationHost.frame.size); window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        mutationHost.layoutSubtreeIfNeeded()
        let portraitHeight = mutationHost.fittingSize.height
        model.responseAttachmentData[mutationFile.id] = after
        try await Task.sleep(for: .milliseconds(500))
        mutationHost.layoutSubtreeIfNeeded()
        let landscapeHeight = mutationHost.fittingSize.height
        precondition(portraitHeight > landscapeHeight + 40,
                     "A mounted gallery must refresh same-length EXIF geometry: \(portraitHeight) -> \(landscapeHeight)")
        print("Native gallery same-length metadata change: \(portraitHeight) -> \(landscapeHeight)")
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [320, 480, 760] {
                for count in [1, 2, 3, 4, 9] {
                    let view = VStack(alignment: .leading, spacing: 12) {
                        Text("Image attachments").font(Theme.callout.weight(.semibold))
                        ChatImageGallery(resources: model.imageResources(for: Array(files.prefix(count))))
                        Spacer(minLength: 0)
                    }.padding(20).frame(width: width, height: count > 3 ? 560 : 390).background(Theme.background)
                    try await capture(AnyView(view), size: CGSize(width: width, height: count > 3 ? 560 : 390),
                        name: "gallery-\(count)-\(Int(width))-\(dark ? "dark" : "light")", window: window)
                }
                if !localFiles.isEmpty, width != 480 {
                    let view = VStack(alignment: .leading, spacing: 12) {
                        Text("Image attachments").font(Theme.callout.weight(.semibold))
                        ChatImageGallery(resources: model.imageResources(for: localFiles))
                        Spacer(minLength: 0)
                    }.padding(20).frame(width: width, height: 330).background(Theme.background)
                    try await capture(AnyView(view), size: CGSize(width: width, height: 330),
                        name: "local-gallery-\(Int(width))-\(dark ? "dark" : "light")", window: window)
                }
            }
            let compact = VStack(alignment: .leading, spacing: 8) {
                Label("Read · 4 images", systemImage: "chevron.right").font(Theme.callout)
                ChatImageGallery(resources: model.imageResources(for: files), compact: true)
            }.padding(20).frame(width: 360, height: 135, alignment: .topLeading).background(Theme.background)
            try await capture(AnyView(compact), size: CGSize(width: 360, height: 135), name: "tool-\(dark ? "dark" : "light")", window: window)
            let request = ChatImagePresentation(reference: model.currentReference, attachments: files, selectedID: files[1].id)
            let viewer = ChatImageViewer(model: model, request: request).frame(width: 880, height: 680)
            try await capture(AnyView(viewer), size: CGSize(width: 880, height: 680), name: "viewer-\(dark ? "dark" : "light")", window: window)
            for width: CGFloat in [320, 360] {
                for expanded in [false, true] {
                    GalleryQAState.expanded = expanded
                    let context = ChatContextCard(model: model).padding(16)
                        .frame(width: width, height: expanded ? 980 : 320, alignment: .topLeading).background(Theme.background)
                    try await capture(AnyView(context), size: CGSize(width: width, height: expanded ? 980 : 320),
                        name: "context-\(Int(width))-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light")", window: window)
                }
            }
        }
        window.orderOut(nil)
        print("Rendered production gallery/lightbox/context QA images to \(output.path)")
    }
    func capture(_ view: AnyView, size: CGSize, name: String, window: NSWindow) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size); window.contentView = hosting; window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
}
@main enum GalleryQA {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let runner = GalleryQARunner(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        application.delegate = runner
        withExtendedLifetime(runner) { application.run() }
    }
}
''']
swift = output / 'GalleryQA.swift'
swift.write_text('\n'.join(pieces))
binary = app / 'Contents/MacOS/ImageGalleryQA'
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(output / 'ModuleCache'),
    str(swift), str(root / 'apps/mac/Sources/Design/AppFonts.swift'), str(root / 'apps/mac/Sources/Design/ActionIcon.swift'),
    str(root / 'apps/mac/Sources/Design/L10n.swift'), str(root / 'apps/mac/Sources/Features/Workspaces/Chat/ChatFileStaging.swift'),
    '-o', str(binary)], check=True)
subprocess.run([str(binary), str(output), *(str(path.resolve()) for path in args.fixture)], check=True, timeout=120)
