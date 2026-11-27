// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

enum HomeSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case continueWork = "continue"
    case pinnedWork = "pinned"
    case machines
    case usage
    case activity
    case limits

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continueWork: L10n.text("apple.homelayout.continue.31fbef16")
        case .pinnedWork: L10n.text("apple.homelayout.pinned_work.23dd8f45")
        case .machines: L10n.text("apple.homelayout.machines.c061da19")
        case .usage: L10n.text("apple.homelayout.today_and_this_week.2cb0c4ae")
        case .activity: L10n.text("apple.homelayout.activity.38da1505")
        case .limits: L10n.text("apple.homelayout.plan_limits.925788cd")
        }
    }

    var detail: String {
        switch self {
        case .continueWork: L10n.text("apple.homelayout.the_folders_and_conversations_you_were_las.611a8af7")
        case .pinnedWork: L10n.text("apple.homelayout.shortcuts_to_the_folders_and_conversations.395d6781")
        case .machines: L10n.text("apple.homelayout.which_of_your_machines_are_awake.59492064")
        case .usage: L10n.text("apple.homelayout.what_today_and_this_week_came_to.e49c5c1c")
        case .activity: L10n.text("apple.homelayout.the_year_a_square_a_day.a3daad88")
        case .limits: L10n.text("apple.homelayout.how_much_of_each_tool_s_subscription_is_le.16c87cc1")
        }
    }

    var symbol: String {
        switch self {
        case .continueWork: "arrow.uturn.backward.circle.fill"
        case .pinnedWork: "pin.fill"
        case .machines: "desktopcomputer"
        case .usage: "sum"
        case .activity: "square.grid.3x3.fill"
        case .limits: "gauge.with.needle"
        }
    }
}

enum HomePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced
    case work
    case usage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: L10n.text("apple.homelayout.balanced.5386ea5d")
        case .work: L10n.text("apple.homelayout.work_first.c3edce98")
        case .usage: L10n.text("apple.homelayout.usage_first.007ee7e0")
        }
    }

    var hidden: Set<HomeSection> {
        switch self {
        case .balanced:
#if os(macOS)
            [.usage]
#else
            []
#endif
        default:
            []
        }
    }

    var order: [HomeSection] {
        switch self {
        case .balanced:
#if os(macOS)
            [.continueWork, .pinnedWork, .activity, .limits, .machines, .usage]
#else
            [.usage, .continueWork, .machines, .pinnedWork, .activity, .limits]
#endif
        case .work: [.continueWork, .pinnedWork, .machines, .limits, .usage, .activity]
        case .usage: [.usage, .limits, .activity, .continueWork, .pinnedWork, .machines]
        }
    }
}

@MainActor @Observable
final class HomeLayout {
    static let shared = HomeLayout()

    private static let orderKey = "home.sectionOrder.v1"
    private static let hiddenKey = "home.sectionHidden.v1"
    private static let presetKey = "home.sectionPreset.v1"

    private(set) var order: [HomeSection]
    private(set) var hidden: Set<HomeSection>
    private(set) var preset: HomePreset?

    var sections: [HomeSection] { order.filter { !hidden.contains($0) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.orderKey) == nil
            ? nil
            : defaults.stringArray(forKey: Self.orderKey)
        let resolved = Self.normalize(
            order: stored?.compactMap(HomeSection.init(rawValue:)),
            hidden: (defaults.stringArray(forKey: Self.hiddenKey) ?? [])
                .compactMap(HomeSection.init(rawValue:))
        )
        order = resolved.order
        hidden = resolved.hidden
        preset = stored == nil
            ? .balanced
            : defaults.string(forKey: Self.presetKey).flatMap(HomePreset.init(rawValue:))
    }

    @ObservationIgnored private let defaults: UserDefaults

    static func normalize(
        order stored: [HomeSection]?, hidden: [HomeSection]
    ) -> (order: [HomeSection], hidden: Set<HomeSection>) {
        guard let stored else { return (HomePreset.balanced.order, HomePreset.balanced.hidden) }
        var seen: Set<HomeSection> = []
        var order = stored.filter { seen.insert($0).inserted }
        order += HomePreset.balanced.order.filter { !seen.contains($0) }
        return (order, Set(hidden).intersection(order))
    }

    func setVisible(_ visible: Bool, section: HomeSection) {
        if visible {
            hidden.remove(section)
        } else {
            hidden.insert(section)
        }
        preset = nil
        save()
    }

    func move(from: IndexSet, to: Int) {
        order = Self.moved(order, from: from, to: to)
        preset = nil
        save()
    }

    /// SwiftUI's own `onMove` semantics, written out because this model has no
    /// business importing SwiftUI: `to` is an index in the list *before* the
    /// rows are lifted out of it.
    static func moved(
        _ sections: [HomeSection], from offsets: IndexSet, to destination: Int
    ) -> [HomeSection] {
        let lifted = offsets.sorted().filter { sections.indices.contains($0) }
        guard !lifted.isEmpty else { return sections }
        let moving = lifted.map { sections[$0] }
        var remaining = sections
        for index in lifted.reversed() { remaining.remove(at: index) }
        let ahead = lifted.filter { $0 < destination }.count
        let target = min(max(0, destination - ahead), remaining.count)
        remaining.insert(contentsOf: moving, at: target)
        return remaining
    }

    static func movedVisible(
        _ order: [HomeSection], hidden: Set<HomeSection>, from offsets: IndexSet, to destination: Int
    ) -> [HomeSection] {
        let visible = order.filter { !hidden.contains($0) }
        var moved = moved(visible, from: offsets, to: destination).makeIterator()
        return order.map { hidden.contains($0) ? $0 : moved.next() ?? $0 }
    }

    func apply(order: [HomeSection], hidden: Set<HomeSection>, preset: HomePreset?) {
        let resolved = Self.normalize(order: order, hidden: Array(hidden))
        self.order = resolved.order
        self.hidden = resolved.hidden
        self.preset = preset
        save()
    }

    func reset() {
        apply(order: HomePreset.balanced.order, hidden: HomePreset.balanced.hidden, preset: .balanced)
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue), forKey: Self.hiddenKey)
        if let preset {
            defaults.set(preset.rawValue, forKey: Self.presetKey)
        } else {
            defaults.removeObject(forKey: Self.presetKey)
        }
    }
}
