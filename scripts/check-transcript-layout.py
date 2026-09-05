#!/usr/bin/env python3
"""Check transcript follow and deferred scrolling using the production Swift types.

Run on macOS with the Swift toolchain. No app, host daemon, or signing needed.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "apps/mac/Sources/Features/Workspaces/Chat/TranscriptFollow.swift").read_text()
metrics = source[source.index("struct TranscriptMetrics:"):source.index("@available(macOS 15.0")]
follow = source[source.index("@Observable\nfinal class TranscriptFollowState"):source.index("struct ChatScrollContentKey:")]
delivery = source[source.index("final class TranscriptScrollDelivery"):source.index("/// Report where the transcript is scrolled,")]
tests = r'''
func metrics(_ top: CGFloat, _ height: CGFloat = 1000) -> TranscriptMetrics {
    TranscriptMetrics(distanceFromTop: top, distanceFromBottom: height - top - 400,
                      contentHeight: height, viewportHeight: 400)
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
let delivery = TranscriptScrollDelivery()
var received: [Int] = []
for value in 0..<100 { delivery.submit { received.append(value) } }
assert(received.isEmpty, "must not scroll inside the geometry callback")
drain()
assert(received == [99], "only the newest pending correction should execute")
var depth = 0
var maxDepth = 0
func receive(_ value: Int) {
    depth += 1
    maxDepth = max(depth, maxDepth)
    received.append(value)
    if value == 100 { delivery.submit { receive(101) } }
    depth -= 1
}
delivery.submit { receive(100) }
drain()
assert(received == [99, 100, 101] && maxDepth == 1, "corrections must not re-enter layout")
delivery.submit { receive(102) }
delivery.cancel()
drain()
assert(received == [99, 100, 101], "cancelled corrections must not execute")
delivery.submit { receive(103) }
drain()
assert(received.last == 103, "delivery must work after cancellation")

for driven in [false, true] {
    let state = TranscriptFollowState()
    state.note(metrics(600))
    if driven { state.markDriven() }
    state.note(metrics(500))
    assert(!state.pinned && state.showJump, "one wheel tick must release follow")
}
let growth = TranscriptFollowState()
growth.note(metrics(600))
var repins = 0
growth.repin = { repins += 1; return true }
growth.note(metrics(600, 1100))
assert(growth.pinned && repins == 0, "growth must queue a correction without scrolling inline")
drain()
assert(repins == 1, "stationary growth must still follow")

let departed = TranscriptFollowState()
departed.note(metrics(600))
var unwanted = 0
departed.repin = { unwanted += 1; return true }
departed.note(metrics(600, 1100))
departed.note(metrics(500, 1100))
assert(!departed.pinned, "user motion must be tracked before deferred corrections execute")
drain()
assert(unwanted == 0, "a queued correction must not pull back a reader who left")

let paused = TranscriptFollowState()
paused.note(metrics(600))
paused.repin = { unwanted += 1; return true }
paused.note(metrics(600, 1100))
paused.pause()
drain()
assert(unwanted == 0, "pause must cancel pending corrections")

let estimate = TranscriptFollowState()
estimate.note(metrics(600))
estimate.note(metrics(500, 1100))
assert(estimate.pinned, "a single lazy-height correction must not release follow")
print("PASS: deferred/coalesced corrections, no re-entry, cancellation, wheel gestures, growth, departure, pause, estimate resizing")
'''
with tempfile.TemporaryDirectory(prefix="tokenstat-layout-test-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text("import Foundation\nimport Observation\nenum TranscriptFollow { static let threshold: CGFloat = 56 }\n" + metrics + delivery + follow + tests)
    subprocess.run(["swift", str(path)], check=True)
