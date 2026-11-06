// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// A newly opened view starts settled. Only appended words receive timestamps;
/// replacing or shortening a snapshot resets the baseline without replaying it.
final class StreamingWordArrivals {
    private var identity: String?
    private var source: String?
    private var count = 0
    private var arrivals: [Int: TimeInterval] = [:]
    static let duration: TimeInterval = 0.22

    func update(source: String, count: Int, now: TimeInterval, animate: Bool = true, identity: String = "") -> [Int: TimeInterval] {
        if self.identity != identity {
            self.identity = identity
            self.source = nil
            self.count = 0
            arrivals.removeAll()
        }
        arrivals = arrivals.filter { now - $0.value < Self.duration }
        // Redraws of identical text can skip both prefix checks. Comparing
        // bytes avoids an extra normalization pass for rewritten Unicode text.
        if count == self.count, hasSameBytes(as: source) {
            if !animate { arrivals.removeAll() }
            self.source = source
            return arrivals
        }
        if let previous = self.source, previous.hasPrefix(source), source != previous {
            // A reconnect may briefly show an earlier snapshot. Keep the
            // high-water mark so restoring its text cannot replay old words.
            arrivals.removeAll()
            return arrivals
        }
        let appends = self.source.map { source.hasPrefix($0) } ?? false
        if animate, appends, count >= self.count {
            for index in self.count..<count { arrivals[index] = now }
        } else {
            arrivals.removeAll()
        }
        self.source = source
        self.count = appends ? max(self.count, count) : count
        return arrivals
    }

    private func hasSameBytes(as source: String) -> Bool {
        guard let previous = self.source else { return false }
        return source.utf8.withContiguousStorageIfAvailable { current in
            previous.utf8.withContiguousStorageIfAvailable { old in
                guard current.count == old.count else { return false }
                if current.isEmpty || current.baseAddress == old.baseAddress { return true }
                guard let lhs = current.baseAddress, let rhs = old.baseAddress else { return false }
                return memcmp(lhs, rhs, current.count) == 0
            } ?? false
        } ?? false
    }
}

/// Reuse the active word range across every text chunk in one render.
struct StreamingWordWindow {
    private let arrivals: [Int: TimeInterval]
    private let first: Int
    private let last: Int

    init(_ arrivals: [Int: TimeInterval]) {
        self.arrivals = arrivals
        var first = Int.max
        var last = Int.min
        for word in arrivals.keys {
            first = min(first, word)
            last = max(last, word)
        }
        self.first = first
        self.last = last
    }

    func words(in range: Range<Int>) -> [Int: TimeInterval] {
        guard !arrivals.isEmpty, !range.isEmpty,
              range.upperBound > first, range.lowerBound <= last else { return [:] }
        if range.lowerBound <= first, range.upperBound > last { return arrivals }
        return arrivals.filter { range.contains($0.key) }
    }
}
