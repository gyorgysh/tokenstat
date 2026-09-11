// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with Singleflight.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct SingleflightTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor
    static func main() async {
        let gate = Singleflight<Int>()
        var starts = 0
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.run {
                        starts += 1
                        try? await Task.sleep(for: .milliseconds(50))
                        return starts
                    }
                }
            }
            var answers: [Int] = []
            for await answer in group {
                answers.append(answer)
            }
            require(answers.count == 8, "every waiter gets an answer")
            require(answers.allSatisfy { $0 == 1 }, "concurrent callers share one attempt")
        }
        require(starts == 1, "the operation ran once, not eight times")

        let second = await gate.run {
            starts += 1
            return starts
        }
        require(second == 2, "a later call runs fresh after the slot clears")
        require(starts == 2, "no stray attempt leaked")

        let flag = Singleflight<Int>()
        require(!flag.isRunning, "idle starts idle")
        async let slow: Int = flag.run {
            try? await Task.sleep(for: .milliseconds(50))
            return 7
        }
        try? await Task.sleep(for: .milliseconds(10))
        require(flag.isRunning, "running reads true mid-flight")
        require(await slow == 7, "the attempt still answers")
        require(!flag.isRunning, "the slot clears after")
        print("SingleflightTests passed.")
    }
}
