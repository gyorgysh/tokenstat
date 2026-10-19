// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with SimulatorCommand.swift using swiftc -parse-as-library, then run.
import Foundation

@main struct SimulatorCommandTests {
    static func main() async throws {
        do {
            _ = try await SimulatorCommand.developerDirectory(selection: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
            preconditionFailure("A missing Xcode selection must not fall back to xcrun or open an installer")
        } catch is SimulatorCommand.Failure { }
        let value = try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import sys;sys.stdout.buffer.write(bytes(range(256))*1024);sys.stderr.write('e'*200000)"])
        precondition(value.status == 0 && value.data.count == 262144 && value.errors.count == 200000)
        let failed = try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import sys;sys.stderr.write('actual error');sys.exit(7)"])
        precondition(failed.status == 7 && failed.errors == "actual error")
        let argument = "literal $(touch never); `echo no`"
        let exact = try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import sys;print(sys.argv[1],end='')", argument])
        precondition(String(decoding: exact.data, as: UTF8.self) == argument)
        let input = Data("a clipboard with\nnewlines and Unicode: 世界".utf8)
        let echoed = try await SimulatorCommand.run("/bin/cat", [], input: input)
        precondition(echoed.data == input)
        let ignored = try await SimulatorCommand.run("/usr/bin/true", [], input: Data(repeating: 1, count: 1_000_000))
        precondition(ignored.status == 0, "A closed stdin must not deliver SIGPIPE to the app")
        for input: Data? in [nil, Data(repeating: 1, count: 1_000_000)] {
            let inherited = Date()
            do {
                _ = try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import subprocess;subprocess.Popen(['/bin/sleep','5'])"], timeout: 0.2, input: input)
                preconditionFailure("A descendant holding pipes bypassed the timeout")
            } catch { precondition(Date().timeIntervalSince(inherited) < 3, "Inherited pipes blocked the command deadline") }
        }
        let inheritedCancellation = Task {
            try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import subprocess;subprocess.Popen(['/bin/sleep','5'])"], input: Data(repeating: 1, count: 1_000_000))
        }
        try await Task.sleep(for: .milliseconds(300))
        let inheritedCancelBegan = Date(); inheritedCancellation.cancel()
        do { _ = try await inheritedCancellation.value; preconditionFailure("Inherited pipes ignored cancellation") }
        catch is CancellationError { precondition(Date().timeIntervalSince(inheritedCancelBegan) < 3) }
        let began = Date()
        do {
            _ = try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(20)"], timeout: 0.1)
            preconditionFailure("Timed-out process reported success")
        } catch { precondition(Date().timeIntervalSince(began) < 4) }
        let job = Task { try await SimulatorCommand.run("/bin/sleep", ["20"]) }
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        do { _ = try await job.value; preconditionFailure("Cancelled process reported success") }
        catch is CancellationError { }
        let stubborn = Task { try await SimulatorCommand.run("/usr/bin/python3", ["-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(20)"]) }
        try await Task.sleep(for: .milliseconds(200))
        let cancelBegan = Date(); stubborn.cancel()
        do { _ = try await stubborn.value; preconditionFailure("Stubborn cancelled process survived") }
        catch is CancellationError { precondition(Date().timeIntervalSince(cancelBegan) < 4) }
        print("PASS: simulator process drains, binary data, stdin, exact arguments, exit status, timeout and cancellation")
    }
}
