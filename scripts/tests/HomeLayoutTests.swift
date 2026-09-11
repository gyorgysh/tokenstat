// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HomeLayout.swift.
import Foundation

@main struct HomeLayoutTests {
    @MainActor static func main() {
        let name = "HomeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // A device that has never been arranged gets the balanced order.
        // These tests run on a Mac, so that is the Mac balanced: the work
        // first, the figures switched off to be turned back on.
        let fresh = HomeLayout(defaults: defaults)
        assert(fresh.order == [.continueWork, .pinnedWork, .activity, .limits, .machines, .usage])
        assert(fresh.sections == [.continueWork, .pinnedWork, .activity, .limits, .machines])
        assert(fresh.hidden == [.usage])
        // And says so: a device nobody has arranged is balanced, not "none of
        // these three".
        assert(fresh.preset == .balanced)

        // Moving a card and switching one off survives a relaunch, and stops
        // claiming to be a preset.
        fresh.move(from: IndexSet(integer: 2), to: 0)
        fresh.setVisible(false, section: .machines)
        assert(fresh.sections == [.activity, .continueWork, .pinnedWork, .limits])
        assert(fresh.preset == nil)
        let relaunched = HomeLayout(defaults: defaults)
        assert(relaunched.order == fresh.order)
        assert(relaunched.hidden == [.usage, .machines])

        // Every card can be off. A clear Home is an answer, not a failure.
        for section in HomeSection.allCases { relaunched.setVisible(false, section: section) }
        assert(relaunched.sections.isEmpty)
        assert(HomeLayout(defaults: defaults).sections.isEmpty)

        // A preset replaces the whole arrangement in one go and is remembered
        // as the one in force.
        relaunched.apply(order: HomePreset.usage.order, hidden: [], preset: .usage)
        assert(relaunched.sections == HomePreset.usage.order)
        assert(HomeLayout(defaults: defaults).preset == .usage)
        relaunched.reset()
        assert(relaunched.sections == [.continueWork, .pinnedWork, .activity, .limits, .machines])
        assert(relaunched.hidden == [.usage])
        assert(relaunched.preset == .balanced)

        // A stored order this build cannot read is made usable rather than
        // thrown away: names it does not know go, a name twice is kept once,
        // and a card added by a later build joins at the end instead of
        // jumping an arrangement somebody chose.
        let messy = HomeLayout.normalize(
            order: [.limits, .limits, .activity],
            hidden: [.limits, .machines]
        )
        assert(messy.order == [.limits, .activity, .continueWork, .pinnedWork, .machines, .usage])
        assert(messy.hidden == [.limits, .machines])

        // An arrangement stored before pins existed gains the card at the
        // end, leaving every chosen position alone.
        let prePins = HomeLayout.normalize(
            order: [.continueWork, .machines, .usage, .activity, .limits],
            hidden: []
        )
        assert(prePins.order == [.continueWork, .machines, .usage, .activity, .limits, .pinnedWork])

        // Hiding something that is not in the order is not a thing.
        let stray = HomeLayout.normalize(order: [.usage], hidden: [.activity])
        assert(stray.order.first == .usage)
        assert(stray.order.count == HomeSection.allCases.count)
        assert(stray.hidden == [.activity])

        // Moving matches what a drag does: the destination is an index in the
        // list before the rows are lifted out of it.
        let five: [HomeSection] = [.continueWork, .pinnedWork, .machines, .usage, .activity, .limits]
        assert(HomeLayout.moved(five, from: IndexSet(integer: 5), to: 0)
            == [.limits, .continueWork, .pinnedWork, .machines, .usage, .activity])
        assert(HomeLayout.moved(five, from: IndexSet(integer: 0), to: 6)
            == [.pinnedWork, .machines, .usage, .activity, .limits, .continueWork])
        assert(HomeLayout.moved(five, from: IndexSet(integer: 1), to: 1) == five)
        assert(HomeLayout.moved(five, from: IndexSet([0, 1]), to: 4)
            == [.machines, .usage, .continueWork, .pinnedWork, .activity, .limits])
        // An offset nothing is at leaves the order alone rather than crashing.
        assert(HomeLayout.moved(five, from: IndexSet(integer: 9), to: 0) == five)

        // Visible-row offsets must not move a hidden card accidentally.
        let withHidden: [HomeSection] = [.continueWork, .usage, .activity, .pinnedWork, .limits, .machines]
        let visibleMove = HomeLayout.movedVisible(withHidden, hidden: [.usage, .machines],
                                                 from: IndexSet(integer: 0), to: 3)
        assert(visibleMove == [.activity, .usage, .pinnedWork, .continueWork, .limits, .machines])
        assert(HomeLayout.movedVisible(withHidden, hidden: Set(withHidden),
                                       from: IndexSet(integer: 0), to: 2) == withHidden)
        assert(HomeLayout.movedVisible(withHidden, hidden: [.usage],
                                       from: IndexSet(integer: 50), to: 0) == withHidden)

        // Nothing stored at all is the Mac balanced order, not an empty Home.
        assert(HomeLayout.normalize(order: nil, hidden: []).order == [.continueWork, .pinnedWork, .activity, .limits, .machines, .usage])
        assert(HomeLayout.normalize(order: nil, hidden: []).hidden == [.usage])

        // Every preset is a complete arrangement. One that dropped a card
        // would hide it with no way to say so, so anything hidden must still
        // be in the order.
        for preset in HomePreset.allCases {
            assert(Set(preset.hidden).isSubset(of: preset.order))
            assert(Set(preset.order) == Set(HomeSection.allCases))
            assert(preset.order.count == HomeSection.allCases.count)
        }

        // Junk in storage falls back rather than producing half a Home.
        let junkName = "HomeLayoutTests.junk.\(UUID().uuidString)"
        let junk = UserDefaults(suiteName: junkName)!
        defer { junk.removePersistentDomain(forName: junkName) }
        junk.set(["nonsense", "activity"], forKey: "home.sectionOrder.v1")
        junk.set(["nonsense"], forKey: "home.sectionHidden.v1")
        let recovered = HomeLayout(defaults: junk)
        assert(recovered.order.first == .activity)
        assert(recovered.order.count == HomeSection.allCases.count)
        assert(recovered.hidden.isEmpty)

        print("Home layout: defaults, reorder, hiding, presets, persistence and normalization passed")
    }
}
