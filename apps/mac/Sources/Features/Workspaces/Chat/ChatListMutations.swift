// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// A read started before a completed mutation cannot undo it. Reads started
/// afterwards remain authoritative, including later edits from another device.
@MainActor
final class ChatListMutations<Item: Identifiable> where Item.ID == String {
    struct Read { let owner: String; let revision: UInt64; let order: UInt64 }
    private struct Change { let revision: UInt64; let item: Item? }
    private var revision: UInt64 = 0
    private var changes: [String: [String: Change]] = [:]
    private var readOrder: UInt64 = 0
    private var accepted: [String: UInt64] = [:]

    func beginRead(owner: String) -> Read {
        readOrder &+= 1
        return Read(owner: owner, revision: revision, order: readOrder)
    }
    func replace(_ item: Item, owner: String) {
        revision &+= 1
        changes[owner, default: [:]][item.id] = Change(revision: revision, item: item)
    }
    func remove(_ id: String, owner: String) {
        revision &+= 1
        changes[owner, default: [:]][id] = Change(revision: revision, item: nil)
    }
    func apply(_ incoming: [Item], read: Read, current: [Item]) -> [Item] {
        guard read.order >= accepted[read.owner, default: 0] else { return current }
        accepted[read.owner] = read.order
        guard let edits = changes[read.owner] else { return incoming }
        let newer = edits.filter { $0.value.revision > read.revision }
        guard !newer.isEmpty else { return incoming }
        var seen = Set<String>()
        var rows = incoming.compactMap { item -> Item? in
            guard seen.insert(item.id).inserted else { return nil }
            if let change = newer[item.id] { return change.item }
            return item
        }
        for (id, change) in newer.sorted(by: { $0.value.revision < $1.value.revision }) {
            if !seen.contains(id), let item = change.item { rows.append(item) }
        }
        return rows
    }
    func removeAll() { revision &+= 1; changes = [:]; accepted = [:] }
}
