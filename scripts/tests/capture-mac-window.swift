// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Capture the running Debug photo app through its native snapshot hook.
// Compile: swiftc scripts/tests/capture-mac-window.swift -o target/product-photos/capture-window
import Foundation
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: capture-window <output.png>\n", stderr)
    exit(2)
}
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
let before = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("ai.tokenstat.debug.snapshot"), object: path, userInfo: nil, deliverImmediately: true)
let deadline = Date(timeIntervalSinceNow: 20)
var saved = false
while Date() < deadline {
    if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
       before == nil || modified > before! {
        saved = true
        break
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}
if !saved {
    fputs("The native photo app did not write a fresh capture.\n", stderr)
    exit(1)
}
print(path)
