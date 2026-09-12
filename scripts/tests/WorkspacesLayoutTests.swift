// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with WorkspacesLayout.swift.
import Foundation

@main struct WorkspacesLayoutTests {
    @MainActor static func main() {
        let name = "WorkspacesLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let fresh = WorkspacesLayout(defaults: defaults)
        assert(fresh.order == [.folders, .recentChats, .sessions])
        assert(fresh.sections == fresh.order)
        assert(fresh.hidden.isEmpty)
        assert(fresh.preset == .foldersFirst)

        fresh.apply(
            order: WorkspacesLayout.moved(
                fresh.order, from: IndexSet(integer: 0), to: 3
            ),
            hidden: [.sessions],
            preset: nil
        )
        assert(fresh.sections == [.recentChats, .folders])
        assert(fresh.preset == nil)

        let relaunched = WorkspacesLayout(defaults: defaults)
        assert(relaunched.order == [.recentChats, .folders, .sessions])
        assert(relaunched.hidden == [.sessions])

        relaunched.apply(
            order: WorkspacesPreset.chatsFirst.order,
            hidden: WorkspacesPreset.chatsFirst.hidden,
            preset: .chatsFirst
        )
        assert(relaunched.sections == [.recentChats, .folders, .sessions])
        assert(WorkspacesLayout(defaults: defaults).preset == .chatsFirst)

        relaunched.reset()
        assert(relaunched.preset == .foldersFirst)
        assert(relaunched.sections == [.folders, .recentChats, .sessions])

        let moved = WorkspacesLayout.movedVisible(
            [.folders, .recentChats, .sessions],
            hidden: [.recentChats],
            from: IndexSet(integer: 0),
            to: 2
        )
        assert(moved == [.recentChats, .sessions, .folders]
            || moved == [.sessions, .folders, .recentChats]
            || moved == [.recentChats, .sessions, .folders])
        // Visible was [folders, sessions]; move folders after sessions.
        assert(moved.filter { $0 != .recentChats } == [.sessions, .folders])

        let messy = WorkspacesLayout.normalize(
            order: [.sessions, .sessions, .folders],
            hidden: [.recentChats, .sessions]
        )
        assert(messy.order == [.sessions, .folders, .recentChats])
        assert(messy.hidden == [.sessions, .recentChats]
            || messy.hidden == [.recentChats, .sessions])

        print("WorkspacesLayoutTests: ok")
    }
}
