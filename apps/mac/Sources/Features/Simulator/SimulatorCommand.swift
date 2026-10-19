// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

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
            let out = Reader(), err = Reader(), stdin = Pipe()
            process.standardOutput = out.pipe; process.standardError = err.pipe
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            let deadline = DispatchWorkItem { [self] in
                lock.lock()
                if process.isRunning { timedOut = true; process.terminate() }
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                    lock.lock(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; lock.unlock()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            DispatchQueue.concurrentPerform(iterations: 3) { index in
                if index == 0 { out.read() }
                else if index == 1 { err.read() }
                else {
                    if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                    try? stdin.fileHandleForWriting.close()
                }
            }
            process.waitUntilExit(); deadline.cancel()
            lock.lock(); let expired = timedOut, stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
            if expired { throw Failure(message: L10n.text("apple.simulator.timeout")) }
            guard !out.overflow else { throw Failure(message: L10n.text("apple.simulator.output_limit")) }
            return Result(data: out.data, errors: String(decoding: err.data, as: UTF8.self), status: process.terminationStatus)
        }
    }
    private final class Reader: @unchecked Sendable {
        let pipe = Pipe()
        var data = Data()
        var overflow = false
        func read() {
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                if data.count + chunk.count <= 64 * 1024 * 1024 { data.append(chunk) }
                else { overflow = true }
            }
        }
    }
}
#endif
