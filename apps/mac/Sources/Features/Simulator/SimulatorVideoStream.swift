// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import AVFoundation
import VideoToolbox
import Darwin

/// Incremental Annex B framing tolerates start codes split across pipe reads.
struct SimulatorAnnexBReader {
    private var buffer = Data()
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { buffer.removeAll(); return [] }
        let bytes = [UInt8](buffer)
        var marks: [(Int, Int)] = []
        var offset = 0
        while offset + 3 <= bytes.count {
            if bytes[offset] == 0 && bytes[offset + 1] == 0 {
                if bytes[offset + 2] == 1 { marks.append((offset, 3)); offset += 3; continue }
                if offset + 4 <= bytes.count && bytes[offset + 2] == 0 && bytes[offset + 3] == 1 {
                    marks.append((offset, 4)); offset += 4; continue
                }
            }
            offset += 1
        }
        guard marks.count > 1, let last = marks.last else { return [] }
        let result = (0..<(marks.count - 1)).compactMap { index -> Data? in
            let start = marks[index].0 + marks[index].1, end = marks[index + 1].0
            return start < end ? Data(bytes[start..<end]) : nil
        }
        buffer = Data(bytes[last.0...])
        return result
    }

    /// Local screenrecord writes can pause indefinitely after a still frame.
    /// Finish its last NAL at a quiet boundary instead of waiting for another
    /// frame's start code. A later chunk starts a fresh access unit.
    mutating func drain() -> [Data] {
        defer { buffer.removeAll(keepingCapacity: true) }
        return append(Data([0, 0, 1]))
    }
}

@MainActor
final class SimulatorVideoDecoder {
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var picture: [Data] = []
    private var decompression: VTDecompressionSession?
    private let output = Output()
    private var generation = UUID()
    private let frameCapacity = DispatchSemaphore(value: 2)
    var onFrame: ((CVPixelBuffer) -> Void)?
    private final class Output: @unchecked Sendable {
        var receive: (@Sendable (CVPixelBuffer) -> Void)?
    }
    /// The decoder has finished writing this retained buffer before delivery.
    private struct DecodedPixels: @unchecked Sendable { let value: CVPixelBuffer }
    init() { configureOutput() }
    private func configureOutput() {
        let lease = generation, capacity = frameCapacity
        output.receive = { [weak self] pixels in
            guard capacity.wait(timeout: .now()) == .success else { return }
            let retained = DecodedPixels(value: pixels)
            DispatchQueue.main.async { [weak self] in
                defer { capacity.signal() }
                guard let self, self.generation == lease else { return }
                self.onFrame?(retained.value)
            }
        }
    }
    func reset() {
        if let decompression {
            VTDecompressionSessionWaitForAsynchronousFrames(decompression)
            VTDecompressionSessionInvalidate(decompression)
        }
        decompression = nil; format = nil; sps = nil; pps = nil; picture.removeAll()
        generation = UUID(); configureOutput()
    }
    deinit {
        if let decompression {
            VTDecompressionSessionWaitForAsynchronousFrames(decompression)
            VTDecompressionSessionInvalidate(decompression)
        }
    }

    func consume(_ unit: Data) {
        guard let first = unit.first else { return }
        let type = first & 31
        if type == 7 || type == 8 || type == 9 { flush() }
        if type == 7 { sps = unit; updateFormat(); return }
        if type == 8 { pps = unit; updateFormat(); return }
        guard (1...5).contains(type) else { return }
        if Self.startsPicture(unit) { flush() }
        picture.append(unit)
    }
    private static func startsPicture(_ unit: Data) -> Bool {
        // first_mb_in_slice is unsigned Exp-Golomb; zero is the leading '1'.
        unit.count > 1 && unit[unit.startIndex + 1] & 0x80 != 0
    }
    private func updateFormat() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { a in pps.withUnsafeBytes { b in
            guard let first = a.baseAddress?.assumingMemoryBound(to: UInt8.self), let second = b.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let pointers = [first, second], sizes = [sps.count, pps.count]
            _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } }
        if let decompression {
            VTDecompressionSessionWaitForAsynchronousFrames(decompression)
            VTDecompressionSessionInvalidate(decompression)
        }
        decompression = nil
        guard let format else { return }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            guard status == noErr, let context, let image else { return }
            Unmanaged<Output>.fromOpaque(context).takeUnretainedValue().receive?(image)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        _ = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decompression)
    }

    func finishPicture() { flush() }
    private func flush() {
        defer { picture.removeAll(keepingCapacity: true) }
        guard let format, !picture.isEmpty else { return }
        var avcc = Data()
        for unit in picture {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        avcc.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { _ = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        }
        var sample: CMSampleBuffer?, size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let decompression {
            _ = VTDecompressionSessionDecodeFrame(decompression, sampleBuffer: sample,
                flags: ._EnableAsynchronousDecompression, frameRefcon: nil, infoFlagsOut: nil)
        }
    }
}

/// Android's screenrecord supplies an H.264 pipe, decoded by native media
/// layers. Hiding the inspector closes the pipe; the emulator remains running.
@MainActor
final class AndroidSimulatorStream {
    private var process: Process?
    private var pipe: Pipe?
    private var lease = UUID()
    private let decoder = SimulatorVideoDecoder()
    private let readQueue = DispatchQueue(label: "ai.tokenstat.simulator.android-video", qos: .userInitiated)
    private let deliveryCapacity = DispatchSemaphore(value: 3)
    private var receivedFrame = false
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?
    func start(tools: AndroidSimulatorTools, serial: String, pixels: CGSize, transportID: UInt64? = nil) {
        stop()
        let lease = UUID(); self.lease = lease
        receivedFrame = false
        decoder.onFrame = { [weak self] pixels in
            guard let self, self.lease == lease else { return }
            self.receivedFrame = true
            self.onFrame?(pixels)
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tools.adb)
        let scale = min(1, 1280 / max(pixels.width, pixels.height))
        let width = max(16, Int(pixels.width * scale) / 2 * 2), height = max(16, Int(pixels.height * scale) / 2 * 2)
        // Shell v2 without a PTY keeps binary stdout intact and terminates
        // the remote recording when the client disconnects. exec-out can
        // leave a still recording running until its time limit.
        process.arguments = AndroidSimulatorTools.targetArguments(serial, transportID: transportID) + ["shell", "-T", "screenrecord", "--output-format=h264", "--bit-rate", "6000000", "--size", "\(width)x\(height)", "--time-limit", "180", "-"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.lease == lease else { return }
                if finished.terminationStatus == 0 { self.start(tools: tools, serial: serial, pixels: pixels, transportID: transportID) }
                else { self.onError?(L10n.text("apple.simulator.android_stream_error")) }
            }
        }
        do { try process.run() } catch { onError?(error.localizedDescription); return }
        self.process = process; self.pipe = pipe
        let deliveryCapacity = deliveryCapacity
        let deliver: @Sendable ([Data], Bool) -> Void = { [weak self] units, finishedPicture in
            deliveryCapacity.wait()
            DispatchQueue.main.async { [weak self] in
                defer { deliveryCapacity.signal() }
                guard let self, self.lease == lease else { return }
                units.forEach { self.decoder.consume($0) }
                if finishedPicture { self.decoder.finishPicture() }
            }
        }
        readQueue.async {
            // Foundation's sized read may wait for the requested byte count.
            // A still screen can stay below it indefinitely; consume each
            // available pipe fragment with one unbuffered read instead.
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            defer { try? pipe.fileHandleForReading.close() }
            var bytes = [UInt8](repeating: 0, count: 65536)
            var reader = SimulatorAnnexBReader()
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while true {
                // Flush a still frame only after the reader has caught up.
                // A timer on another queue can cut a NAL while unread bytes
                // remain in the pipe during decoder backpressure.
                let ready = Darwin.poll(&readiness, 1, 120)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { break }
                if ready == 0 {
                    let units = reader.drain()
                    if !units.isEmpty { deliver(units, true) }
                    continue
                }
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let units = reader.append(Data(bytes.prefix(count)))
                if !units.isEmpty { deliver(units, false) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.lease == lease, !self.receivedFrame else { return }
            self.onError?(L10n.text("apple.simulator.android_stream_error")); self.stop()
        }
    }
    func stop() {
        lease = UUID(); decoder.reset()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        process = nil; pipe = nil
    }
    deinit { if process?.isRunning == true { process?.terminate() } }
}
#endif
