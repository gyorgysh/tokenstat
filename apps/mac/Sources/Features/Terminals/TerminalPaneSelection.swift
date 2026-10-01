// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// Tab and split selection uses stable IDs, independent of the transport.
struct TerminalPaneSelection {
    var selectedID: String?
    var leadingID: String?
    var trailingID: String?

    func active(in available: [String]) -> String? {
        selectedID.flatMap { available.contains($0) ? $0 : nil } ?? available.first
    }

    func panes(in available: [String], split: Bool) -> (leading: String?, trailing: String?) {
        guard split else { return (active(in: available), nil) }
        let trail = trailingID.flatMap { available.contains($0) ? $0 : nil }
        let lead = leadingID.flatMap { available.contains($0) ? $0 : nil }
            ?? available.first { $0 == active(in: available) && $0 != trail }
            ?? available.first { $0 != trail }
            ?? active(in: available)
        return (lead, trail == lead ? nil : trail)
    }

    mutating func setSplit(_ split: Bool, available: [String]) {
        guard split else { leadingID = nil; trailingID = nil; return }
        let showing = panes(in: available, split: true)
        leadingID = showing.leading
        trailingID = showing.trailing ?? available.first { $0 != leadingID }
    }

    mutating func select(_ id: String, available: [String], split: Bool) {
        guard available.contains(id) else { return }
        if split {
            let showing = panes(in: available, split: true)
            if id != showing.leading, id != showing.trailing {
                if showing.trailing == nil, let lead = showing.leading {
                    leadingID = lead
                    trailingID = id
                } else if active(in: available) == showing.trailing {
                    trailingID = id
                } else {
                    leadingID = id
                }
            }
        }
        selectedID = id
    }

    mutating func sendToOtherHalf(_ id: String, available: [String]) {
        guard available.contains(id), id != active(in: available) else { return }
        let showing = panes(in: available, split: true)
        if id == showing.leading || id == showing.trailing {
            selectedID = id
        } else if active(in: available) == showing.leading {
            trailingID = id
        } else {
            leadingID = id
        }
    }

    /// Move the visible sessions while keeping focus on the same terminal.
    mutating func swapPanes(available: [String]) {
        let showing = panes(in: available, split: true)
        guard let lead = showing.leading, let trail = showing.trailing else { return }
        leadingID = trail
        trailingID = lead
    }

    /// Returns true when a vanished split member requires a single pane.
    @discardableResult
    mutating func reconcile(available: [String]) -> Bool {
        let lostLead = leadingID.map { !available.contains($0) } ?? false
        let lostTrail = trailingID.map { !available.contains($0) } ?? false
        if lostLead || lostTrail {
            selectedID = lostLead ? trailingID : leadingID
            leadingID = nil
            trailingID = nil
        }
        selectedID = active(in: available)
        return lostLead || lostTrail
    }
}
