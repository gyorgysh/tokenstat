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
    private var encoder: ScreenVideoEncoder?
    private var task: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameContinuation: AsyncStream<Data>.Continuation?
    private var pressure = 0
    private var clearFrames = 0

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        let (frames, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(3))
        frameContinuation = continuation
        frameTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await frame in frames { await self?.push(frame) }
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
                for session in sessions where session.control {
                    if let input = try? await Bridge.screenCaptureInput(id: session.id) {
                        ScreenInput.apply(input)
                    }
                }
            } catch {
                // hostd may be restarting or no session may exist yet.
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func adopt(_ sessions: [ScreenCaptureSession]) async throws {
        let (needsEncoder, existing) = lock.withLock {
            active = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            return (!active.isEmpty, encoder)
        }

        if needsEncoder, existing == nil {
            let created = ScreenVideoEncoder { [weak self] frame in
                self?.frameContinuation?.yield(frame)
            }
            try await created.start()
            lock.withLock { encoder = created }
        } else if !needsEncoder, let existing {
            existing.stop()
            lock.withLock { encoder = nil }
        }
    }

    private func push(_ frame: Data) async {
        let (ids, encoder) = lock.withLock { (Array(active.keys), self.encoder) }
        var congested = false
        for id in ids {
            if let result = try? await Bridge.screenCapturePush(id: id, frame: frame), !result.accepted { congested = true }
        }
        if congested {
            pressure += 1; clearFrames = 0
            if pressure == 3 { await encoder?.setQuality(0.7) }
        } else {
            pressure = 0; clearFrames += 1
            if clearFrames == 300 { await encoder?.setQuality(1) }
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

    init(output: @escaping @Sendable (Data) -> Void) { self.output = output }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenCaptureError.noDisplay }
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
        configuration = config

        try makeCompression()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        let stream = stream
        self.stream = nil
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
    static func video(sequence: UInt64, timestamp: CMTime, width: UInt16, height: UInt16, keyframe: Bool, payload: Data) -> Data {
        var data = Data("TSCR".utf8)
        data.append(contentsOf: [1, 1, keyframe ? 1 : 0, 0])
        data.appendBigEndian(sequence)
        let micros = timestamp.isNumeric ? UInt64(max(0, CMTimeGetSeconds(timestamp) * 1_000_000)) : 0
        data.appendBigEndian(micros)
        data.appendBigEndian(width)
        data.appendBigEndian(height)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

private enum ScreenInput {
    struct Event: Decodable { var type: String; var x: Double?; var y: Double?; var button: Int?; var down: Bool?; var keyCode: UInt16?; var flags: UInt64?; var text: String? }
    static func apply(_ data: Data) {
        guard AXIsProcessTrusted(), let event = try? JSONDecoder().decode(Event.self, from: data) else { return }
        let display = CGMainDisplayID()
        let point = CGPoint(
            x: (event.x ?? 0) * Double(CGDisplayPixelsWide(display)),
            y: (event.y ?? 0) * Double(CGDisplayPixelsHigh(display))
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
