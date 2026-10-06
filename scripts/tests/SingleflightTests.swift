// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with Singleflight.swift using swiftc -parse-as-library, then run.
import Foundation

@MainActor
private final class TestSignal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@main
struct SingleflightTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    @MainActor
    static func main() async {
        let gate = Singleflight<Int>()
        var starts = 0
        var arrivals = 0
        let allArrived = TestSignal()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    arrivals += 1
                    if arrivals == 8 { allArrived.signal() }
                    return await gate.run {
                        starts += 1
                        await allArrived.wait()
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
        let entered = TestSignal()
        let release = TestSignal()
        let slow = Task { @MainActor in
            await flag.run {
                entered.signal()
                await release.wait()
                return 7
            }
        }
        await entered.wait()
        require(flag.isRunning, "running reads true mid-flight")
        release.signal()
        require(await slow.value == 7, "the attempt still answers")
        require(!flag.isRunning, "the slot clears after")
        print("SingleflightTests passed.")
    }
}
