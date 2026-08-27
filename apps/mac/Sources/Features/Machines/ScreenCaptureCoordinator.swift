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

    /// How often the helper looks for waiting input.
    ///
    /// A tenth of a second is the pace of bookkeeping, not of a pointer. A
    /// finger moving across a phone produces events at the display's rate, and
    /// polling ten times a second turned that into ten coarse jumps a
    /// tenth of a second behind the finger, which is what made control mode
    /// feel like it was arguing back. Watching costs nothing extra: with no
    /// controller on the session there is nothing in the queue to find, so the
    /// loop stays on the slow beat.
    private static let controlPoll = Duration.milliseconds(8)
    private static let idlePoll = Duration.milliseconds(100)
    /// The session list and the pasteboard change count keep the slow beat
    /// whatever the input loop is doing. Neither changes at pointer rate, and
    /// both cost a round trip through the host.
    private static let bookkeepingInterval: TimeInterval = 0.1

    private func run() async {
        var sessions: [ScreenCaptureSession] = []
        var nextBookkeeping = Date.distantPast
        while !Task.isCancelled {
            do {
                if Date() >= nextBookkeeping {
                    nextBookkeeping = Date().addingTimeInterval(Self.bookkeepingInterval)
                    sessions = try await Bridge.screenCaptureSessions()
                    try await adopt(sessions)
                    await publishClipboard(to: sessions.filter(\.control).map(\.id))
                }
                for session in sessions {
                    guard let inputs = try? await Bridge.screenCaptureInput(id: session.id) else { continue }
                    for input in inputs {
                        if let display = ScreenInput.displaySelection(input) {
                            try? await encoder(for: session.id)?.selectDisplay(display)
                        } else if let clipboard = ScreenInput.clipboard(input) {
                            if session.control {
                                await applyClipboard(clipboard)
                            }
                        } else if session.control {
                            ScreenInput.apply(input, displayID: encoder(for: session.id)?.displayID)
                        }
                    }
                }
            } catch {
                // hostd may be restarting or no session may exist yet.
                sessions = []
            }
            let controlling = sessions.contains(where: \.control)
            try? await Task.sleep(for: controlling ? Self.controlPoll : Self.idlePoll)
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
            do {
                let session = sessions.first { $0.id == id }
                try await created.start(
                    control: session?.control ?? false,
                    profile: session?.profile ?? .relay
                )
                lock.withLock { encoders[id] = created }
            } catch {
                await fail(id, error: error)
            }
        }
        // A session that stayed but changed hands. Control is flipped on the
        // live session now, so this is the ordinary way somebody starts
        // driving, not a rare case: without it the picture rate would stay at
        // the watching pace for the whole session.
        for session in sessions where !added.contains(session.id) {
            await encoder(for: session.id)?.setControl(session.control)
            // The viewer can change what it is willing to spend without
            // reopening the stream, same as it can take the mouse.
            await encoder(for: session.id)?.setProfile(session.profile)
        }
        // Nobody is driving any more, either because the session ended or
        // because control went back. A viewer that vanished mid-drag would
        // otherwise leave this Mac with the mouse button still down.
        if !sessions.contains(where: \.control) { ScreenInput.releaseHeld() }
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

    private func fail(_ id: String, error: Error) async {
        _ = try? await Bridge.screenCapturePush(id: id, frame: ScreenWire.error(Data(error.localizedDescription.utf8)))
        await Bridge.screenCaptureClose(id: id)
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
    /// The decoder cannot start without SPS/PPS, which only ride on a
    /// keyframe. The first picture, and the first after a compression
    /// rebuild, must be one even if VideoToolbox would have waited.
    private var forceKey = true
    private(set) var displayID: CGDirectDisplayID?
    /// Whether this session carries mouse and keyboard.
    ///
    /// The only thing it changes is how often a picture is taken. See
    /// `frameRate`.
    private var control = false
    /// What this session may spend, and how widely it may draw.
    ///
    /// Set from the route the viewer reached this machine on, and from the
    /// quality it asked for. Relay until told otherwise, which is what every
    /// session used to be.
    private var profile = ScreenQualityProfile.relay
    /// The adaptive backoff, as a fraction of the profile's width. Congestion
    /// pulls it down and a long clear run puts it back; it is kept here so a
    /// profile change does not lose a backoff that is still warranted.
    private var congestionScale: CGFloat = 1

    init(output: @escaping @Sendable (Data) -> Void) { self.output = output }

    /// Pictures per second.
    ///
    /// The bitrate does not move with it: the cost of a session is the
    /// profile's budget, and this decides how finely that budget is spread
    /// over time. Spending the same budget on half as many pictures makes each
    /// of them better, which is the right trade for watching and the wrong one
    /// for driving.
    private var frameRate: Int32 { control ? profile.controlFPS : profile.viewingFPS }

    /// The width to encode at, after the profile's cap and any backoff.
    private var targetWidth: CGFloat {
        guard sourceWidth > 0 else { return profile.maxWidth }
        return min(CGFloat(sourceWidth), profile.maxWidth) * congestionScale
    }

    func start(
        displayID requestedID: CGDirectDisplayID? = nil,
        control: Bool? = nil,
        profile: ScreenQualityProfile? = nil
    ) async throws {
        if let control { self.control = control }
        if let profile { self.profile = profile }
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
        sourceWidth = display.width
        sourceHeight = display.height
        let scale = min(1, targetWidth / CGFloat(display.width))
        width = Int32(max(2, Int(CGFloat(display.width) * scale) & ~1))
        height = Int32(max(2, Int(CGFloat(display.height) * scale) & ~1))

        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = Int(height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        configuration = config

        forceKey = true
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
        forceKey = true
    }

    /// Follow a session that was handed the mouse, or had it taken back.
    ///
    /// Control is no longer fixed when a session opens: the viewer flips it on
    /// the live session rather than reopening the stream. The only thing that
    /// changes here is the picture rate, so the stream is reconfigured in
    /// place instead of being torn down.
    func setControl(_ wanted: Bool) async {
        guard wanted != control else { return }
        control = wanted
        guard let stream, let config = configuration else { return }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        try? await stream.updateConfiguration(config)
    }

    /// Back off, or come back, under congestion.
    ///
    /// A fraction of the profile rather than of a fixed 1920, so a direct
    /// route that turns out to be a poor Wi-Fi link still narrows and a relay
    /// session behaves exactly as it did.
    func setQuality(_ quality: CGFloat) async {
        guard congestionScale != quality else { return }
        congestionScale = quality
        await reconfigure()
    }

    /// Move to a different budget on a session that is already running.
    ///
    /// The same road `setQuality` takes, because the picture must not stop:
    /// reconfigure the stream, then rebuild the compression session with a
    /// keyframe forced, since the decoder cannot start again without SPS/PPS.
    func setProfile(_ next: ScreenQualityProfile) async {
        guard next != profile else { return }
        profile = next
        await reconfigure()
    }

    private func reconfigure() async {
        guard let stream, let config = configuration, sourceWidth > 0 else { return }
        let scale = min(1, targetWidth / CGFloat(sourceWidth))
        let newWidth = Int32(max(2, Int(CGFloat(sourceWidth) * scale) & ~1))
        let newHeight = Int32(max(2, Int(CGFloat(sourceHeight) * scale) & ~1))
        config.width = Int(newWidth)
        config.height = Int(newHeight)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        do {
            try await stream.updateConfiguration(config)
            queue.sync {
                if let compression { VTCompressionSessionInvalidate(compression) }
                compression = nil; width = newWidth; height = newHeight
                forceKey = true
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
        // 1.5 Mbps, not 4.
        //
        // Four megabits is a number for a screen recording somebody keeps.
        // This is a desktop being watched live, usually on a phone, over a
        // relay somebody pays for by the gigabyte: four megabits is 1.8 GB an
        // hour, and the difference on a screen that is mostly text and flat
        // panels is not something a person notices on a handset.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: profile.averageBitRate as CFNumber)
        // A ceiling as well as an average, so a burst of motion cannot spend a
        // minute's budget in a second. The pair is bytes-per-window: 2x the
        // average over one second.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: [profile.averageBitRate / 4, 1] as CFArray
        )
        // Every four seconds rather than every two. A keyframe is the
        // expensive frame, and on a desktop that is not moving it is the only
        // traffic there is: halving how often one goes out halves the cost of
        // a session nobody is touching.
        //
        // In seconds, not in frames. A count of frames would have made a
        // control session's keyframes twice as frequent as a viewing one's
        // purely because it takes twice as many pictures, which is the one
        // way raising the frame rate could have cost real money.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: profile.keyframeSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameRate * profile.keyframeSeconds) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
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
        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: image,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    /// Whether this encoded sample can start a decoder on its own.
    ///
    /// `NotSync` missing means it is a sync sample. `NotSync` present and
    /// false means the same thing: VideoToolbox does write the key as false
    /// on IDR frames. Treating "key exists" as "not a keyframe" dropped
    /// SPS/PPS from every picture, so the viewer decoded nothing and showed
    /// a black screen while mouse and keyboard still arrived on a side
    /// channel.
    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        guard let value = attachments?.first?[kCMSampleAttachmentKey_NotSync] else { return true }
        if let flag = value as? Bool { return !flag }
        if let number = value as? NSNumber { return !number.boolValue }
        return true
    }

    private func encoded(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let keyframe = isKeyframe(sample)
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
        if keyframe { forceKey = false }
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
    static func error(_ payload: Data) -> Data {
        frame(kind: 6, sequence: 0, timestamp: 0, width: 0, height: 0, independent: true, payload: payload)
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
    /// Which buttons the far end is currently holding down.
    ///
    /// macOS does not infer a drag from a move that happens to arrive between
    /// a press and a release: an application is told about a drag by
    /// `leftMouseDragged`, and gets `mouseMoved` for a pointer that is merely
    /// travelling. Posting the wrong one is why a dragged window sat still and
    /// then jumped to its new place on release, and why dragging to select
    /// text selected nothing.
    ///
    /// Read and written on the capture helper's poll, which is one task, so a
    /// plain box is enough.
    nonisolated(unsafe) private static var held: Set<CGMouseButton> = []

    /// The drag event for a button that is down, or a plain move.
    private static func moveType() -> (CGEventType, CGMouseButton) {
        if held.contains(.left) { return (.leftMouseDragged, .left) }
        if held.contains(.right) { return (.rightMouseDragged, .right) }
        if held.contains(.center) { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    /// Put the pointer somewhere, as a drag when a button is held.
    private static func postMove(_ source: CGEventSource?, to point: CGPoint) {
        let (type, button) = moveType()
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    /// Forget every held button. Called when a session ends or hands control
    /// back, so a viewer that vanished mid-drag cannot leave this Mac
    /// believing the mouse is still down.
    static func releaseHeld() {
        guard !held.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let point = CGEvent(source: nil)?.location ?? .zero
        for button in held {
            let type: CGEventType = button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
        held.removeAll()
    }

    struct Event: Decodable {
        var type: String
        var x: Double?
        var y: Double?
        var id: UInt32?
        var button: Int?
        var down: Bool?
        var keyCode: UInt16?
        var flags: UInt64?
        var text: String?
        /// Wheel movement in pixels. A phone sends these from a two-finger
        /// drag, which has no notion of a wheel detent.
        var dx: Double?
        var dy: Double?
        /// 1 for a click, 2 for a double click. macOS decides what a double
        /// click means from this field, not from the gap between two events,
        /// so a touch client has to say it out loud.
        var clickCount: Int?
    }
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
            postMove(source, to: point)
            let down = event.down == true
            if down { held.insert(.left) } else { held.remove(.left) }
            cg = CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        // A move while a button is held is a drag, and has to be posted as
        // one. See `held`.
        case "move":
            let (type, button) = moveType()
            cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        case "mouse":
            let button = CGMouseButton(rawValue: UInt32(event.button ?? 0)) ?? .left
            let down = event.down == true
            let type: CGEventType = down ? (button == .right ? .rightMouseDown : .leftMouseDown) : (button == .right ? .rightMouseUp : .leftMouseUp)
            if down { held.insert(button) } else { held.remove(button) }
            cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        // Press and release in one message, with the click count the caller
        // means. A touch client cannot rely on two separate messages arriving
        // close enough together for macOS to read them as a double click.
        case "click":
            let button = CGMouseButton(rawValue: UInt32(event.button ?? 0)) ?? .left
            let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
            // One pair, carrying the count. macOS reads the click count off the
            // event rather than timing the events, so posting the pair once per
            // click would make a double click arrive as three clicks: the first
            // click of the pair has already been sent as its own press.
            let clicks = max(1, min(3, event.clickCount ?? 1))
            postMove(source, to: point)
            for type in [downType, upType] {
                let click = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                click?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
                if let flags = event.flags { click?.flags = CGEventFlags(rawValue: flags) }
                click?.post(tap: .cghidEventTap)
            }
            return
        // Two-finger scrolling. Pixel units rather than lines, so the distance
        // a finger travelled is the distance the content moves.
        case "scroll":
            postMove(source, to: point)
            cg = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(event.dy ?? 0)),
                wheel2: Int32(clamping: Int(event.dx ?? 0)),
                wheel3: 0
            )
        case "key": cg = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode ?? 0, keyDown: event.down == true)
        case "text":
            guard let text = event.text else { return }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
            if let flags = event.flags { down?.flags = CGEventFlags(rawValue: flags) }
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
