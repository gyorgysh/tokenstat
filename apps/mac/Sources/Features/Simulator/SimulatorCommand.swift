// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation
import Darwin

/// A bounded, binary-safe tool invocation. Each stream drains independently.
enum SimulatorCommand {
    struct Result: Sendable { let data: Data; let errors: String; let status: Int32 }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20, input: Data? = nil) async throws -> Result {
        let job = Job(executable, arguments, timeout: timeout, input: input)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await Task.detached(priority: .userInitiated) { try job.run() }.value
            try Task.checkCancellation()
            return value
        } onCancel: { job.cancel() }
    }

    static func simctl(_ arguments: [String], timeout: TimeInterval = 20, input: Data? = nil) async throws -> Data {
        let value = try await run("/usr/bin/xcrun", ["simctl"] + arguments, timeout: timeout, input: input)
        guard value.status == 0 else {
            throw Failure(message: value.errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return value.data
    }

    /// simctl versions differ in stdout support. A private, disposable file
    /// works with both current and older Xcode without depending on the app's cwd.
    static func screenshot(deviceID: String, displayID: UInt32) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-simulator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("screen.png")
        _ = try await simctl(["io", deviceID, "screenshot", "--display=\(displayID)", "--type=png", file.path])
        try Task.checkCancellation()
        return try Data(contentsOf: file)
    }

    static func developerDirectory() async throws -> String {
        let tool = try await run("/usr/bin/xcrun", ["--find", "simctl"])
        guard tool.status == 0 else { throw Failure(message: tool.errors) }
        let path = String(decoding: tool.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    private final class Job: @unchecked Sendable {
        let process = Process()
        let timeout: TimeInterval
        let input: Data?
        let lock = NSLock()
        var cancelled = false
        var timedOut = false
        var finished = false
        init(_ executable: String, _ arguments: [String], timeout: TimeInterval, input: Data?) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            self.timeout = timeout; self.input = input
        }
        func cancel() {
            lock.lock(); cancelled = true
            if process.isRunning { process.terminate() }
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; lock.unlock()
            }
        }
        func run() throws -> Result {
            let out = PipeIO(), err = PipeIO(), stdin = PipeIO()
            process.standardOutput = out.pipe; process.standardError = err.pipe
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin.pipe
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            let deadline = DispatchWorkItem { [self] in
                lock.lock()
                if !finished { timedOut = true }
                if process.isRunning { process.terminate() }
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    lock.lock(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; lock.unlock()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                if index == 0 { out.read(until: isStopped) }
                else if index == 1 { err.read(until: isStopped) }
                else { stdin.write(input, until: isStopped) }
            }
            process.waitUntilExit(); deadline.cancel()
            lock.lock(); finished = true; let expired = timedOut, stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
            if expired { throw Failure(message: L10n.text("apple.simulator.timeout")) }
            if let error = out.error ?? err.error ?? stdin.error { throw error }
            guard !out.overflow else { throw Failure(message: L10n.text("apple.simulator.output_limit")) }
            return Result(data: out.data, errors: String(decoding: err.data, as: UTF8.self), status: process.terminationStatus)
        }
        private func isStopped() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled || timedOut
        }
    }
    /// A descendant may keep a pipe open after its parent exits. Poll all
    /// three streams so the job's deadline also bounds draining and stdin.
    private final class PipeIO: @unchecked Sendable {
        let pipe = Pipe()
        var data = Data()
        var overflow = false
        var error: Error?
        private func nonblocking(_ fd: Int32) -> Bool {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); return false
            }
            return true
        }
        private func ready(_ fd: Int32, event: Int16, until stopped: () -> Bool) -> Bool {
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            while !stopped() {
                let result = poll(&descriptor, 1, 100)
                if result > 0 { return true }
                if result < 0 && errno != EINTR {
                    error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); return false
                }
            }
            return false
        }
        func read(until stopped: () -> Bool) {
            let handle = pipe.fileHandleForReading, fd = handle.fileDescriptor
            defer { try? handle.close() }
            guard nonblocking(fd) else { return }
            var bytes = [UInt8](repeating: 0, count: 65536)
            while ready(fd, event: Int16(POLLIN), until: stopped) {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard count > 0 else {
                    if count < 0 { error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    return
                }
                if data.count + count <= 64 * 1024 * 1024 { data.append(contentsOf: bytes.prefix(count)) }
                else { overflow = true }
            }
        }
        func write(_ input: Data?, until stopped: () -> Bool) {
            let handle = pipe.fileHandleForWriting, fd = handle.fileDescriptor
            defer { try? handle.close() }
            guard let input, nonblocking(fd) else { return }
            guard fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else {
                error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)); return
            }
            input.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count && ready(fd, event: Int16(POLLOUT), until: stopped) {
                    let count = Darwin.write(fd, base.advanced(by: offset), min(65536, bytes.count - offset))
                    if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                    guard count > 0 else {
                        if count < 0 && errno != EPIPE { error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                        return
                    }
                    offset += count
                }
            }
        }
    }
}
#endif
