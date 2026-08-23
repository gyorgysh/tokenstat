// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import AVFoundation
import SwiftUI
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
                Toggle(isOn: $controlling) { Label("Control", systemImage: "cursorarrow.motionlines") }
                    .disabled(model.state == .streaming)
            }
        }
        .task { await start() }
        .onDisappear { model.stop() }
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
                    model.sendText(press.characters)
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
    let decoder = ScreenH264Decoder()
    private var session: ScreenViewerSession?
    private var task: Task<Void, Never>?
    private var pointerIsDown = false
    private var clipboardChangeCount = -1

    func start(peer: String, tier: String?, control: Bool) async {
        stop()
        state = .connecting
        message = "Connecting…"
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
            state = .streaming
            task = Task { [weak self] in await self?.readLoop(session.id) }
        } catch {
            state = .failed
            message = error.localizedDescription
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let id = session?.id { Task { await Bridge.screenViewerClose(id: id) } }
        session = nil
        pointerIsDown = false
        decoder.reset()
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
                    aspectRatio = CGFloat(frame.width) / CGFloat(max(1, frame.height))
                    decoder.decode(frame)
                }
                if !read.active {
                    state = .failed
                    message = read.error ?? "The screen session ended."
                    return
                }
                syncClipboard()
            } catch {
                state = .failed
                message = error.localizedDescription
                return
            }
        }
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
    func sendText(_ text: String) { send(["type":"text", "text":text]) }
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
