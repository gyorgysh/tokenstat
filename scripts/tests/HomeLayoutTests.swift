// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with HomeLayout.swift.
import Foundation

@main struct HomeLayoutTests {
    @MainActor static func main() {
        let name = "HomeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // A device that has never been arranged gets the balanced order,
        // which is the order Home has always drawn.
        let fresh = HomeLayout(defaults: defaults)
        assert(fresh.order == HomePreset.balanced.order)
        assert(fresh.sections == [.continueWork, .machines, .usage, .activity, .limits])
        assert(fresh.hidden.isEmpty)
        // And says so: a device nobody has arranged is balanced, not "none of
        // these three".
        assert(fresh.preset == .balanced)

        // Moving a card and switching one off survives a relaunch, and stops
        // claiming to be a preset.
        fresh.move(from: IndexSet(integer: 3), to: 0)
        fresh.setVisible(false, section: .machines)
        assert(fresh.sections == [.activity, .continueWork, .usage, .limits])
        assert(fresh.preset == nil)
        let relaunched = HomeLayout(defaults: defaults)
        assert(relaunched.order == fresh.order)
        assert(relaunched.hidden == [.machines])

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
        assert(relaunched.sections == HomePreset.balanced.order)
        assert(relaunched.preset == .balanced)

        // A stored order this build cannot read is made usable rather than
        // thrown away: names it does not know go, a name twice is kept once,
        // and a card added by a later build joins at the end instead of
        // jumping an arrangement somebody chose.
        let messy = HomeLayout.normalize(
            order: [.limits, .limits, .activity],
            hidden: [.limits, .machines]
        )
        assert(messy.order == [.limits, .activity, .continueWork, .machines, .usage])
        assert(messy.hidden == [.limits, .machines])

        // Hiding something that is not in the order is not a thing.
        let stray = HomeLayout.normalize(order: [.usage], hidden: [.activity])
        assert(stray.order.first == .usage)
        assert(stray.order.count == HomeSection.allCases.count)
        assert(stray.hidden == [.activity])

        // Moving matches what a drag does: the destination is an index in the
        // list before the rows are lifted out of it.
        let five = HomePreset.balanced.order
        assert(HomeLayout.moved(five, from: IndexSet(integer: 4), to: 0)
            == [.limits, .continueWork, .machines, .usage, .activity])
        assert(HomeLayout.moved(five, from: IndexSet(integer: 0), to: 5)
            == [.machines, .usage, .activity, .limits, .continueWork])
        assert(HomeLayout.moved(five, from: IndexSet(integer: 1), to: 1) == five)
        assert(HomeLayout.moved(five, from: IndexSet([0, 1]), to: 4)
            == [.usage, .activity, .continueWork, .machines, .limits])
        // An offset nothing is at leaves the order alone rather than crashing.
        assert(HomeLayout.moved(five, from: IndexSet(integer: 9), to: 0) == five)

        // Nothing stored at all is the default, not an empty Home.
        assert(HomeLayout.normalize(order: nil, hidden: []).order == HomePreset.balanced.order)

        // Every preset is a complete arrangement. One that dropped a card
        // would hide it with no way to say so.
        for preset in HomePreset.allCases {
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
