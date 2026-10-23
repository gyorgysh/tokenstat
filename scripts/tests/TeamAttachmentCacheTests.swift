// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with TeamAttachmentCache.swift.
import Foundation

@main struct TeamAttachmentCacheTests {
    static func main() {
        var cache = TeamAttachmentCache<String>(byteLimit: 10, entryLimit: 2)
        cache.insert("first", id: "one", bytes: 6)
        cache.insert("second", id: "two", bytes: 6)
        precondition(cache["one"] == nil && cache["two"] == "second" && cache.byteCount == 6,
                     "Opening another attachment must evict downloaded bytes over budget")
        cache.insert("replaced", id: "two", bytes: 2)
        cache.insert("empty", id: "three", bytes: 0)
        cache.insert("last", id: "four", bytes: 0)
        precondition(cache["two"] == nil && cache.byteCount == 0,
                     "Zero-byte attachments must still respect the entry bound")
        cache.retain(["four"])
        precondition(cache["three"] == nil && cache["four"] == "last", "A refreshed history must retire invisible files")
        precondition(!cache.insert("oversized", id: "huge", bytes: Int.max))
        precondition(cache["four"] == "last" && cache["huge"] == nil, "An invalid size must not evict valid files")
        for index in 0..<1000 { cache.insert("file", id: "\(index)", bytes: 5) }
        precondition(cache.byteCount == 10 && cache["0"] == nil && cache["999"] != nil,
                     "A long-lived shared reader must not retain its entire attachment history")
        cache.retain([])
        precondition(cache.byteCount == 0)

        let encoded = Data("fixture".utf8).base64EncodedString()
        precondition(TeamAttachmentLimits.decode(encoded, size: 7) == Data("fixture".utf8))
        for size: Int64? in [nil, -1, 0, 8, Int64.max] {
            precondition(TeamAttachmentLimits.decode(encoded, size: size) == nil, "Missing or mismatched attachment size must fail closed")
        }
        precondition(TeamAttachmentLimits.decode("not base64", size: 7) == nil)
        let tooLarge = Data(repeating: 1, count: TeamAttachmentLimits.maximumBytes + 1)
        precondition(TeamAttachmentLimits.decode(tooLarge.base64EncodedString(), size: Int64(tooLarge.count)) == nil)
        print("Team attachment cache and payload bounds passed")
    }
}
