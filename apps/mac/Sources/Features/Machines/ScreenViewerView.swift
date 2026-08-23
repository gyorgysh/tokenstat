// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AVFoundation
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Legend screen viewer. H.264 is decoded entirely at this endpoint by the
/// system display layer; the relay and account service see encrypted bytes.
struct ScreenViewerView: View {
    let peer: String
    let name: String
    let tier: String?
    @State private var model = ScreenViewerModel()
    @State private var controlling = false
    @State private var muted = false
    @State private var importingFile = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScreenVideoSurface(layer: model.decoder.layer)
                .aspectRatio(model.aspectRatio, contentMode: .fit)
                .overlay { inputSurface }
            if model.state != .streaming {
                VStack(spacing: Theme.Space.m) {
                    ProgressView().opacity(model.state == .connecting ? 1 : 0)
                    Text(model.message).foregroundStyle(.white)
                    if model.state == .failed {
                        Button("Try again", .refresh) { Task { await start() } }
                    }
                }
                .padding(Theme.Space.l)
            }
        }
        .navigationTitle(name)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                Circle().fill(model.transport == "direct" ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.transport == "direct" ? "Direct connection" : "Encrypted relay")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        }
        .toolbar {
            if model.displays.count > 1 {
                ToolbarItem {
                    Picker("Display", selection: Binding(
                        get: { model.selectedDisplay ?? 0 },
                        set: { model.selectDisplay($0) }
                    )) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            ToolbarItem {
                if model.transferProgress == nil {
                    Button("Send file", .upload) { importingFile = true }
                } else {
                    Button("Cancel transfer", .stop) { model.cancelTransfer() }
                }
            }
            ToolbarItem {
                Toggle(isOn: $muted) { Label("Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2") }
                    .onChange(of: muted) { _, value in model.audio.muted = value }
            }
            ToolbarItem {
                Toggle(isOn: $controlling) { Label("Control", systemImage: "cursorarrow.motionlines") }
                    .disabled(model.state == .streaming)
            }
        }
        .task { await start() }
        .onDisappear { model.stop() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            model.sendFile(url)
        }
        .overlay(alignment: .bottom) {
            if let progress = model.transferProgress {
                ProgressView(value: progress).padding().background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private func start() async { await model.start(peer: peer, tier: tier, control: controlling) }

    private var inputSurface: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard controlling else { return }
                    model.movePointer(
                        x: value.location.x / max(1, geometry.size.width),
                        y: value.location.y / max(1, geometry.size.height)
                    )
                }.onEnded { value in
                    guard controlling else { return }
                    model.releasePointer(
                        x: value.location.x / max(1, geometry.size.width),
                        y: value.location.y / max(1, geometry.size.height)
                    )
                })
                .focusable(controlling)
                .onKeyPress { press in
                    guard controlling, !press.characters.isEmpty else { return .ignored }
                    model.sendText(press.characters, flags: press.modifiers.screenFlags)
                    return .handled
                }
        }
    }
}

@MainActor @Observable
private final class ScreenViewerModel {
    enum State { case idle, connecting, streaming, failed }
    var state: State = .idle
    var message = "Connecting…"
    var aspectRatio: CGFloat = 16 / 9
    var displays: [ScreenDisplay] = []
    var selectedDisplay: UInt32?
    var transferProgress: Double?
    var transport = "relay"
    let decoder = ScreenH264Decoder()
    let audio = ScreenAudioPlayer()
    private var session: ScreenViewerSession?
    private var task: Task<Void, Never>?
    private var pointerIsDown = false
    private var peer = ""
    private var transferTask: Task<Void, Never>?
    private var clipboardChangeCount = -1
    private var requestedTier: String?
    private var requestedControl = false
    private var reconnectAttempts = 0
    private var stopped = false

    func start(peer: String, tier: String?, control: Bool) async {
        stop()
        stopped = false
        self.peer = peer
        requestedTier = tier
        requestedControl = control
        reconnectAttempts = 0
        state = .connecting
        message = "Connecting…"
        await connect()
    }

    private func connect() async {
        let tier = requestedTier
        let control = requestedControl
        guard tier?.lowercased() == "legend" else {
            state = .failed
            message = "Screen access requires the Legend plan."
            return
        }
        do {
            let identity = try await Bridge.machineIdentity()
            let capability = try await Bridge.onPeer(
                peer,
                "screen.capability.issue",
                ["peerID": identity.key, "control": control, "tier": tier ?? ""],
                as: ScreenCapability.self
            )
            let session = try await Bridge.screenViewerOpen(peer: peer, capability: capability.token, control: control)
            self.session = session
            transport = session.transport
            state = .streaming
            task = Task { [weak self] in await self?.readLoop(session.id) }
        } catch {
            let reason = error.localizedDescription
            if actionable(reason) { state = .failed; message = reason }
            else { reconnect(after: reason) }
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        if let id = session?.id { Task { await Bridge.screenViewerClose(id: id) } }
        session = nil
        pointerIsDown = false
        decoder.reset()
        audio.reset()
        transferTask?.cancel()
        transferTask = nil
    }

    private func readLoop(_ id: String) async {
        while !Task.isCancelled {
            do {
                let read = try await Bridge.screenViewerRead(id: id)
                if let encoded = read.metadata, let data = Data(base64Encoded: encoded),
                   let metadata = try? JSONDecoder().decode(ScreenMetadata.self, from: data)
                {
                    if metadata.type == "displays", let values = metadata.displays {
                        displays = values
                        selectedDisplay = metadata.selected
                    } else if metadata.type == "clipboard", let text = metadata.text {
                        applyClipboard(text)
                    }
                }
                if let encoded = read.frame, let data = Data(base64Encoded: encoded),
                   let frame = ScreenEncodedFrame(data)
                {
                    reconnectAttempts = 0
                    aspectRatio = CGFloat(frame.width) / CGFloat(max(1, frame.height))
                    decoder.decode(frame)
                }
                if let encoded = read.audio, let data = Data(base64Encoded: encoded) {
                    audio.play(data)
                }
                if !read.active {
                    let reason = read.error ?? "The screen session ended."
                    if actionable(reason) { state = .failed; message = reason }
                    else { reconnect(after: reason) }
                    return
                }
                syncClipboard()
            } catch {
                reconnect(after: error.localizedDescription)
                return
            }
        }
    }

    private func reconnect(after reason: String) {
        guard !stopped else { return }
        if let id = session?.id { Task { await Bridge.screenViewerClose(id: id) } }
        session = nil
        decoder.reset(); audio.reset()
        reconnectAttempts += 1
        guard reconnectAttempts <= 3 else {
            state = .failed
            message = "Connection could not recover. \(reason)"
            return
        }
        state = .connecting
        message = "Connection interrupted. Reconnecting…"
        let delay = reconnectAttempts
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func actionable(_ reason: String) -> Bool {
        let value = reason.lowercased()
        return value.contains("screen recording") || value.contains("accessibility")
            || value.contains("permission") || value.contains("not been allowed")
            || value.contains("does not have screen access") || value.contains("legend plan")
            || value.contains("no display") || value.contains("videotoolbox")
    }

    func movePointer(x: CGFloat, y: CGFloat) {
        if pointerIsDown {
            send(["type":"move", "x":x, "y":y] as [String: Any])
        } else {
            pointerIsDown = true
            send(["type":"pointer", "x":x, "y":y, "down":true] as [String: Any])
        }
    }
    func releasePointer(x: CGFloat, y: CGFloat) {
        guard pointerIsDown else { return }
        pointerIsDown = false
        send(["type":"pointer", "x":x, "y":y, "down":false] as [String: Any])
    }
    func sendText(_ text: String, flags: UInt64) { send(["type":"text", "text":text, "flags":flags] as [String: Any]) }
    func selectDisplay(_ id: UInt32) {
        guard displays.contains(where: { $0.id == id }) else { return }
        selectedDisplay = id
        decoder.reset()
        send(["type":"display", "id":id] as [String: Any])
    }
    private func syncClipboard() {
        let value: (Int, String?)
        #if os(macOS)
        value = (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
        #else
        value = (UIPasteboard.general.changeCount, UIPasteboard.general.string)
        #endif
        guard value.0 != clipboardChangeCount else { return }
        clipboardChangeCount = value.0
        guard let text = value.1, text.utf8.count <= 4_096 else { return }
        send(["type":"clipboard", "text":text])
    }
    private func applyClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardChangeCount = NSPasteboard.general.changeCount
        #else
        UIPasteboard.general.string = text
        clipboardChangeCount = UIPasteboard.general.changeCount
        #endif
    }
    private func send(_ value: [String: Any]) {
        guard let id = session?.id, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        Task { try? await Bridge.screenViewerInput(id: id, data: data) }
    }

    func sendFile(_ url: URL) {
        guard transferTask == nil, !peer.isEmpty else { return }
        transferTask = Task { [weak self] in
            await self?.transfer(url)
            self?.transferTask = nil
        }
    }

    func cancelTransfer() { transferTask?.cancel() }

    private func transfer(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var id = ""
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            var size: UInt64 = 0
            while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data); size += UInt64(data.count)
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let resumeKey = Data("\(url.lastPathComponent)\u{0}\(size)\u{0}\(hash)".utf8)
            id = SHA256.hash(data: resumeKey).map { String(format: "%02x", $0) }.joined()
            let opened = try await Bridge.onPeer(peer, "screen.transfer.open", [
                "id": id, "name": url.lastPathComponent, "size": size, "digest": hash,
            ], as: ScreenTransferOpen.self)
            try handle.seek(toOffset: opened.offset)
            var offset = opened.offset
            transferProgress = size == 0 ? 1 : Double(offset) / Double(size)
            while let data = try handle.read(upToCount: min(opened.chunkBytes, 256 * 1024)), !data.isEmpty {
                try Task.checkCancellation()
                let answer = try await Bridge.onPeer(peer, "screen.transfer.chunk", [
                    "id": id, "offset": offset, "data": data.base64EncodedString(),
                ], as: ScreenTransferChunk.self)
                offset = answer.offset
                transferProgress = size == 0 ? 1 : Double(offset) / Double(size)
            }
            _ = try await Bridge.onPeer(peer, "screen.transfer.finish", ["id": id], as: ScreenTransferSaved.self)
            transferProgress = nil
        } catch is CancellationError {
            _ = try? await Bridge.onPeer(peer, "screen.transfer.cancel", ["id": id], as: ScreenTransferCancelled.self)
            transferProgress = nil
        } catch {
            transferProgress = nil
            message = error.localizedDescription
        }
    }
}

@MainActor
private final class ScreenAudioPlayer {
    var muted = false { didSet { if muted { player.stop() } } }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false

    func reset() {
        player.stop()
        engine.stop()
    }

    func play(_ data: Data) {
        guard !muted, data.count >= 16, String(data: data.prefix(4), encoding: .utf8) == "TAUD",
              data[4] == 1 else { return }
        let channels = AVAudioChannelCount(data[5])
        let rate: UInt32 = data.integer(at: 8)
        let frames: UInt32 = data.integer(at: 12)
        let samples = Int(frames) * Int(channels)
        guard channels > 0, channels <= 8, rate > 0,
              data.count == 16 + samples * MemoryLayout<Int16>.size,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let input = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Int16.self)
            for frame in 0..<Int(frames) {
                for channel in 0..<Int(channels) {
                    output[channel][frame] = Float(Int16(littleEndian: input[frame * Int(channels) + channel])) / Float(Int16.max)
                }
            }
        }
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try? engine.start()
            player.play()
            configured = true
        } else if !player.isPlaying {
            try? engine.start()
            player.play()
        }
        player.scheduleBuffer(buffer)
    }
}

private struct ScreenDisplay: Codable, Hashable, Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
}

private struct ScreenMetadata: Codable {
    let type: String
    let selected: UInt32?
    let displays: [ScreenDisplay]?
    let id: String?
    let text: String?
}

private extension EventModifiers {
    var screenFlags: UInt64 {
        var value: UInt64 = 0
        if contains(.capsLock) { value |= 1 << 16 }
        if contains(.shift) { value |= 1 << 17 }
        if contains(.control) { value |= 1 << 18 }
        if contains(.option) { value |= 1 << 19 }
        if contains(.command) { value |= 1 << 20 }
        return value
    }
}

private struct ScreenEncodedFrame {
    let sequence: UInt64
    let width: UInt16
    let height: UInt16
    let keyframe: Bool
    let payload: Data
    init?(_ data: Data) {
        guard data.count >= 32, String(data: data.prefix(4), encoding: .utf8) == "TSCR", data[4] == 1, data[5] == 1 else { return nil }
        sequence = data.integer(at: 8)
        keyframe = data[6] & 1 == 1
        width = data.integer(at: 24)
        height = data.integer(at: 26)
        let count: UInt32 = data.integer(at: 28)
        guard data.count == 32 + Int(count) else { return nil }
        payload = data.subdata(in: 32..<data.count)
    }
}

@MainActor
private final class ScreenH264Decoder {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resizeAspect }
    func reset() { layer.flushAndRemoveImage(); format = nil }

    func decode(_ frame: ScreenEncodedFrame) {
        let units = frame.payload.annexBUnits()
        if frame.keyframe,
           let sps = units.first(where: { $0.first.map { $0 & 0x1f == 7 } == true }),
           let pps = units.first(where: { $0.first.map { $0 & 0x1f == 8 } == true })
        {
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [
                        spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
        }
        guard let format else { return }
        let pictures = units.filter { unit in unit.first.map { ![7, 8].contains(Int($0 & 0x1f)) } ?? false }
        var avcc = Data()
        for unit in pictures { avcc.appendBigEndian(UInt32(unit.count)); avcc.append(unit) }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return }
        avcc.withUnsafeBytes { raw in _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }
}

#if os(macOS)
private struct ScreenVideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView { LayerHost(layer) }
    func updateNSView(_ view: NSView, context: Context) { view.layer?.frame = view.bounds }
    private final class LayerHost: NSView {
        init(_ display: CALayer) { super.init(frame: .zero); wantsLayer = true; layer = display }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); layer?.frame = bounds }
    }
}
#else
private struct ScreenVideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> UIView { LayerHost(layer) }
    func updateUIView(_ view: UIView, context: Context) { view.layer.sublayers?.first?.frame = view.bounds }
    private final class LayerHost: UIView {
        init(_ display: CALayer) { super.init(frame: .zero); layer.addSublayer(display) }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); layer.sublayers?.first?.frame = bounds }
    }
}
#endif

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(at offset: Int) -> T {
        self[offset..<offset + MemoryLayout<T>.size].reduce(0) { ($0 << 8) | T($1) }
    }
    func annexBUnits() -> [Data] {
        let bytes = [UInt8](self); var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count { if bytes[i...i+3] == [0,0,0,1] { starts.append(i + 4); i += 4 } else { i += 1 } }
        return starts.enumerated().map { index, start in Data(bytes[start..<(index + 1 < starts.count ? starts[index + 1] - 4 : bytes.count)]) }
    }
}
