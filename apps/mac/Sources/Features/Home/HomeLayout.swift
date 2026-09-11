// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
import Observation

/// One block of Home, named so a person can move it or switch it off.
///
/// The greeting, the connection notice and anything about the account stay
/// outside this list on purpose: they are not cards somebody arranges, they
/// are the screen telling you something. Everything here is optional, and all
/// of it can be off at once. A Home with nothing on it is a real answer for
/// somebody who opens the app to go straight to a folder.
enum HomeSection: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The work worth going back to. Under the two figures by default, and
    /// the first thing anybody actually opens.
    case continueWork = "continue"
    case pinnedWork = "pinned"
    case machines
    case usage
    case activity
    case limits

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continueWork: "Continue"
        case .pinnedWork: "Pinned work"
        case .machines: "Machines"
        case .usage: "Today and this week"
        case .activity: "Activity"
        case .limits: "Plan limits"
        }
    }

    /// One line in the editor, saying what the card is for rather than
    /// repeating its name.
    var detail: String {
        switch self {
        case .continueWork: "The folders and conversations you were last in"
        case .pinnedWork: "Shortcuts to the folders and conversations you pinned"
        case .machines: "Which of your machines are awake"
        case .usage: "What today and this week came to"
        case .activity: "The year, a square a day"
        case .limits: "How full each plan window is"
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

/// A starting arrangement, not a mode.
///
/// Picking one changes the order of the cards and nothing else: no feature
/// turns off, no number is counted differently, nothing is billed another
/// way. That is why they are named after what is at the top rather than after
/// a kind of person.
enum HomePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced
    case work
    case usage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .work: "Work first"
        case .usage: "Usage first"
        }
    }

    /// Every preset switches everything on, with one exception: Balanced on
    /// the Mac leaves the figures off. A new Mac opens on the work, and the
    /// figures live one click away in Insights; somebody who wants them on
    /// Home switches them back on in Customize Home. Everywhere else a card
    /// is switched off by the person holding the device, not by the
    /// arrangement they picked.
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

    /// Balanced answers the two questions the app is opened for, in order:
    /// what you were doing, and what it cost. On the Mac the work leads and
    /// the figures sit out: Continue, the pinned shortcuts, the year grid,
    /// the plan windows, the machines, with Today and this week switched off
    /// to be turned back on. On the phone the two figures lead as before:
    /// they are one line deep and read at a glance, so they answer without
    /// pushing the work down a short screen.
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

/// How this device arranges Home.
///
/// Device furniture, like the tab bar and the layout preference, and kept the
/// same way. A phone in a hand and a Mac on a desk are not the same screen,
/// and an arrangement made on one has no business rearranging the other. Pins
/// and the work itself belong to the account; the order of the cards does not.
@MainActor @Observable
final class HomeLayout {
    static let shared = HomeLayout()

    private static let orderKey = "home.sectionOrder.v1"
    private static let hiddenKey = "home.sectionHidden.v1"
    private static let presetKey = "home.sectionPreset.v1"

    private(set) var order: [HomeSection]
    private(set) var hidden: Set<HomeSection>
    /// The last preset applied, so the editor can show which one this is
    /// still exactly. Cleared the moment anything is moved by hand.
    private(set) var preset: HomePreset?

    /// What Home draws, in order. Empty is allowed and means what it says.
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
        // A device nobody has arranged is balanced, and the editor should say
        // so rather than showing three arrangements and none of them chosen.
        preset = stored == nil
            ? .balanced
            : defaults.string(forKey: Self.presetKey).flatMap(HomePreset.init(rawValue:))
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Make a stored arrangement usable whatever is in it.
    ///
    /// A build that adds a section must not disturb an order somebody chose,
    /// so new ones join at the end. A name this build does not know is
    /// dropped, a name twice is kept once, and hiding something that is not
    /// in the order is not a thing.
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

    /// Reorder the visible rows while retaining hidden cards in their saved
    /// slots. List offsets refer to the visible group, not the full arrangement.
    static func movedVisible(
        _ order: [HomeSection], hidden: Set<HomeSection>, from offsets: IndexSet, to destination: Int
    ) -> [HomeSection] {
        let visible = order.filter { !hidden.contains($0) }
        var moved = moved(visible, from: offsets, to: destination).makeIterator()
        return order.map { hidden.contains($0) ? $0 : moved.next() ?? $0 }
    }

    /// Apply an arrangement made somewhere else, in one go, so Home changes
    /// once rather than card by card.
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
