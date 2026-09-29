// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if os(macOS)
import AppKit
import SwiftUI
/// Native virtual elements keep calendar navigation available without adding a
/// SwiftUI Button subtree for every day to each window layout pass.
struct HeatmapAccessibilityView: NSViewRepresentable {
    var rows: [[HeatCell?]]
    var cell: CGFloat
    var gap: CGFloat
    var onSelect: ((HeatCell) -> Void)?

    func makeNSView(context: Context) -> HeatmapAccessibilityHost { HeatmapAccessibilityHost() }
    func updateNSView(_ view: HeatmapAccessibilityHost, context: Context) {
        view.cell = cell
        view.gap = gap
        view.onSelect = onSelect
        view.update(rows: rows)
    }
}

final class HeatmapAccessibilityHost: NSView {
    var cell: CGFloat = 0
    var gap: CGFloat = 0
    var onSelect: ((HeatCell) -> Void)?
    private var rows: [[HeatCell?]] = []
    private var days: [HeatmapAccessibilityDay] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Daily activity" }
    override func accessibilityChildren() -> [Any]? { days }

    func update(rows: [[HeatCell?]]) {
        guard self.rows != rows else { return }
        self.rows = rows
        days = rows.enumerated().flatMap { row, cells in
            cells.enumerated().compactMap { column, day in
                guard let day, !day.isLocked else { return nil }
                return HeatmapAccessibilityDay(day: day, row: row, column: column, owner: self)
            }
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
}

final class HeatmapAccessibilityDay: NSAccessibilityElement, NSAccessibilityButton {
    let day: HeatCell
    let row: Int
    let column: Int
    weak var owner: HeatmapAccessibilityHost?
    init(day: HeatCell, row: Int, column: Int, owner: HeatmapAccessibilityHost) {
        self.day = day; self.row = row; self.column = column; self.owner = owner
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        setAccessibilityLabel("\(day.date): \(formatSpend(day.value)) at API list price")
        setAccessibilityHelp("Pins this day in the inspector")
    }
    override func accessibilityParent() -> Any? { owner }
    override func accessibilityIdentifier() -> String { "activity-day-" + day.date }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { owner?.onSelect != nil }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        let cell = CGRect(x: CGFloat(column) * (owner.cell + owner.gap),
                          y: CGFloat(row) * (owner.cell + owner.gap), width: owner.cell, height: owner.cell)
        return window.convertToScreen(owner.convert(cell, to: nil))
    }
    override func accessibilityPerformPress() -> Bool {
        guard let action = owner?.onSelect else { return false }
        action(day)
        return true
    }
}
#endif
