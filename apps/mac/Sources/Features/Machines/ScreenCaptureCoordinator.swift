// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// Device-local endpoint for Legend screen sessions owned by hostd.
final class ScreenCaptureCoordinator: @unchecked Sendable {
    static let shared = ScreenCaptureCoordinator()

    private let lock = NSLock()
    private var active: [String: ScreenCaptureSession] = [:]
    private var encoders: [String: ScreenVideoEncoder] = [:]
    private var task: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<(String, Data)>.Continuation?
    private var pressure: [String: Int] = [:]
    private var clearFrames: [String: Int] = [:]
    private var clipboardChangeCount = -1

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        let (frames, continuation) = AsyncStream.makeStream(of: (String, Data).self, bufferingPolicy: .bufferingNewest(12))
        frameContinuation = continuation
        frameTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await (id, frame) in frames { await self?.push(frame, to: id) }
        }
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let sessions = try await Bridge.screenCaptureSessions()
                try await adopt(sessions)
                for session in sessions {
                    if let input = try? await Bridge.screenCaptureInput(id: session.id) {
                        if let display = ScreenInput.displaySelection(input) {
                            try? await encoder(for: session.id)?.selectDisplay(display)
                        } else if let clipboard = ScreenInput.clipboard(input) {
                            await applyClipboard(clipboard)
                        } else if session.control {
                            ScreenInput.apply(input, displayID: encoder(for: session.id)?.displayID)
                        }
                    }
                }
                await publishClipboard(to: sessions.map(\.id))
            } catch {
                // hostd may be restarting or no session may exist yet.
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func adopt(_ sessions: [ScreenCaptureSession]) async throws {
        let (added, removed) = lock.withLock {
            let previous = Set(active.keys)
            active = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let current = Set(active.keys)
            return (current.subtracting(previous), previous.subtracting(current))
        }

        for id in removed {
            lock.withLock { encoders.removeValue(forKey: id) }?.stop()
            pressure[id] = nil; clearFrames[id] = nil
        }
        for id in added {
            let created = ScreenVideoEncoder { [weak self] frame in
                self?.frameContinuation?.yield((id, frame))
            }
            try await created.start()
            lock.withLock { encoders[id] = created }
        }
    }

    private func encoder(for id: String) -> ScreenVideoEncoder? { lock.withLock { encoders[id] } }

    private func publishClipboard(to ids: [String]) async {
        guard !ids.isEmpty else { return }
        let update: (String, String)? = await MainActor.run {
            let board = NSPasteboard.general
            guard board.changeCount != clipboardChangeCount else { return nil }
            clipboardChangeCount = board.changeCount
            guard let text = board.string(forType: .string), text.utf8.count <= 4_096 else { return nil }
            return (UUID().uuidString, text)
        }
        guard let update,
              let payload = try? JSONSerialization.data(withJSONObject: ["type": "clipboard", "id": update.0, "text": update.1]) else { return }
        let frame = ScreenWire.metadata(payload)
        for id in ids { frameContinuation?.yield((id, frame)) }
    }

    private func applyClipboard(_ text: String) async {
        await MainActor.run {
            let board = NSPasteboard.general
            guard board.string(forType: .string) != text else { return }
            board.clearContents()
            board.setString(text, forType: .string)
            clipboardChangeCount = board.changeCount
        }
    }

    private func push(_ frame: Data, to id: String) async {
        let encoder = encoder(for: id)
        let congested = if let result = try? await Bridge.screenCapturePush(id: id, frame: frame) { !result.accepted } else { true }
        if congested {
            pressure[id, default: 0] += 1; clearFrames[id] = 0
            if pressure[id] == 3 { await encoder?.setQuality(0.7) }
        } else {
            pressure[id] = 0; clearFrames[id, default: 0] += 1
            if clearFrames[id] == 300 { await encoder?.setQuality(1) }
        }
    }
}

private final class ScreenVideoEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let output: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "ai.tokenstat.screen.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var compression: VTCompressionSession?
    private var sequence: UInt64 = 0
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var configuration: SCStreamConfiguration?
    private(set) var displayID: CGDirectDisplayID?

    init(output: @escaping @Sendable (Data) -> Void) { self.output = output }

    func start(displayID requestedID: CGDirectDisplayID? = nil) async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = requestedID.flatMap({ id in content.displays.first { $0.displayID == id } }) ?? content.displays.first else { throw ScreenCaptureError.noDisplay }
        displayID = display.displayID
        let displays = content.displays.enumerated().map { index, item in
            ["id": item.displayID, "name": item.displayID == CGMainDisplayID() ? "Main display" : "Display \(index + 1)", "width": item.width, "height": item.height] as [String: Any]
        }
        if let metadata = try? JSONSerialization.data(withJSONObject: ["type": "displays", "selected": display.displayID, "displays": displays]) {
            output(ScreenWire.metadata(metadata))
        }
        let scale = min(1, 1920 / CGFloat(display.width))
        sourceWidth = display.width
        sourceHeight = display.height
        width = Int32(max(2, Int(CGFloat(display.width) * scale) & ~1))
        height = Int32(max(2, Int(CGFloat(display.height) * scale) & ~1))

        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        configuration = config

        try makeCompression()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func selectDisplay(_ id: CGDirectDisplayID) async throws {
        guard id != displayID else { return }
        stop()
        try await start(displayID: id)
    }

    func stop() {
        let stream = stream
        self.stream = nil
        displayID = nil
        Task { try? await stream?.stopCapture() }
        if let compression { VTCompressionSessionInvalidate(compression) }
        compression = nil
    }

    func setQuality(_ quality: CGFloat) async {
        guard let stream, let config = configuration else { return }
        let scale = min(1, 1920 / CGFloat(sourceWidth)) * quality
        let newWidth = Int32(max(2, Int(CGFloat(sourceWidth) * scale) & ~1))
        let newHeight = Int32(max(2, Int(CGFloat(sourceHeight) * scale) & ~1))
        guard newWidth != width else { return }
        config.width = Int(newWidth); config.height = Int(newHeight)
        do {
            try await stream.updateConfiguration(config)
            queue.sync {
                if let compression { VTCompressionSessionInvalidate(compression) }
                compression = nil; width = newWidth; height = newHeight
                try? makeCompression()
            }
        } catch { return }
    }

    private func makeCompression() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                guard status == noErr, let refcon, let sample else { return }
                Unmanaged<ScreenVideoEncoder>.fromOpaque(refcon).takeUnretainedValue().encoded(sample)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw ScreenCaptureError.encoder(status) }
        compression = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if let payload = ScreenAudioPCM.encode(sampleBuffer) { output(ScreenWire.audio(payload)) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let image = CMSampleBufferGetImageBuffer(sampleBuffer),
              let compression else { return }
        VTCompressionSessionEncodeFrame(compression, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp, duration: sampleBuffer.duration, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    private func encoded(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        var payload = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    payload.append(contentsOf: [0, 0, 0, 1])
                    payload.append(pointer, count: size)
                }
            }
        }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: total)
        var offset = 0
        while offset + 4 <= total {
            let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size >= 0, offset + size <= total else { return }
            payload.append(contentsOf: [0, 0, 0, 1])
            payload.append(bytes.bindMemory(to: UInt8.self).baseAddress! + offset, count: size)
            offset += size
        }
        guard payload.count <= 1_048_576 else { return }
        sequence += 1
        output(ScreenWire.video(sequence: sequence, timestamp: sample.presentationTimeStamp, width: UInt16(width), height: UInt16(height), keyframe: keyframe, payload: payload))
    }
}

private enum ScreenWire {
    static func metadata(_ payload: Data) -> Data {
        frame(kind: 4, sequence: 0, timestamp: 0, width: 0, height: 0, independent: true, payload: payload)
    }
    static func audio(_ payload: Data) -> Data {
        frame(kind: 5, sequence: 0, timestamp: 0, width: 0, height: 0, independent: true, payload: payload)
    }
    static func video(sequence: UInt64, timestamp: CMTime, width: UInt16, height: UInt16, keyframe: Bool, payload: Data) -> Data {
        let micros = timestamp.isNumeric ? UInt64(max(0, CMTimeGetSeconds(timestamp) * 1_000_000)) : 0
        return frame(kind: 1, sequence: sequence, timestamp: micros, width: width, height: height, independent: keyframe, payload: payload)
    }
    private static func frame(kind: UInt8, sequence: UInt64, timestamp: UInt64, width: UInt16, height: UInt16, independent: Bool, payload: Data) -> Data {
        var data = Data("TSCR".utf8)
        data.append(contentsOf: [1, kind, independent ? 1 : 0, 0])
        data.appendBigEndian(sequence)
        data.appendBigEndian(timestamp)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

private enum ScreenAudioPCM {
    static func encode(_ sample: CMSampleBuffer) -> Data? {
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              basic.pointee.mFormatID == kAudioFormatLinearPCM,
              basic.pointee.mBitsPerChannel == 32,
              basic.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        let channels = Int(basic.pointee.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard channels > 0, channels <= 8, frames > 0,
              frames * channels * MemoryLayout<Int16>.size <= 64 * 1024 else { return nil }
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        defer { free(list.unsafeMutablePointer) }
        var block: CMBlockBuffer?
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &needed, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &block
        ) == noErr else { return nil }
        let nonInterleaved = basic.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var payload = Data("TAUD".utf8)
        payload.append(contentsOf: [1, UInt8(channels), 0, 0])
        payload.appendBigEndian(UInt32(basic.pointee.mSampleRate))
        payload.appendBigEndian(UInt32(frames))
        for frame in 0..<frames {
            for channel in 0..<channels {
                let buffer = list[nonInterleaved ? channel : 0]
                guard let bytes = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let value = bytes[nonInterleaved ? frame : frame * channels + channel]
                var encoded = Int16(max(-1, min(1, value)) * Float(Int16.max)).littleEndian
                Swift.withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
            }
        }
        return payload
    }
}

private enum ScreenInput {
    struct Event: Decodable { var type: String; var x: Double?; var y: Double?; var id: UInt32?; var button: Int?; var down: Bool?; var keyCode: UInt16?; var flags: UInt64?; var text: String? }
    static func displaySelection(_ data: Data) -> CGDirectDisplayID? {
        guard let event = try? JSONDecoder().decode(Event.self, from: data), event.type == "display" else { return nil }
        return event.id
    }
    static func clipboard(_ data: Data) -> String? {
        guard let event = try? JSONDecoder().decode(Event.self, from: data), event.type == "clipboard",
              let text = event.text, text.utf8.count <= 4_096 else { return nil }
        return text
    }
    static func apply(_ data: Data, displayID: CGDirectDisplayID?) {
        guard AXIsProcessTrusted(), let event = try? JSONDecoder().decode(Event.self, from: data) else { return }
        let display = displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let point = CGPoint(
            x: bounds.minX + (event.x ?? 0) * bounds.width,
            y: bounds.minY + (event.y ?? 0) * bounds.height
        )
        let source = CGEventSource(stateID: .hidSystemState)
        let cg: CGEvent?
        switch event.type {
        case "pointer":
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            cg = CGEvent(mouseEventSource: source, mouseType: event.down == true ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        case "move": cg = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        case "mouse":
            let button = CGMouseButton(rawValue: UInt32(event.button ?? 0)) ?? .left
            let type: CGEventType = event.down == true ? (button == .right ? .rightMouseDown : .leftMouseDown) : (button == .right ? .rightMouseUp : .leftMouseUp)
            cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        case "key": cg = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode ?? 0, keyDown: event.down == true)
        case "text":
            guard let text = event.text else { return }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
            down?.post(tap: .cghidEventTap)
            cg = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        default: cg = nil
        }
        if let flags = event.flags { cg?.flags = CGEventFlags(rawValue: flags) }
        cg?.post(tap: .cghidEventTap)
    }
}

private enum ScreenCaptureError: LocalizedError {
    case permission, noDisplay, encoder(OSStatus)
    var errorDescription: String? {
        switch self {
        case .permission: "Allow Screen Recording in System Settings > Privacy & Security."
        case .noDisplay: "No display is available to share."
        case let .encoder(status): "VideoToolbox could not start (\(status))."
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif
