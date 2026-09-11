// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatTurnTiming.swift using swiftc -parse-as-library, then run.
import Foundation

@main
struct ChatTurnTimingTests {
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: Int) -> Date { start.addingTimeInterval(TimeInterval(seconds)) }

        require(TurnElapsed.phrase(since: start, now: at(0)) == "0s", "zero reads 0s")
        require(TurnElapsed.phrase(since: start, now: at(10)) == "10s", "seconds read Ns")
        require(TurnElapsed.phrase(since: start, now: at(59)) == "59s", "59 seconds is not a minute")
        require(TurnElapsed.phrase(since: start, now: at(60)) == "1m", "60 seconds reads 1m")
        require(TurnElapsed.phrase(since: start, now: at(119)) == "1m", "minutes floor")
        require(TurnElapsed.phrase(since: start, now: at(180)) == "3m", "three minutes reads 3m")
        require(TurnElapsed.phrase(since: start, now: at(3599)) == "59m", "59 minutes is not an hour")
        require(TurnElapsed.phrase(since: start, now: at(3600)) == "1h", "exact hour has no zero minutes")
        require(TurnElapsed.phrase(since: start, now: at(3900)) == "1h 5m", "hours carry leftover minutes")
        require(TurnElapsed.phrase(since: start, now: at(7200)) == "2h", "exact hours read Nh")
        require(TurnElapsed.phrase(since: at(10), now: start) == "0s", "the future reads 0s, never negative")

        require(TurnElapsed.durationWords(since: start, now: at(1)) == "1 second", "singular second")
        require(TurnElapsed.durationWords(since: start, now: at(10)) == "10 seconds", "plural seconds")
        require(TurnElapsed.durationWords(since: start, now: at(60)) == "1 minute", "singular minute")
        require(TurnElapsed.durationWords(since: start, now: at(180)) == "3 minutes", "plural minutes")
        require(TurnElapsed.durationWords(since: start, now: at(3600)) == "1 hour", "singular hour")
        require(TurnElapsed.durationWords(since: start, now: at(3900)) == "1 hour 5 minutes", "hours carry minutes aloud")

        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let t1 = t0.addingTimeInterval(30)
        var stamps = reconcileRunningSince([:], running: ["a"], now: t0)
        require(stamps == ["a": t0], "a newly running conversation is stamped with now")
        stamps = reconcileRunningSince(stamps, running: ["a", "b"], now: t1)
        require(stamps["a"] == t0, "a continuing turn keeps its original stamp")
        require(stamps["b"] == t1, "a newly running conversation is stamped while the old one keeps ticking")
        stamps = reconcileRunningSince(stamps, running: ["b"], now: t1)
        require(stamps["a"] == nil && stamps["b"] == t1, "a stopped turn leaves no stamp")
        stamps = reconcileRunningSince(["gone": t0], running: [], now: t1)
        require(stamps.isEmpty, "an unknown id is not kept")
        print("ChatTurnTimingTests passed.")
    }
}
