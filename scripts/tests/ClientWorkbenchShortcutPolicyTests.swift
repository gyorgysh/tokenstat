// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ClientWorkbenchShortcutPolicy.swift.
import Foundation

@main struct ClientWorkbenchShortcutPolicyTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                failures += 1
                print("FAIL: \(message)")
            }
        }

        // No shortcut may be bare Return: starting or confirming work never
        // rides on the key chat composition uses.
        for shortcut in WorkbenchShortcut.allCases {
            check(!shortcut.isBareReturn, "\(shortcut.rawValue) must not be bare Return")
        }

        // Run is Shift-Command-R, distinct from the global Refresh on
        // Command-R, and the inspector toggle carries Option so it never
        // collides with typing.
        check(WorkbenchShortcut.run.modifiers == [.command, .shift], "run is Shift-Command-R")
        check(WorkbenchShortcut.inspector.modifiers == [.command, .option], "inspector carries Option")
        check(WorkbenchShortcut.save.modifiers == .command, "save is Command-S")
        check(WorkbenchShortcut.new.modifiers == .command, "new is Command-N")

        // Each binding is unique: two entries sharing a chord would make
        // discovery lie.
        var seen: Set<String> = []
        for shortcut in WorkbenchShortcut.allCases {
            let binding = WorkbenchShortcutPolicy.binding(of: shortcut)
            let id = "\(binding.key)+\(binding.modifiers.rawValue)"
            check(!seen.contains(id), "duplicate chord for \(shortcut.rawValue)")
            seen.insert(id)
        }

        // Save: dirty, idle, no conflict, no terminal.
        check(
            WorkbenchShortcutPolicy.canSave(EditorShortcutState(dirty: true)),
            "save fires on a dirty idle file"
        )
        check(
            !WorkbenchShortcutPolicy.canSave(EditorShortcutState(dirty: false)),
            "save refuses a clean file"
        )
        check(
            !WorkbenchShortcutPolicy.canSave(EditorShortcutState(dirty: true, saving: true)),
            "save refuses while a save is in flight"
        )
        check(
            !WorkbenchShortcutPolicy.canSave(EditorShortcutState(dirty: true, conflict: true)),
            "save refuses while a host conflict waits for an explicit choice"
        )
        check(
            !WorkbenchShortcutPolicy.canSave(EditorShortcutState(dirty: true, terminalOpen: true)),
            "save refuses while a terminal owns the keyboard"
        )

        // Find toggles except over a terminal.
        check(
            WorkbenchShortcutPolicy.canFind(EditorShortcutState()),
            "find toggles in the editor"
        )
        check(
            !WorkbenchShortcutPolicy.canFind(EditorShortcutState(terminalOpen: true)),
            "find refuses over a terminal"
        )

        // Next/previous: navigate when open with matches, open when hidden,
        // never over a terminal.
        check(
            WorkbenchShortcutPolicy.canFindNext(EditorShortcutState(canNavigate: true, findShowing: true)),
            "next navigates when open with matches"
        )
        check(
            !WorkbenchShortcutPolicy.canFindNext(EditorShortcutState(canNavigate: false, findShowing: true)),
            "next refuses when open without matches"
        )
        check(
            WorkbenchShortcutPolicy.canFindNext(EditorShortcutState(findShowing: false)),
            "next opens the bar when hidden"
        )
        check(
            WorkbenchShortcutPolicy.canFindPrevious(EditorShortcutState(findShowing: false)),
            "previous opens the bar when hidden"
        )
        check(
            !WorkbenchShortcutPolicy.canFindNext(EditorShortcutState(findShowing: false, terminalOpen: true)),
            "next refuses over a terminal even when hidden"
        )
        check(
            !WorkbenchShortcutPolicy.canFindPrevious(
                EditorShortcutState(canNavigate: true, findShowing: true, terminalOpen: true)
            ),
            "previous refuses over a terminal"
        )

        // Focused Run: selected, idle, nothing live or pending, nothing covering.
        check(
            WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: true)),
            "run fires for the selected idle job"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: false)),
            "run refuses with no selection"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(working: true, hasSelection: true)),
            "run refuses while starting"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: true, hasLiveRun: true)),
            "run refuses while a run is live"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: true, hasPendingLaunch: true)),
            "run refuses while an unconfirmed launch waits for Check/Retry"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: true, modalPresented: true)),
            "run refuses while a sheet or cover is up"
        )
        check(
            !WorkbenchShortcutPolicy.canRun(JobRunShortcutState(hasSelection: true, terminalOpen: true)),
            "run refuses while a terminal owns the screen"
        )

        // New: refused only while covered.
        check(
            WorkbenchShortcutPolicy.canCreate(NewShortcutState()),
            "new fires on an open surface"
        )
        check(
            !WorkbenchShortcutPolicy.canCreate(NewShortcutState(modalPresented: true)),
            "new refuses while a sheet or cover is up"
        )
        check(
            !WorkbenchShortcutPolicy.canCreate(NewShortcutState(terminalOpen: true)),
            "new refuses while a terminal owns the screen"
        )

        // Inspector: needs an identity and a non-terminal screen.
        check(
            WorkbenchShortcutPolicy.canToggleInspector(InspectorShortcutState(hasIdentity: true)),
            "inspector toggles when there is one"
        )
        check(
            !WorkbenchShortcutPolicy.canToggleInspector(InspectorShortcutState(hasIdentity: false)),
            "inspector refuses with nothing to show"
        )
        check(
            !WorkbenchShortcutPolicy.canToggleInspector(
                InspectorShortcutState(hasIdentity: true, terminalOpen: true)
            ),
            "inspector refuses over a terminal"
        )

        if failures == 0 {
            print("ClientWorkbenchShortcutPolicyTests passed")
        } else {
            print("\(failures) failures")
            fatalError("\(failures) failures")
        }
    }
}
