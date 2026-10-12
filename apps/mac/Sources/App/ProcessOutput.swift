// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// Drain both output streams while a tool runs. Waiting for exit or reading
/// one pipe to EOF first can deadlock when the other pipe fills.
enum ProcessOutput {
    struct Result {
        let status: Int32
        let output: String
        let errors: String
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let readers = [Reader(), Reader()]
        process.standardOutput = readers[0].pipe
        process.standardError = readers[1].pipe
        try process.run()
        DispatchQueue.concurrentPerform(iterations: readers.count) { readers[$0].read() }
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: readers[0].data, as: UTF8.self),
                      errors: String(decoding: readers[1].data, as: UTF8.self))
    }

    // Each reader is written by exactly one worker. concurrentPerform joins
    // both workers before the caller reads their completed data.
    private final class Reader: @unchecked Sendable {
        let pipe = Pipe()
        private(set) var data = Data()
        func read() { data = pipe.fileHandleForReading.readDataToEndOfFile() }
    }
}
#endif
