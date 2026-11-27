// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

enum ChatHistoryWindow {
    static let collapsedLimit = 5
    static let inlineLimit = 10

    static func previews<Item>(in items: [Item], limit: Int, isSelected: (Item) -> Bool) -> [Item] {
        items.prefix(max(0, limit)).filter { !isSelected($0) }
    }

    static func visible(count: Int, selected: Int?, expanded: Bool) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        if let s = selected, s >= 0, s < count, expanded || s >= collapsedLimit {
            if count <= inlineLimit { return 0..<count }
            if s < inlineLimit { return 0..<inlineLimit }
            let start = min(s - 4, count - inlineLimit)
            return start..<(start + inlineLimit)
        }
        if expanded { return 0..<min(count, inlineLimit) }
        return 0..<min(count, collapsedLimit)
    }

    static func looped(count: Int, current: Int?, step: Int) -> Int? {
        let bound = min(count, inlineLimit)
        guard bound > 0, step == -1 || step == 1 else { return nil }
        guard let current, current >= 0, current < bound else {
            return step > 0 ? 0 : bound - 1
        }
        return (current + step + bound) % bound
    }
}
